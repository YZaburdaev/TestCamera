unit LockFreeRingBuffer;

interface

uses
  Winapi.Windows, System.SysUtils, SharedMemory;

type
  // Упрощенный lock-free ring buffer без поддержки переноса данных
  // Более надежный и быстрый, но требует, чтобы данные помещались непрерывно
  TLockFreeRingBuffer = class
  private const
    c_Begin = $01;
    c_End = $02;
    c_MagicWord = 0;
  private
    FSharedMem: TSharedMemory;
    FBuffer: PByte;
    FCapacity: Integer;       // Емкость для данных
    FHead: PInteger;          // Указатель на голову (запись)
    FTail: PInteger;          // Указатель на хвост (чтение)
    FDataStart: PByte;        // Начало области данных
    FInitialized: Boolean;

    function CheckData(var Data; Size: Integer): Boolean;
    // Вспомогательные методы
    function GetAvailableSpace(Head, Tail: Integer): Integer;
    function GetUsedSpace(Head, Tail: Integer): Integer;
  public
    constructor Create(const AName: string; ACapacity: Integer;
      AOpenExisting: Boolean = False);
    destructor Destroy; override;

    // Основные операции
    function TryWrite(const Data; Size: Integer): Boolean;
    function TryRead(var Data; MaxSize: Integer; out ActualSize: Integer): Boolean;
    function Peek(var Data; MaxSize: Integer; out ActualSize: Integer): Boolean;

    // Статистика
    function AvailableSpace: Integer;
    function UsedSpace: Integer;

    // Управление
    procedure Clear;
    function IsEmpty: Boolean;

    property Capacity: Integer read FCapacity;
    property Initialized: Boolean read FInitialized;
  end;

implementation

const
  HEADER_PADDING = 64; // Разделяем Head и Tail для предотвращения false sharing

{ TLockFreeRingBuffer }

constructor TLockFreeRingBuffer.Create(const AName: string; ACapacity: Integer;
  AOpenExisting: Boolean);
var
  TotalSize: Integer;
begin
  inherited Create;

  // Минимальная емкость
  if ACapacity < 1024 then
    ACapacity := 1024;

  // Общий размер = заголовки + данные
  TotalSize := SizeOf(Integer) * 2 + HEADER_PADDING + ACapacity;

  // Создаем shared memory
  FSharedMem := TSharedMemory.Create(AName, TotalSize, AOpenExisting);
  FBuffer := FSharedMem.Data;

  // Устанавливаем указатели
  FHead := PInteger(FBuffer);
  FTail := PInteger(PByte(FBuffer) + SizeOf(Integer) + HEADER_PADDING);
  FDataStart := PByte(FBuffer) + SizeOf(Integer) * 2 + HEADER_PADDING;
  FCapacity := ACapacity;

  // Инициализация при создании
  if not AOpenExisting then
  begin
    FHead^ := 0;
    FTail^ := 0;
    MemoryBarrier;
  end;

  FInitialized := True;
end;

destructor TLockFreeRingBuffer.Destroy;
begin
  FInitialized := False;
  FreeAndNil(FSharedMem);
  inherited;
end;

function TLockFreeRingBuffer.GetAvailableSpace(Head, Tail: Integer): Integer;
begin
  if Head >= Tail then
    Result := FCapacity - (Head - Tail)
  else
    Result := Tail - Head;

  // Оставляем место для различения пустого/полного
  Result := Result - 1;
end;

function TLockFreeRingBuffer.GetUsedSpace(Head, Tail: Integer): Integer;
begin
  if Head >= Tail then
    Result := Head - Tail
  else
    Result := FCapacity - (Tail - Head);
end;

function TLockFreeRingBuffer.AvailableSpace: Integer;
var
  Head, Tail: Integer;
begin
  if not FInitialized then
    Exit(0);

  Head := InterlockedCompareExchange(FHead^, 0, 0);
  Tail := InterlockedCompareExchange(FTail^, 0, 0);

  Result := GetAvailableSpace(Head, Tail);
  if Result < 0 then
    Result := 0;
end;

function TLockFreeRingBuffer.UsedSpace: Integer;
var
  Head, Tail: Integer;
begin
  if not FInitialized then
    Exit(0);

  Head := InterlockedCompareExchange(FHead^, 0, 0);
  Tail := InterlockedCompareExchange(FTail^, 0, 0);

  Result := GetUsedSpace(Head, Tail);
