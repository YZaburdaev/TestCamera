unit IPCManager.Hybrid;

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  System.SyncObjs,
  LockFreeRingBuffer;

const
  SMALL_MSG_MAX_SIZE = 16384;
  LARGE_MSG_CHUNK_SIZE = 65536;

  MSG_FLAG_SMALL      = $0001;
  MSG_FLAG_CHUNKED    = $0002;
  MSG_FLAG_FIRST      = $0004;
  MSG_FLAG_MIDDLE     = $0008;
  MSG_FLAG_LAST       = $0010;

type
  TMessageHeader = packed record
    MsgType: UInt16;
    Flags: UInt16;
    TotalSize: UInt32;
    MsgID: UInt64;
    ChunkIndex: UInt32;
    ChunkSize: UInt32;
  end;

  TIPCMessage = record
    MsgType: Integer;
    Data: TBytes;
    Timestamp: TDateTime;
  end;

  TMessageEvent = procedure(const Msg: TIPCMessage) of object;
  TMessageErrorEvent = procedure(const ErrorMsg: string) of object;

  // Основной потокобезопасный IPC класс
  TIPCManager = class
  private
    FBuffer: TLockFreeRingBuffer;
    FMessageBuilders: TObjectDictionary<UInt64, TBytes>;
    FBuilderSizes: TDictionary<UInt64, Integer>;
    FBuilderOffsets: TDictionary<UInt64, Integer>;
    FCriticalSection: TCriticalSection;
    FListenerThread: TThread;
    FListenerActive: Boolean;
    FListenerInterval: Integer;
    FOnMessage: TMessageEvent;
    FOnError: TMessageErrorEvent;

    procedure SendSmallMessage(MsgType: UInt16; const Data: TBytes);
    procedure SendChunkedMessage(MsgType: UInt16; const Data: TBytes);
    function BuildPacket(const Header: TMessageHeader; const Data: TBytes;
      DataOffset: Integer): TBytes;
    function CheckFlag(Flags: UInt16; Flag: UInt16): Boolean;
    procedure ProcessMessages;
    procedure CleanupOldMessages;
  protected
    procedure DoMessage(const Msg: TIPCMessage); virtual;
    procedure DoError(const ErrorMsg: string); virtual;
  public
    constructor Create(const AName: string; BufferSize: Integer = 1024 * 1024 * 5);
    destructor Destroy; override;

    // Отправка сообщений (потокобезопасно из любого потока)
    procedure Send(MsgType: Integer; const Data: TBytes); overload;
    procedure Send(MsgType: Integer; const Text: string); overload;
    procedure Send(MsgType: Integer; Stream: TStream); overload;

    // Управление Listener'ом
    procedure StartListener(IntervalMS: Integer = 10);
    procedure StopListener;
    procedure PauseListener;
    procedure ResumeListener;

    // Принудительная обработка сообщений (для синхронного использования)
    procedure ProcessPendingMessages;

    // Свойства
    property OnMessage: TMessageEvent read FOnMessage write FOnMessage;
    property OnError: TMessageErrorEvent read FOnError write FOnError;
    property ListenerActive: Boolean read FListenerActive;
    property ListenerInterval: Integer read FListenerInterval write FListenerInterval;
  end;

  // Поток для Listener'а
  TIPCListenerThread = class(TThread)
  private
    FIPC: TIPCManager;
    FInterval: Integer;
    FPaused: Boolean;
    FPauseEvent: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(AIPC: TIPCManager; IntervalMS: Integer);
    destructor Destroy; override;

    procedure Pause;
    procedure Resume;
  end;

implementation

uses
  Winapi.Windows, System.DateUtils;

{ TIPCListenerThread }

constructor TIPCListenerThread.Create(AIPC: TIPCManager; IntervalMS: Integer);
begin
  inherited Create(False);
  FreeOnTerminate := False;

  FIPC := AIPC;
  FInterval := IntervalMS;
  FPaused := False;
  FPauseEvent := TEvent.Create(nil, True, False, '');
end;

destructor TIPCListenerThread.Destroy;
begin
  FreeAndNil(FPauseEvent);
  inherited;
end;

