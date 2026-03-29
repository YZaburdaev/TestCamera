program MarketPosCamera;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  Windows,
  MarketPosCamera.VLCCamera.Grabber in 'MarketPosCamera.VLCCamera.Grabber.pas',
  PasLibVlcClassUnit in 'PasLibVlc\source\PasLibVlcClassUnit.pas',
  PasLibVlcUnit in 'PasLibVlc\source\PasLibVlcUnit.pas',
  MarketPosCamera.TerminationEvent in 'MarketPosCamera.TerminationEvent.pas',
  MarketPosCamera.Common in 'MarketPosCamera.Common.pas',
  IPCManager.Hybrid in 'IPCManager\IPCManager.Hybrid.pas',
  LockFreeRingBuffer in 'IPCManager\LockFreeRingBuffer.pas',
  SharedMemory in 'IPCManager\SharedMemory.pas',
  MarketPosCamera.Core in 'MarketPosCamera.Core.pas',
  SiAuto in 'SmartInspect\si\SiAuto.pas',
  SiExceptReport in 'SmartInspect\si\SiExceptReport.pas',
  SmartInspect in 'SmartInspect\si\SmartInspect.pas',
  MarketPosCamera.Settings in 'MarketPosCamera.Settings.pas';

var
  FMarketPosCamera: TMarketPosCamera;

function Ctrl_Handler(Ctrl: DWORD): LongBool; stdcall;
begin
  Result := False;
  if Ctrl in [CTRL_C_EVENT, CTRL_BREAK_EVENT] then
  begin
    WriteLn('[CTRL+C]');
    SiDevOps.LogWarning('CTRL_BREAK_EVENT');
    SetTerminationEvent;
    Result := True;
  end;
end;

procedure AppCreate;
begin
  InitializeTerminationEvent;

  SetConsoleCtrlHandler(@Ctrl_Handler, True);

  Settings.Read;
  FMarketPosCamera := TMarketPosCamera.Create;
end;

procedure AppRun;
begin
  SiDevOps.TrackMethod('AppRun');

  FMarketPosCamera.Start;

  while True do
  begin
    if CheckTerminationEvent then
    begin
      ConsoleWriteMessage('Получен управляющий сигнал остановки');
      Break;
    end;

    SleepAndWakeOnTermination(250);
  end;
end;

procedure AppStop;
begin
  ConsoleWriteMessage('Подготовка к завершению рабочего процесса');

  FMarketPosCamera.Stop;
  FMarketPosCamera.Free;

  FinalizeTerminationEvent;
  ConsoleWriteMessage('Корректное завершение рабочего процесса');
end;


begin
  ReportMemoryLeaksOnShutdown := True;

  SiAutoLoadSic;
  try
    SiDevOps.EnterThread('Main');
    ConsoleWriteMessage(ExtractFileName(ParamStr(0)) + ' - рабочий процесс для взаимодействия с камерой');

    AppCreate;
    try
      AppRun;
    finally
      AppStop;
      SiDevOps.LeaveThread('Main');
    end;
  except
    on E: Exception do
    begin
      WriteLn('Фатальный сбой ' + E.ClassName + ': ' + E.Message);
      SilentExceptionSecurityLog('Фатальный сбой ' + E.ClassName, E);
    end;
  end;
end.
