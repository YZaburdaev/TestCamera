unit IPCManager.ThreadSafeMessagesPool;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections,
  YZLockFreeRingBuffer;

type
  TIPCMessage = class
  private
    FMsgType: Integer;
    FData: TBytes;
    FRefCount: Integer;
    
    function GetDataSize: Integer;
  public
    constructor Create(MsgType: Integer; const Data: TBytes);
    
    function AddRef: Integer;
    function Release: Integer;
    
    property MsgType: Integer read FMsgType;
    property Data: TBytes read FData;
    property DataSize: Integer read GetDataSize;
  end;

  TMessagePool = class
  private
    FPool: TObjectStack<TIPCMessage>;
    FCriticalSection: TCriticalSection;
    
    function InternalCreateMessage(MsgType: Integer; const Data: TBytes): TIPCMessage;
  public
    constructor Create;
    destructor Destroy; override;
    
    function AcquireMessage(MsgType: Integer; const Data: TBytes): TIPCMessage;
    procedure ReleaseMessage(Message: TIPCMessage);
  end;

  TIPCManager = class
  private
    FBuffer: TLockFreeRingBuffer;
    FMessagePool: TMessagePool;
    FMaxMessageSize: Integer;
    
    procedure SendMessageInternal(Message: TIPCMessage);
  public
    constructor Create(const AName: string; MaxBufferSize: Integer = 1024 * 1024 * 10);
    destructor Destroy; override;
    
    procedure Send(MsgType: Integer; const Data: TBytes);
    function Receive(var Message: TIPCMessage): Boolean;
  end;

implementation

{ TIPCMessage }

constructor TIPCMessage.Create(MsgType: Integer; const Data: TBytes);
begin
  inherited Create;
  FMsgType := MsgType;
  FData := Copy(Data, 0, Length(Data));
  FRefCount := 1;
end;

function TIPCMessage.GetDataSize: Integer;
begin
  Result := Length(FData);
end;

function TIPCMessage.AddRef: Integer;
begin
  Result := InterlockedIncrement(FRefCount);
end;

function TIPCMessage.Release: Integer;
begin
  Result := InterlockedDecrement(FRefCount);
  if Result = 0 then
    Free;
end;

{ TMessagePool }

constructor TMessagePool.Create;
begin
  inherited;
  FPool := TObjectStack<TIPCMessage>.Create;
  FCriticalSection := TCriticalSection.Create;
end;

destructor TMessagePool.Destroy;
begin
  while FPool.Count > 0 do
    FPool.Pop.Free;
    
  FreeAndNil(FPool);
  FreeAndNil(FCriticalSection);
  inherited;
end;

function TMessagePool.InternalCreateMessage(MsgType: Integer; const Data: TBytes): TIPCMessage;
begin
  Result := TIPCMessage.Create(MsgType, Data);
end;

function TMessagePool.AcquireMessage(MsgType: Integer; const Data: TBytes): TIPCMessage;
begin
  FCriticalSection.Enter;
  try
    if FPool.Count > 0 then
    begin
      Result := FPool.Pop;
      Result.FMsgType := MsgType;
      Result.FData := Copy(Data, 0, Length(Data));
      Result.FRefCount := 1;
    end
    else
    begin
      Result := InternalCreateMessage(MsgType, Data);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TMessagePool.ReleaseMessage(Message: TIPCMessage);
begin
  if Message.Release = 0 then
  begin
    FCriticalSection.Enter;
    try
      // Можно переиспользовать объект
      if FPool.Count < 100 then // Ограничиваем размер пула
        FPool.Push(Message)
      else
        Message.Free;
    finally
      FCriticalSection.Leave;
    end;
  end;
end;

{ TIPCManager }

constructor TIPCManager.Create(const AName: string; MaxBufferSize: Integer);
begin
  inherited Create;
  
  FBuffer := TLockFreeRingBuffer.Create(AName, MaxBufferSize);
  FMessagePool := TMessagePool.Create;
  FMaxMessageSize := MaxBufferSize div 10; // 10% от буфера
end;

destructor TIPCManager.Destroy;
begin
  FreeAndNil(FMessagePool);
  FreeAndNil(FBuffer);
  inherited;
end;

procedure TIPCManager.Send(MsgType: Integer; const Data: TBytes);
var
  Message: TIPCMessage;
begin
  if Length(Data) > FMaxMessageSize then
    raise Exception.CreateFmt('Message too large: %d bytes (max: %d)', 
      [Length(Data), FMaxMessageSize]);
      
  Message := FMessagePool.AcquireMessage(MsgType, Data);
  try
    SendMessageInternal(Message);
  finally
    FMessagePool.ReleaseMessage(Message);
  end;
end;

procedure TIPCManager.SendMessageInternal(Message: TIPCMessage);
var
  Packet: TBytes;
  Offset: Integer;
begin
  // Сериализуем сообщение: размер + тип + данные
  SetLength(Packet, SizeOf(Integer) * 2 + Message.DataSize);
  
  // Записываем размер данных
  PInteger(@Packet[0])^ := Message.DataSize;
  
  // Записываем тип сообщения
  PInteger(@Packet[SizeOf(Integer)])^ := Message.MsgType;
  
  // Записываем данные
  if Message.DataSize > 0 then
    Move(Message.Data[0], Packet[SizeOf(Integer) * 2], Message.DataSize);
    
  // Отправляем
  FBuffer.TryEnqueue(Packet[0], Length(Packet));
end;

function TIPCManager.Receive(var Message: TIPCMessage): Boolean;
var
  Packet: array of Byte;
  DataSize, MsgType, ActualSize: Integer;
  Data: TBytes;
begin
  Result := False;
  Message := nil;
  
  // Сначала читаем размер пакета
  if FBuffer.Peek(Packet[0], SizeOf(Integer), ActualSize) and 
     (ActualSize = SizeOf(Integer)) then
  begin
    DataSize := PInteger(@Packet[0])^;
    
    // Проверяем, что сообщение поместится в буфер
    if DataSize <= FMaxMessageSize then
    begin
      SetLength(Packet, SizeOf(Integer) * 2 + DataSize);
      
      if FBuffer.TryDequeue(Packet[0], Length(Packet), ActualSize) and
         (ActualSize = Length(Packet)) then
      begin
        // Читаем тип сообщения
        MsgType := PInteger(@Packet[SizeOf(Integer)])^;
        
        // Читаем данные
        SetLength(Data, DataSize);
        if DataSize > 0 then
          Move(Packet[SizeOf(Integer) * 2], Data[0], DataSize);
          
        // Создаем сообщение из пула
        Message := FMessagePool.AcquireMessage(MsgType, Data);
        Result := True;
      end;
    end;
  end;
end;

end.