procedure TIPCListenerThread.Execute;
begin
  while not Terminated do
  begin
    if FPaused then
      FPauseEvent.WaitFor(INFINITE)
    else
    begin
      try
        FIPC.ProcessMessages;

        // Периодическая очистка
        if GetTickCount mod 5000 = 0 then // Каждые 5 секунд
          FIPC.CleanupOldMessages;

      except
        on E: Exception do
          FIPC.DoError('Listener error: ' + E.Message);
      end;

      if FInterval > 0 then
        Sleep(FInterval);
    end;
  end;
end;

procedure TIPCListenerThread.Pause;
begin
  FPaused := True;
  FPauseEvent.ResetEvent;
end;

procedure TIPCListenerThread.Resume;
begin
  FPaused := False;
  FPauseEvent.SetEvent;
end;

{ TIPCManager }

constructor TIPCManager.Create(const AName: string; BufferSize: Integer);
begin
  inherited Create;

  FBuffer := TLockFreeRingBuffer.Create(AName, BufferSize);
//  FMessageBuilders := TObjectDictionary<UInt64, TBytes>.Create([doOwnsValues]);
  FMessageBuilders := TObjectDictionary<UInt64, TBytes>.Create([]);
  FBuilderSizes := TDictionary<UInt64, Integer>.Create;
  FBuilderOffsets := TDictionary<UInt64, Integer>.Create;
  FCriticalSection := TCriticalSection.Create;
  FListenerActive := False;
  FListenerInterval := 10;
end;

destructor TIPCManager.Destroy;
begin
  StopListener;

  FreeAndNil(FCriticalSection);
  FreeAndNil(FBuilderOffsets);
  FreeAndNil(FBuilderSizes);
  FreeAndNil(FMessageBuilders);
  FreeAndNil(FBuffer);

  inherited;
end;

function TIPCManager.CheckFlag(Flags: UInt16; Flag: UInt16): Boolean;
begin
  Result := (Flags and Flag) <> 0;
end;

procedure TIPCManager.DoMessage(const Msg: TIPCMessage);
begin
  if Assigned(FOnMessage) then
    FOnMessage(Msg);
end;

procedure TIPCManager.DoError(const ErrorMsg: string);
begin
  if Assigned(FOnError) then
    FOnError(ErrorMsg);
end;

// === ОТПРАВКА СООБЩЕНИЙ (потокобезопасно) ===

procedure TIPCManager.Send(MsgType: Integer; const Data: TBytes);
begin
  try
    if Length(Data) <= SMALL_MSG_MAX_SIZE then
      SendSmallMessage(MsgType and $FFFF, Data)
    else
      SendChunkedMessage(MsgType and $FFFF, Data);
  except
    on E: Exception do
      DoError('Send error: ' + E.Message);
  end;
end;

procedure TIPCManager.Send(MsgType: Integer; const Text: string);
var
  Bytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(Text);
  Send(MsgType, Bytes);
end;

procedure TIPCManager.Send(MsgType: Integer; Stream: TStream);
var
  Bytes: TBytes;
begin
  if Stream.Size > 0 then
  begin
    SetLength(Bytes, Stream.Size);
    Stream.Position := 0;
    Stream.Read(Bytes[0], Stream.Size);
    Send(MsgType, Bytes);
  end;
end;

procedure TIPCManager.SendSmallMessage(MsgType: UInt16; const Data: TBytes);
var
  Header: TMessageHeader;
  Packet: TBytes;
  MsgID: UInt64;
begin
  ZeroMemory(@Header, SizeOf(Header));

  MsgID := GetTickCount64 xor (GetCurrentProcessId shl 32);

  Header.MsgType := MsgType;
  Header.Flags := MSG_FLAG_SMALL;
  Header.TotalSize := Length(Data);
  Header.MsgID := MsgID;
  Header.ChunkIndex := 0;
  Header.ChunkSize := Length(Data);

  Packet := BuildPacket(Header, Data, 0);
  if not FBuffer.TryWrite(Packet[0], Length(Packet)) then
    raise Exception.Create('Buffer is full');
end;

