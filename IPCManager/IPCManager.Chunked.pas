unit IPCManager.Chunked;

interface

uses
  System.Classes, System.SysUtils, LockFreeRingBuffer;

const
  MSG_CHUNK_HEADER = 0;
  MSG_CHUNK_DATA = 1;
  MSG_COMPLETE = 2;
  
  MAX_CHUNK_SIZE = 8192; // 8KB на чанк

type
  TChunkHeader = packed record
    MsgID: UInt64;        // Уникальный ID сообщения
    TotalSize: UInt32;    // Общий размер данных
    ChunkIndex: UInt32;   // Индекс чанка
    ChunkCount: UInt32;   // Всего чанков
    ChunkSize: UInt32;    // Размер этого чанка
  end;
  PChunkHeader = ^TChunkHeader;

  TIPCMessage = record
    MsgType: Integer;
    DataSize: Integer;
    Data: TBytes; // Динамический массив
  end;

  TIPCMessageHandler = procedure(const Msg: TIPCMessage) of object;
  
  TMessageBuilder = class
  private
    FMsgID: UInt64;
    FTotalSize: UInt32;
    FReceivedSize: UInt32;
    FData: TBytes;
    FChunksReceived: array of Boolean;
    
    function IsComplete: Boolean;
  public
    constructor Create(const Header: TChunkHeader);
    procedure AddChunk(ChunkIndex: UInt32; const ChunkData; ChunkSize: UInt32);
    function BuildMessage(var Msg: TIPCMessage): Boolean;
  end;

  TIPCManager = class
  private
    FRingBuffer: TLockFreeRingBuffer;
    FMessageBuilders: TObjectDictionary<UInt64, TMessageBuilder>;
    FCriticalSection: TCriticalSection;
    FOnMessage: TIPCMessageHandler;
    
    procedure ProcessChunk(const Header: TChunkHeader; ChunkData: PByte);
    procedure SendChunked(MsgType: Integer; const Data: TBytes);
  public
    constructor Create(const AName: string; ACapacity: Integer = 1024 * 1024 * 10); // 10MB
    destructor Destroy; override;
    
    procedure SendMessage(MsgType: Integer; const Data: TBytes); overload;
    procedure SendMessage(MsgType: Integer; const Text: string); overload;
    procedure SendMessage(MsgType: Integer; Stream: TStream); overload;
    
    procedure ProcessMessages;
    
    property OnMessage: TIPCMessageHandler read FOnMessage write FOnMessage;
  end;

implementation

uses
  System.Generics.Collections, Winapi.Windows;

{ TMessageBuilder }

constructor TMessageBuilder.Create(const Header: TChunkHeader);
begin
  inherited Create;
  
  FMsgID := Header.MsgID;
  FTotalSize := Header.TotalSize;
  FReceivedSize := 0;
  
  SetLength(FData, FTotalSize);
  SetLength(FChunksReceived, Header.ChunkCount);
end;

procedure TMessageBuilder.AddChunk(ChunkIndex: UInt32; const ChunkData; ChunkSize: UInt32);
var
  Offset: UInt32;
begin
  if ChunkIndex >= Length(FChunksReceived) then
    Exit;
    
  if FChunksReceived[ChunkIndex] then
    Exit; // Чанк уже получен
    
  // Вычисляем смещение в общем массиве
  Offset := ChunkIndex * MAX_CHUNK_SIZE;
  
  // Копируем данные чанка
  if Offset + ChunkSize <= FTotalSize then
  begin
    Move(ChunkData, FData[Offset], ChunkSize);
    FReceivedSize := FReceivedSize + ChunkSize;
    FChunksReceived[ChunkIndex] := True;
  end;
end;

function TMessageBuilder.BuildMessage(var Msg: TIPCMessage): Boolean;
var
  i: Integer;
begin
  Result := IsComplete;
  if Result then
  begin
    Msg.MsgType := 0; // Будет установлено вызывающим кодом
    Msg.DataSize := FTotalSize;
    Msg.Data := Copy(FData, 0, FTotalSize);
  end;
end;

function TMessageBuilder.IsComplete: Boolean;
var
  i: Integer;
begin
  if FReceivedSize <> FTotalSize then
    Exit(False);
    
  for i := 0 to High(FChunksReceived) do
    if not FChunksReceived[i] then
      Exit(False);
      
  Result := True;
end;

{ TIPCManager }

constructor TIPCManager.Create(const AName: string; ACapacity: Integer);
begin
  inherited Create;
  
  FRingBuffer := TLockFreeRingBuffer.Create(AName, ACapacity);
  FMessageBuilders := TObjectDictionary<UInt64, TMessageBuilder>.Create([doOwnsValues]);
  FCriticalSection := TCriticalSection.Create;
