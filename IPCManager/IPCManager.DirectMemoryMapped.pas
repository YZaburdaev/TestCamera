unit IPCManager.DirectMemoryMapped;

interface

uses
  System.Classes, System.SysUtils, SharedMemory, LockFreeRingBuffer;

type
  TDataDescriptor = packed record
    MsgID: UInt64;
    DataSize: UInt32;
    DataOffset: UInt32; // Смещение в shared memory
    SharedMemName: array[0..63] of AnsiChar; // Имя shared memory с данными
  end;
  PDataDescriptor = ^TDataDescriptor;

  TIPCManager = class
  private
    FControlBuffer: TLockFreeRingBuffer; // Для дескрипторов
    FDataMemories: TObjectDictionary<string, TSharedMemory>;
    FCriticalSection: TCriticalSection;
    
    function GetSharedMemory(const Name: string; Size: Cardinal): TSharedMemory;
    procedure CleanupOldMemories;
  public
    constructor Create(const AName: string);
    destructor Destroy; override;
    
    procedure SendLargeData(MsgType: Integer; const Data: TBytes);
    function ReceiveLargeData(var Data: TBytes): Boolean;
  end;

implementation

uses
  System.Generics.Collections, System.DateUtils, Winapi.Windows;

{ TIPCManager }

constructor TIPCManager.Create(const AName: string);
begin
  inherited Create;
  
  FControlBuffer := TLockFreeRingBuffer.Create(AName + '_Control', 1024 * 1024);
  FDataMemories := TObjectDictionary<string, TSharedMemory>.Create([doOwnsValues]);
  FCriticalSection := TCriticalSection;
  
  // Таймер для очистки старых shared memory
  // Можно реализовать через отдельный поток
end;

destructor TIPCManager.Destroy;
begin
  CleanupOldMemories;
  FreeAndNil(FDataMemories);
  FreeAndNil(FControlBuffer);
  FreeAndNil(FCriticalSection);
  inherited;
end;

procedure TIPCManager.SendLargeData(MsgType: Integer; const Data: TBytes);
var
  DataSize: Cardinal;
  MemName: string;
  SharedMem: TSharedMemory;
  Descriptor: TDataDescriptor;
  MsgID: UInt64;
begin
  DataSize := Length(Data);
  if DataSize = 0 then
    Exit;
    
  // Генерируем уникальный ID и имя shared memory
  QueryPerformanceCounter(PInt64(@MsgID)^);
  MemName := Format('%s_Data_%x_%d', [FControlBuffer.Name, GetCurrentProcessId, MsgID]);
  
  // Создаем shared memory для данных
  SharedMem := TSharedMemory.Create(MemName, DataSize);
  try
    // Копируем данные
    SharedMem.Write(Data[0], 0, DataSize);
    
    // Создаем дескриптор
    Descriptor.MsgID := MsgID;
    Descriptor.DataSize := DataSize;
    Descriptor.DataOffset := 0;
    StrPCopy(Descriptor.SharedMemName, AnsiString(MemName));
    
    // Отправляем дескриптор через control buffer
    FControlBuffer.TryEnqueue(Descriptor, SizeOf(Descriptor));
    
  finally
    // Не освобождаем shared memory - получатель должен прочитать данные
  end;
end;

function TIPCManager.GetSharedMemory(const Name: string; Size: Cardinal): TSharedMemory;
begin
  FCriticalSection.Enter;
  try
    if not FDataMemories.TryGetValue(Name, Result) then
    begin
      Result := TSharedMemory.Create(Name, Size, True); // Открываем существующий
      FDataMemories.Add(Name, Result);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

function TIPCManager.ReceiveLargeData(var Data: TBytes): Boolean;
var
  Descriptor: TDataDescriptor;
  ActualSize: Integer;
  SharedMem: TSharedMemory;
begin
  Result := False;
  
  // Читаем дескриптор
  if FControlBuffer.TryDequeue(Descriptor, SizeOf(Descriptor), ActualSize) and
     (ActualSize = SizeOf(Descriptor)) then
  begin
    // Открываем shared memory с данными
    SharedMem := GetSharedMemory(string(Descriptor.SharedMemName), Descriptor.DataSize);
    
    if SharedMem.IsValid then
    begin
      // Читаем данные
      SetLength(Data, Descriptor.DataSize);
      Result := SharedMem.Read(Data[0], Descriptor.DataOffset, Descriptor.DataSize);
      
      // Закрываем shared memory после чтения
      FDataMemories.Remove(string(Descriptor.SharedMemName));
    end;
  end;
end;

procedure TIPCManager.CleanupOldMemories;
var
  Keys: TArray<string>;
  Key: string;
begin
  FCriticalSection.Enter;
  try
    Keys := FDataMemories.Keys.ToArray;
    for Key in Keys do
    begin
      // Можно добавить логику очистки по времени
      FDataMemories.Remove(Key);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

end.