procedure TIPCManager.SendChunkedMessage(MsgType: UInt16; const Data: TBytes);
var
  Header: TMessageHeader;
  TotalSize, ChunkCount, i: Integer;
  ChunkSize, Offset: Integer;
  Packet: TBytes;
  Flags: UInt16;
  MsgID: UInt64;
begin
  TotalSize := Length(Data);
  ChunkCount := (TotalSize + LARGE_MSG_CHUNK_SIZE - 1) div LARGE_MSG_CHUNK_SIZE;
  MsgID := GetTickCount64 xor (GetCurrentProcessId shl 32);
  Offset := 0;

  for I := 0 to ChunkCount - 1 do
  begin
    ZeroMemory(@Header, SizeOf(Header));

    Flags := MSG_FLAG_CHUNKED;
    if I = 0 then
      Flags := Flags or MSG_FLAG_FIRST
    else if I = ChunkCount - 1 then
      Flags := Flags or MSG_FLAG_LAST
    else
      Flags := Flags or MSG_FLAG_MIDDLE;

    Header.MsgType := MsgType;
    Header.Flags := Flags;
    Header.TotalSize := TotalSize;
    Header.MsgID := MsgID;
    Header.ChunkIndex := I;

    if I = ChunkCount - 1 then
      ChunkSize := TotalSize - Offset
    else
      ChunkSize := LARGE_MSG_CHUNK_SIZE;

    Header.ChunkSize := ChunkSize;

    Packet := BuildPacket(Header, Data, Offset);
    if not FBuffer.TryWrite(Packet[0], Length(Packet)) then
      raise Exception.CreateFmt('Buffer full at chunk %d', [I]);

    Inc(Offset, ChunkSize);
  end;
end;

function TIPCManager.BuildPacket(const Header: TMessageHeader;
  const Data: TBytes; DataOffset: Integer): TBytes;
var
  DataSize: Integer;
begin
  DataSize := Header.ChunkSize;
  SetLength(Result, SizeOf(Header) + DataSize);

  Move(Header, Result[0], SizeOf(Header));

  if (DataSize > 0) and (DataOffset + DataSize <= Length(Data)) then
    Move(Data[DataOffset], Result[SizeOf(Header)], DataSize);
end;

// === ОБРАБОТКА ВХОДЯЩИХ СООБЩЕНИЙ (потокобезопасно) ===

procedure TIPCManager.ProcessMessages;
var
  Packet: TBytes;
  ActualSize: Integer;
  Header: TMessageHeader;
  PacketData: PByte;
  MsgID: UInt64;
  CompleteMsg: TIPCMessage;
  Buffer: TBytes;
  CurrentOffset: Integer;
begin
  while True do
  begin
    // Пытаемся прочитать заголовок
    var HeaderSize := SizeOf(Header);
    SetLength(Packet, HeaderSize);
    if not FBuffer.Peek(Packet[0], HeaderSize, ActualSize) or
       (ActualSize < HeaderSize) then
      Break;

//    if not FBuffer.TryRead(Packet[0], HeaderSize, ActualSize) or
//       (ActualSize < HeaderSize) then
//      Break;

    Move(Packet[0], Header, HeaderSize);

    // Читаем полный пакет
    SetLength(Packet, HeaderSize + Header.ChunkSize);
    if not FBuffer.TryRead(Packet[0], Length(Packet), ActualSize) or
       (ActualSize <> Length(Packet)) then
      Break;

