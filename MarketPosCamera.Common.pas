unit MarketPosCamera.Common;

interface

const
  // Память для отправляющего менеджера
  c_SenderSharedMemSize = 2560 * 1440 * 32 + (1024 * 1024);
  // Паямть для получающего менеджера
  c_ReceiverSharedMemSize = 1024 * 1024;

  procedure ConsoleWriteMessage(const Msg: string);

implementation

uses
  System.SysUtils,
  SiAuto;

procedure ConsoleWriteMessage(const Msg: string);
begin
  SiDevOps.LogMessage(Msg);
  Writeln(FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz ', Now) + Msg);
end;

initialization


end.