end;

destructor TIPCManager.Destroy;
begin
  FreeAndNil(FCriticalSection);
  FreeAndNil(FMessageBuilders);
  FreeAndNil(FRingBuffer);
  inherited;
end;

procedure TIPCManager.SendMessage(MsgType: Integer; const Data: TBytes);
begin
  if Length(Data) <= MAX_CHUNK_SIZE then
  begin
    // Отправляем как одно сообщение
    FRingBuffer.TryEnqueue(Data[0], Length(Data));
  end
  else
  begin
    // Отправляем чанками
    SendChunked(MsgType, Data);
  end;
end;

procedure TIPCManager.SendMessage(MsgType: Integer; const Text: string);
var
  Bytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(Text);
  SendMessage(MsgType, Bytes);
end;

procedure TIPCManager.SendMessage(MsgType: Integer; Stream: TStream);
var
  Bytes: TBytes;
begin
  if Stream.Size > 0 then
  begin
    SetLength(Bytes, Stream.Size);
    Stream.Position := 0;
    Stream.Read(Bytes[0], Stream.Size);
    SendMessage(MsgType, Bytes);
  end;
end;

procedure TIPCManager.SendChunked(MsgType: Integer; const Data: TBytes);
var
  MsgID: UInt64;
  TotalSize, ChunkCount, i: UInt32;
  ChunkSize: UInt32;
  Header: TChunkHeader;
  Buffer: array[0..MAX_CHUNK_SIZE + SizeOf(TChunkHeader) - 1] of Byte;
begin
  TotalSize := Length(Data);
  ChunkCount := (TotalSize + MAX_CHUNK_SIZE - 1) div MAX_CHUNK_SIZE;
  
  // Генерируем уникальный ID сообщения
  QueryPerformanceCounter(PInt64(@MsgID)^);
  
  // Отправляем заголовок
  Header.MsgID := MsgID;
  Header.TotalSize := TotalSize;
  Header.ChunkIndex := 0;
  Header.ChunkCount := ChunkCount;
  Header.ChunkSize := 0;
  
  Move(Header, Buffer[0], SizeOf(Header));
  FRingBuffer.TryEnqueue(Buffer[0], SizeOf(Header));
  
  // Отправляем чанки
  for i := 0 to ChunkCount - 1 do
  begin
    Header.ChunkIndex := i;
    
    // Вычисляем размер чанка
    if i = ChunkCount - 1 then
      ChunkSize := TotalSize - (i * MAX_CHUNK_SIZE)
    else
      ChunkSize := MAX_CHUNK_SIZE;
      
    Header.ChunkSize := ChunkSize;
    
    // Заполняем буфер: заголовок + данные
    Move(Header, Buffer[0], SizeOf(Header));
    Move(Data[i * MAX_CHUNK_SIZE], Buffer[SizeOf(Header)], ChunkSize);
    
    FRingBuffer.TryEnqueue(Buffer[0], SizeOf(Header) + ChunkSize);
  end;
end;

procedure TIPCManager.ProcessChunk(const Header: TChunkHeader; ChunkData: PByte);
var
  Builder: TMessageBuilder;
  Msg: TIPCMessage;
begin
  FCriticalSection.Enter;
  try
    // Ищем существующий билдер или создаем новый
    if not FMessageBuilders.TryGetValue(Header.MsgID, Builder) then
    begin
      Builder := TMessageBuilder.Create(Header);
      FMessageBuilders.Add(Header.MsgID, Builder);
    end;
    
    // Добавляем чанк (если это не заголовочный чанк)
    if Header.ChunkSize > 0 then
      Builder.AddChunk(Header.ChunkIndex, ChunkData^, Header.ChunkSize);
    
    // Проверяем, собран ли весь сообщение
    if Builder.BuildMessage(Msg) then
    begin
      Msg.MsgType := 0; // Установить реальный тип из заголовка
      
      // Уведомляем подписчика
      if Assigned(FOnMessage) then
        FOnMessage(Msg);
        
      // Удаляем билдер
      FMessageBuilders.Remove(Header.MsgID);
    end;
    
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TIPCManager.ProcessMessages;
var
  Buffer: array[0..MAX_CHUNK_SIZE + SizeOf(TChunkHeader) - 1] of Byte;
  ActualSize: Integer;
  Header: TChunkHeader;
begin
  while FRingBuffer.TryDequeue(Buffer[0], SizeOf(Buffer), ActualSize) do
  begin
    if ActualSize >= SizeOf(TChunkHeader) then
    begin
      Move(Buffer[0], Header, SizeOf(TChunkHeader));
      ProcessChunk(Header, @Buffer[SizeOf(TChunkHeader)]);
    end;
  end;
end;

end.