//    // Читаем данные пакета
//    SetLength(Packet, Header.ChunkSize);
//    if Header.ChunkSize > 0 then
//    begin
//      if not FBuffer.TryRead(Packet[0], Length(Packet), ActualSize) or
//         (ActualSize <> Length(Packet)) then
//        Break;
//
//      PacketData := @Packet[0];
//    end;

    if Header.ChunkSize > 0 then
      PacketData := @Packet[SizeOf(Header)];
    MsgID := Header.MsgID;

    FCriticalSection.Enter;
    try
      if CheckFlag(Header.Flags, MSG_FLAG_SMALL) then
      begin
        // Маленькое сообщение - сразу обрабатываем
        CompleteMsg.MsgType := Header.MsgType;
        SetLength(CompleteMsg.Data, Header.ChunkSize);
        if Header.ChunkSize > 0 then
          Move(PacketData^, CompleteMsg.Data[0], Header.ChunkSize);
        CompleteMsg.Timestamp := Now;

        DoMessage(CompleteMsg);
      end
      else if CheckFlag(Header.Flags, MSG_FLAG_CHUNKED) then
      begin
        // Чанкованное сообщение
        // Тут предполагаем, что у нас не может быть чанка, у которого Header.ChunkSize = 0
        if CheckFlag(Header.Flags, MSG_FLAG_FIRST) then
        begin
          // Первый чанк - создаем буфер
          if not FMessageBuilders.ContainsKey(MsgID) then
          begin
            SetLength(Buffer, Header.TotalSize);
            FMessageBuilders.Add(MsgID, Buffer);
            FBuilderOffsets.Add(MsgID, 0);
            FBuilderSizes.Add(MsgID, Header.TotalSize);
          end;
        end;

        if FMessageBuilders.TryGetValue(MsgID, Buffer) and
           FBuilderOffsets.TryGetValue(MsgID, CurrentOffset) then
        begin
          // Копируем данные чанка
          if (CurrentOffset + Header.ChunkSize <= Header.TotalSize) then
          begin
            Move(PacketData^, Buffer[CurrentOffset], Header.ChunkSize);

            // Обновляем смещение
            FBuilderOffsets[MsgID] := CurrentOffset + Header.ChunkSize;

            // Если последний чанк - сообщение готово
            if CheckFlag(Header.Flags, MSG_FLAG_LAST) then
            begin
              CompleteMsg.MsgType := Header.MsgType;
              CompleteMsg.Data := Copy(Buffer, 0, Header.TotalSize);
              CompleteMsg.Timestamp := Now;

              DoMessage(CompleteMsg);

              // Удаляем временные данные
              FMessageBuilders.Remove(MsgID);
              FBuilderOffsets.Remove(MsgID);
              FBuilderSizes.Remove(MsgID);
            end;
          end;
        end;
      end;
    finally
      FCriticalSection.Leave;
    end;
  end;
end;

procedure TIPCManager.CleanupOldMessages;
var
  MsgID: UInt64;
  Timeout: Cardinal;
  KeysToRemove: TList<UInt64>;
begin
  // Удаляем сообщения, которые собираются дольше 30 секунд
  Timeout := 30000;
  KeysToRemove := TList<UInt64>.Create;
  try
    FCriticalSection.Enter;
    try
      for MsgID in FMessageBuilders.Keys do
      begin
        // Простая проверка по MsgID (первые 32 бита содержат timestamp)
        if (GetTickCount64 - (MsgID and $FFFFFFFF)) > Timeout then
          KeysToRemove.Add(MsgID);
      end;

      for MsgID in KeysToRemove do
      begin
        FMessageBuilders.Remove(MsgID);
        FBuilderOffsets.Remove(MsgID);
        FBuilderSizes.Remove(MsgID);
      end;
    finally
      FCriticalSection.Leave;
    end;
  finally
    KeysToRemove.Free;
  end;
end;

// === УПРАВЛЕНИЕ LISTENER'ОМ ===

procedure TIPCManager.StartListener(IntervalMS: Integer = 10);
begin
  if FListenerActive then
    Exit;

  FListenerInterval := IntervalMS;
  FListenerActive := True;

  FListenerThread := TIPCListenerThread.Create(Self, FListenerInterval);
end;

procedure TIPCManager.StopListener;
begin
  if not FListenerActive then
    Exit;

  FListenerActive := False;

  if Assigned(FListenerThread) then
  begin
    FListenerThread.Terminate;
    FListenerThread.WaitFor;
    FreeAndNil(FListenerThread);
  end;
end;

procedure TIPCManager.PauseListener;
begin
  if Assigned(FListenerThread) then
    TIPCListenerThread(FListenerThread).Pause;
end;

procedure TIPCManager.ResumeListener;
begin
  if Assigned(FListenerThread) then
    TIPCListenerThread(FListenerThread).Resume;
end;

// === СИНХРОННАЯ ОБРАБОТКА (для ручного вызова) ===

procedure TIPCManager.ProcessPendingMessages;
begin
  ProcessMessages;
end;

end.
