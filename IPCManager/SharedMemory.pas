unit SharedMemory;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs;

type
  ESharedMemoryError = class(Exception);

  TSharedMemory = class
  private
    FName: string;
    FSize: Cardinal;
    FHandle: THandle;
    FData: Pointer;
    FOwnsHandle: Boolean;
    
    function GetIsValid: Boolean;
  protected
    procedure CheckValid;
  public
    constructor Create(const AName: string; ASize: Cardinal; AOpenExisting: Boolean = False);
    destructor Destroy; override;
    
    procedure Open(const AName: string; ASize: Cardinal);
    procedure Close;
    
    function Read(var Buffer; Offset: Cardinal; Count: Cardinal): Boolean;
    function Write(const Buffer; Offset: Cardinal; Count: Cardinal): Boolean;
    
    property Data: Pointer read FData;
    property Size: Cardinal read FSize;
    property IsValid: Boolean read GetIsValid;
    property Name: string read FName;
  end;

implementation

{ TSharedMemory }

constructor TSharedMemory.Create(const AName: string; ASize: Cardinal; AOpenExisting: Boolean);
begin
  inherited Create;
  
  FName := AName;
  FSize := ASize;
  FHandle := 0;
  FData := nil;
  FOwnsHandle := False;
  
  if not AOpenExisting then
    Open(AName, ASize);
end;

destructor TSharedMemory.Destroy;
begin
  Close;
  inherited;
end;

procedure TSharedMemory.CheckValid;
begin
  if not IsValid then
    raise ESharedMemoryError.Create('Shared memory is not valid');
end;

function TSharedMemory.GetIsValid: Boolean;
begin
  Result := (FHandle <> 0) and (FData <> nil);
end;

procedure TSharedMemory.Open(const AName: string; ASize: Cardinal);
var
  FullName: string;
  SecurityAttr: TSecurityAttributes;
  SecurityDesc: TSecurityDescriptor;
begin
  Close;
  
  FName := AName;
  FSize := ASize;
  
  // Настраиваем безопасность для всех процессов
  InitializeSecurityDescriptor(@SecurityDesc, SECURITY_DESCRIPTOR_REVISION);
  SetSecurityDescriptorDacl(@SecurityDesc, True, nil, False);
  
  SecurityAttr.nLength := SizeOf(TSecurityAttributes);
  SecurityAttr.lpSecurityDescriptor := @SecurityDesc;
  SecurityAttr.bInheritHandle := True;

//  FullName := 'Global\' + AName;
  FullName := 'Local\' + AName;
  
  if not FOwnsHandle then
  begin
    // Пытаемся открыть существующий
    FHandle := OpenFileMapping(
      FILE_MAP_READ or FILE_MAP_WRITE,
//      FILE_MAP_ALL_ACCESS,
      False,
      PChar(FullName)
    );

    if FHandle = 0 then
    begin
      // Создаем новый
      FHandle := CreateFileMapping(
        INVALID_HANDLE_VALUE,
        @SecurityAttr,
        PAGE_READWRITE,
        0,
        ASize,
        PChar(FullName)
      );

      FOwnsHandle := FHandle <> 0;
    end;
  end;

  if FHandle = 0 then
    raise ESharedMemoryError.CreateFmt('Cannot open shared memory "%s": %s',
      [AName, SysErrorMessage(GetLastError)]);

//  FData := MapViewOfFile(FHandle, FILE_MAP_ALL_ACCESS, 0, 0, ASize);
  FData := MapViewOfFile(FHandle, FILE_MAP_READ or FILE_MAP_WRITE, 0, 0, ASize);
  if FData = nil then
  begin
    CloseHandle(FHandle);
    FHandle := 0;
    raise ESharedMemoryError.CreateFmt('Cannot map view of file "%s": %s',
      [AName, SysErrorMessage(GetLastError)]);
  end;
end;

procedure TSharedMemory.Close;
begin
  if FData <> nil then
  begin
    UnmapViewOfFile(FData);
    FData := nil;
  end;
  
  if FHandle <> 0 then
  begin
    CloseHandle(FHandle);
    FHandle := 0;
  end;
end;

function TSharedMemory.Read(var Buffer; Offset, Count: Cardinal): Boolean;
begin
  CheckValid;
  
  if (Offset + Count) > FSize then
    Exit(False);
    
  Move(PByte(FData)[Offset], Buffer, Count);
  Result := True;
end;

function TSharedMemory.Write(const Buffer; Offset, Count: Cardinal): Boolean;
begin
  CheckValid;
  
  if (Offset + Count) > FSize then
    Exit(False);
    
  Move(Buffer, PByte(FData)[Offset], Count);
  
  // Гарантируем запись в память (не только в кэш процессора)
  FlushViewOfFile(FData, 0);
  
  Result := True;
end;

end.