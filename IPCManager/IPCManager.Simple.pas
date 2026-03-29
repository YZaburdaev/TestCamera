unit IPCManager.Simple;

interface

uses
  System.Classes, System.SysUtils, LockFreeRingBuffer;

type
  TIPCMessage = record
    MsgType: Integer;
    DataSize: Integer;
    Data: array[0..4095] of Byte;
  end;
  PIPCMessage = ^TIPCMessage;

  TIPCMessageHandler = procedure(const Msg: TIPCMessage) of object;
  
  TIPCManager = class
  private
    FRingBuffer: TLockFreeRingBuffer;
    FName: string;
    FOnMessage: TIPCMessageHandler;
    FListenerThread: TThread;
    FRunning: Boolean;
    FListenerDelay: Integer;
    
    procedure DoListen;
  public
    constructor Create(const AName: string; ACapacity: Integer = 65536);
    destructor Destroy; override;
    
    procedure StartListener;
    procedure StopListener;
    
    function SendMessage(MsgType: Integer; const Data; Size: Integer): Boolean; overload;
    function SendMessage(MsgType: Integer; const Text: string): Boolean; overload;
    function SendMessage(MsgType: Integer; Value: Integer): Boolean; overload;
    
    property OnMessage: TIPCMessageHandler read FOnMessage write FOnMessage;
    property ListenerDelay: Integer read FListenerDelay write FListenerDelay default 1;
  end;

implementation

uses
  Winapi.Windows;

type
  TIPCListenerThread = class(TThread)
  private
    FManager: TIPCManager;
  protected
    procedure Execute; override;
  public
    constructor Create(AManager: TIPCManager);
  end;

{ TIPCListenerThread }

constructor TIPCListenerThread.Create(AManager: TIPCManager);
begin
  inherited Create(False);
  FManager := AManager;
  FreeOnTerminate := False;
end;

procedure TIPCListenerThread.Execute;
begin
  while not Terminated do
  begin
    FManager.DoListen;
    
    if FManager.FListenerDelay > 0 then
      Sleep(FManager.FListenerDelay);
  end;
end;

{ TIPCManager }

constructor TIPCManager.Create(const AName: string; ACapacity: Integer = 65536);
begin
  inherited Create;
  
  FName := AName;
  FRingBuffer := TLockFreeRingBuffer.Create(AName, ACapacity);
  FListenerDelay := 1; // 1 мс по умолчанию
  FRunning := False;
end;

destructor TIPCManager.Destroy;
begin
  StopListener;
  FreeAndNil(FRingBuffer);
  inherited;
end;

procedure TIPCManager.StartListener;
begin
  if FRunning then
    Exit;
    
  FRunning := True;
  FListenerThread := TIPCListenerThread.Create(Self);
end;

procedure TIPCManager.StopListener;
begin
  if not FRunning then
    Exit;
    
  FRunning := False;
  
  if FListenerThread <> nil then
  begin
    FListenerThread.Terminate;
    FListenerThread.WaitFor;
    FreeAndNil(FListenerThread);
  end;
end;

procedure TIPCManager.DoListen;
var
  Msg: TIPCMessage;
  ActualSize: Integer;
begin
  if not Assigned(FOnMessage) then
    Exit;
    
  while FRingBuffer.TryDequeue(Msg, SizeOf(Msg), ActualSize) do
  begin
    Msg.DataSize := ActualSize;
    FOnMessage(Msg);
  end;
end;

function TIPCManager.SendMessage(MsgType: Integer; const Data; Size: Integer): Boolean;
var
  Msg: TIPCMessage;
begin
  if Size > SizeOf(Msg.Data) then
    Exit(False);
    
  Msg.MsgType := MsgType;
  Move(Data, Msg.Data, Size);
  
  Result := FRingBuffer.TryEnqueue(Msg, SizeOf(Integer) * 2 + Size);
end;

function TIPCManager.SendMessage(MsgType: Integer; const Text: string): Boolean;
begin
  Result := SendMessage(MsgType, PChar(Text)^, Length(Text) * SizeOf(Char));
end;

function TIPCManager.SendMessage(MsgType: Integer; Value: Integer): Boolean;
begin
  Result := SendMessage(MsgType, Value, SizeOf(Integer));
end;

end.