end;

function TLockFreeRingBuffer.TryWrite(const Data; Size: Integer): Boolean;
var
  CurrentHead, CurrentTail, FreeSpace, NextHead: Integer;
  PacketSize: Integer;
begin
  Result := False;

  if (Size <= 0) or (Size > FCapacity - SizeOf(Integer)) or (not FInitialized) then
    Exit(False);

  // Размер пакета: размер данных + размер заголовка
  PacketSize := SizeOf(Integer) + Size;

  repeat
    // Читаем текущие позиции
    CurrentHead := InterlockedCompareExchange(FHead^, 0, 0);
    CurrentTail := InterlockedCompareExchange(FTail^, 0, 0);

    // Вычисляем свободное место
    FreeSpace := GetAvailableSpace(CurrentHead, CurrentTail);

    // Проверяем, поместится ли пакет непрерывно
    // (без переноса через границу буфера)
    if CurrentHead + PacketSize <= FCapacity then
    begin
      // Пакет помещается без переноса
      if FreeSpace < PacketSize then
        Exit(False);

      NextHead := CurrentHead + PacketSize;
    end
    else
    begin
      // Пакет не помещается до конца буфера
      // Проверяем, поместится ли с начала буфера
      if PacketSize > CurrentHead then
        Exit(False); // Недостаточно места

      // Пакет помещается с переносом
      // Нужно проверить свободное место с учетом переноса
      if FreeSpace < PacketSize then
        Exit(False);

      NextHead := PacketSize - (FCapacity - CurrentHead);
    end;

    // Пытаемся атомарно установить новую позицию головы
  until InterlockedCompareExchange(FHead^, NextHead, CurrentHead) = CurrentHead;

  // Записываем данные
  if NextHead < CurrentHead then
  begin
    // Запись с переносом
    // 1. Записываем размер в конец буфера
    if FCapacity - CurrentHead >= SizeOf(Integer) then
    begin
      PInteger(FDataStart + CurrentHead)^ := Size;

      // 2. Записываем данные
      if Size > 0 then
      begin
        // Первая часть данных (до конца буфера)
        if FCapacity - (CurrentHead + SizeOf(Integer)) >= Size then
        begin
          Move(Data, (FDataStart + CurrentHead + SizeOf(Integer))^, Size);
        end
        else
        begin
          // Данные разбиты - записываем частями
          Move(Data, (FDataStart + CurrentHead + SizeOf(Integer))^,
            FCapacity - (CurrentHead + SizeOf(Integer)));
          Move(PByte(@Data)[FCapacity - (CurrentHead + SizeOf(Integer))],
            FDataStart^, Size - (FCapacity - (CurrentHead + SizeOf(Integer))));
        end;
      end;
    end
    else
    begin
      // Размер разбит - сложный случай, откатываем
      InterlockedCompareExchange(FHead^, CurrentHead, NextHead);
      Exit(False);
    end;
  end
  else
  begin
    // Запись без переноса
    // Записываем размер
    PInteger(FDataStart + CurrentHead)^ := Size;

    // Записываем данные
    if Size > 0 then
      Move(Data, (FDataStart + CurrentHead + SizeOf(Integer))^, Size);
  end;

  MemoryBarrier;
  Result := True;
end;

function TLockFreeRingBuffer.TryRead(var Data; MaxSize: Integer;
  out ActualSize: Integer): Boolean;
var
  CurrentHead, CurrentTail, Size, NextTail, DataStart: Integer;
