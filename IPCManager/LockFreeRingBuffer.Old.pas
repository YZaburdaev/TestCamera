unit LockFreeRingBuffer;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, SharedMemory;

type
  TLockFreeRingBuffer = class
  private
    FSharedMem: TSharedMemory;
    FBuffer: PByte;
    FSize: Integer;
    FHead: PInteger;
    FTail: PInteger;
    FDataStart: PByte;
    FCapacity: Integer;
    
    function GetFreeSpace: Integer;
    function GetUsedSpace: Integer;
  public
    constructor Create(const AName: string; ACapacity: Integer; AOpenExisting: Boolean = False);
    destructor Destroy; override;
    
    function TryEnqueue(const Data; Size: Integer): Boolean;
    function TryDequeue(var Data; MaxSize: Integer; out ActualSize: Integer): Boolean;
    function Peek(var Data; MaxSize: Integer; out ActualSize: Integer): Boolean;
    
    procedure Clear;
    
    property Capacity: Integer read FCapacity;
    property FreeSpace: Integer read GetFreeSpace;
    property UsedSpace: Integer read GetUsedSpace;
  end;

implementation

{ TLockFreeRingBuffer }

constructor TLockFreeRingBuffer.Create(const AName: string; ACapacity: Integer; 
  AOpenExisting: Boolean);
var
  TotalSize: Integer;
begin
  inherited Create;
  
  FCapacity := ACapacity;
  
  // Размер = заголовок (2 * SizeOf(Integer)) + буфер данных
  TotalSize := SizeOf(Integer) * 2 + FCapacity;
  
  FSharedMem := TSharedMemory.Create(AName, TotalSize, AOpenExisting);
  FBuffer := FSharedMem.Data;
  
  // Указатели на head и tail
  FHead := PInteger(FBuffer);
  FTail := PInteger(PByte(FBuffer) + SizeOf(Integer));
  FDataStart := PByte(FBuffer) + SizeOf(Integer) * 2;
  FSize := FCapacity;
  
  // Инициализация при создании
  if not AOpenExisting then
  begin
    FHead^ := 0;
    FTail^ := 0;
  end;
end;

destructor TLockFreeRingBuffer.Destroy;
begin
  FreeAndNil(FSharedMem);
  inherited;
end;

function TLockFreeRingBuffer.GetFreeSpace: Integer;
var
  Head, Tail: Integer;
begin
  Head := FHead^;
  Tail := FTail^;
  
  if Head >= Tail then
    Result := FCapacity - (Head - Tail)
  else
    Result := Tail - Head;
    
  // Оставляем 1 байт для различения пустого/полного состояния
  Result := Result - 1;
end;

function TLockFreeRingBuffer.GetUsedSpace: Integer;
begin
  Result := FCapacity - GetFreeSpace;
end;

function TLockFreeRingBuffer.TryEnqueue(const Data; Size: Integer): Boolean;
var
  Head, Tail, NextHead, Free: Integer;
  Ptr: PByte;
begin
  if Size <= 0 then
    Exit(False);
    
  // Проверяем, поместится ли заголовок размера + данные
  if Size > FCapacity - SizeOf(Integer) then
    Exit(False);
    
  repeat
    Head := FHead^;
    Tail := FTail^;
    
    if Head >= Tail then
      Free := FCapacity - (Head - Tail)
    else
      Free := Tail - Head;
      
    Free := Free - 1; // Для различения пустого/полного
    
    if Free < Size + SizeOf(Integer) then
      Exit(False);
      
    NextHead := Head + Size + SizeOf(Integer);
    if NextHead >= FCapacity then
      NextHead := 0;
      
    // Пытаемся атомарно установить новый head
  until InterlockedCompareExchange(FHead^, NextHead, Head) = Head;
  
  // Записываем данные
  Ptr := FDataStart + Head;
  
  // Записываем размер данных
  PInteger(Ptr)^ := Size;
  Inc(Ptr, SizeOf(Integer));
  
  // Записываем сами данные
  Move(Data, Ptr^, Size);
  
  // Memory barrier для гарантии видимости записи
  MemoryBarrier;
  
  Result := True;
end;

function TLockFreeRingBuffer.TryDequeue(var Data; MaxSize: Integer; 
  out ActualSize: Integer): Boolean;
var
  Head, Tail, Size, NextTail: Integer;
  Ptr: PByte;
begin
  Result := False;
  ActualSize := 0;
  
  repeat
    Head := FHead^;
    Tail := FTail^;
    
    if Head = Tail then
      Exit(False); // Буфер пуст
      
    // Читаем размер следующего элемента
    Ptr := FDataStart + Tail;
    Size := PInteger(Ptr)^;
    
    if Size > MaxSize then
      Exit(False);
      
    NextTail := Tail + Size + SizeOf(Integer);
    if NextTail >= FCapacity then
      NextTail := 0;
      
    // Проверяем, не коррумпированы ли данные
    if (Size <= 0) or (Size > FCapacity) then
      Exit(False);
      
    // Пытаемся атомарно установить новый tail
  until InterlockedCompareExchange(FTail^, NextTail, Tail) = Tail;
  
  // Читаем данные
  Inc(Ptr, SizeOf(Integer));
  Move(Ptr^, Data, Size);
  ActualSize := Size;
  
  Result := True;
end;

function TLockFreeRingBuffer.Peek(var Data; MaxSize: Integer; 
  out ActualSize: Integer): Boolean;
var
  Head, Tail, Size: Integer;
  Ptr: PByte;
begin
  Head := FHead^;
  Tail := FTail^;
  
  if Head = Tail then
  begin
    ActualSize := 0;
    Exit(False);
  end;
  
  Ptr := FDataStart + Tail;
  Size := PInteger(Ptr)^;
  
  if Size > MaxSize then
  begin
    ActualSize := Size;
    Exit(False);
  end;
  
  Inc(Ptr, SizeOf(Integer));
  Move(Ptr^, Data, Size);
  ActualSize := Size;
  
  Result := True;
end;

procedure TLockFreeRingBuffer.Clear;
begin
  // Атомарно сбрасываем head и tail
  InterlockedExchange(FHead^, 0);
  InterlockedExchange(FTail^, 0);
end;

end.