begin
  Result := False;
  ActualSize := 0;

  if (MaxSize <= 0) or (not FInitialized) then
    Exit;

  repeat
    // Читаем текущие позиции
    CurrentHead := InterlockedCompareExchange(FHead^, 0, 0);
    CurrentTail := InterlockedCompareExchange(FTail^, 0, 0);

    // Проверяем, есть ли данные
    if CurrentHead = CurrentTail then
      Exit(False);

    // Определяем, где находятся данные
    if CurrentTail < CurrentHead then
    begin
      // Данные непрерывны
      DataStart := CurrentTail;
    end
    else
    begin
      // Данные разбиты (хвост после головы)
      DataStart := CurrentTail;
    end;

    // Читаем размер данных
    Size := PInteger(FDataStart + DataStart)^;

    // Проверяем корректность размера
    if (Size <= 0) or (Size > FCapacity) then
    begin
      // Поврежденные данные - сбрасываем
      Clear;
      Exit(False);
    end;

    // Проверяем, поместится ли в буфер получателя
    if Size > MaxSize then
    begin
      ActualSize := Size;
      Exit(False);
    end;

    // Вычисляем новую позицию хвоста
    NextTail := DataStart + SizeOf(Integer) + Size;
    if NextTail >= FCapacity then
      NextTail := NextTail - FCapacity;

    // Пытаемся атомарно установить новую позицию хвоста
  until InterlockedCompareExchange(FTail^, NextTail, CurrentTail) = CurrentTail;

  // Читаем данные
  if Size > 0 then
  begin
    if DataStart + SizeOf(Integer) + Size <= FCapacity then
    begin
      // Данные непрерывны
      Move((FDataStart + DataStart + SizeOf(Integer))^, Data, Size);
    end
    else
    begin
      // Данные разбиты
      // Первая часть (до конца буфера)
      Move((FDataStart + DataStart + SizeOf(Integer))^, Data,
        FCapacity - (DataStart + SizeOf(Integer)));

      // Вторая часть (с начала буфера)
      Move(FDataStart^, PByte(@Data)[FCapacity - (DataStart + SizeOf(Integer))],
        Size - (FCapacity - (DataStart + SizeOf(Integer))));
    end;
  end;

  ActualSize := Size;
  Result := True;
  MemoryBarrier;
end;

function TLockFreeRingBuffer.Peek(var Data; MaxSize: Integer;
  out ActualSize: Integer): Boolean;
var
  CurrentHead, CurrentTail, Size, DataStart: Integer;
begin
  Result := False;
  ActualSize := 0;

  if (MaxSize <= 0) or (not FInitialized) then
    Exit;

  var Count: Integer := 0;
  repeat
    Inc(Count);

    // Читаем текущие позиции (без изменения)
    CurrentHead := InterlockedCompareExchange(FHead^, 0, 0);
    CurrentTail := InterlockedCompareExchange(FTail^, 0, 0);

    if CurrentHead = CurrentTail then
      Exit(False);

    // Определяем начало данных
    DataStart := CurrentTail;

    // Читаем размер
    Size := PInteger(FDataStart + DataStart)^;

    if (Size <= 0) or (Size > FCapacity) then
      Exit(False);

    ActualSize := Size;

    if Size < MaxSize then
      Exit(False);

    Size := MaxSize;

    // Читаем данные (без изменения состояния)
    if DataStart + SizeOf(Integer) + Size <= FCapacity then
      Move((FDataStart + DataStart + SizeOf(Integer))^, Data, Size)
    else
    begin
      // Данные разбиты
      Move((FDataStart + DataStart + SizeOf(Integer))^, Data,
        FCapacity - (DataStart + SizeOf(Integer)));
      Move(FDataStart^, PByte(@Data)[FCapacity - (DataStart + SizeOf(Integer))],
        Size - (FCapacity - (DataStart + SizeOf(Integer))));
    end;

    // Определяем корректность данных. Предполагаем, что если адрес заголовка
    // поменялся, то это означает, что буффер был перезаписан
    Result := CurrentHead = InterlockedCompareExchange(FHead^, 0, 0);
  until (Count = 2) or Result;

//  if not Result then
//    Похоже, что или данные не корректны или адрес заголовка изменился, т.е. буфер перезаписан
end;

function TLockFreeRingBuffer.CheckData(var Data; Size: Integer): Boolean;
begin
  Result := False;

  if Size <= 0 then
    Exit;


end;

procedure TLockFreeRingBuffer.Clear;
begin
  if not FInitialized then
    Exit;

  InterlockedExchange(FHead^, 0);
  InterlockedExchange(FTail^, 0);
  MemoryBarrier;
end;

function TLockFreeRingBuffer.IsEmpty: Boolean;
var
  Head, Tail: Integer;
begin
  if not FInitialized then
    Exit(True);

  Head := InterlockedCompareExchange(FHead^, 0, 0);
  Tail := InterlockedCompareExchange(FTail^, 0, 0);

  Result := Head = Tail;
end;

end.
