unit MarketPosCamera.TerminationEvent;

interface
  // »нициализаци€ управл€ющих сигналов завершени€ от родительской управл€ющей службы
  // и обратно признаков жизни от рабочего процесса
  function InitializeTerminationEvent: Boolean;

  // ќсвобождение управл€ющих сигналов
  procedure FinalizeTerminationEvent;

  // ѕроверка управл€ющего сигнала завершени€ от родительской управл€ющей службы
  // ≈сли результат True, то пора завершать работу рабочего процесса
  function CheckTerminationEvent: Boolean;

  // ”становка управл€ющего сигнала завершени€.
  // –абочий процесс может сам себе скомандовать остановку
  procedure SetTerminationEvent;

  // —он с пробуждением от управл€ющего сигнала завершени€
  // рекомендуетс€ использовать в циклах ожидани€
  procedure SleepAndWakeOnTermination(AMilliseconds: LongWord);

implementation

uses
  System.SysUtils,
  Winapi.Windows;

var
  // ’ендл управл€ющего сигнала от родительской управл€ющей службы TaskServivce.exe
  // ”станавливаетс€ управл€ющей службой, чтобы проинформировать дочерние рабочие
  // процессы о необходимости завершени€ работы.
  TerminationEventHandle: THandle = 0;

function GetSchedulerAppName: string;
begin
  Result := ExtractFileName(ParamStr(0)).ToUpper;
end;

function GetTerminationEventName: String;
begin
  Result := GetSchedulerAppName;
end;

function InitializeTerminationEvent: Boolean;
begin
  Result := TerminationEventHandle <> 0;

  if Result then
    Exit;

  var TerminationEventName := GetTerminationEventName;
  if TerminationEventHandle = 0 then
    TerminationEventHandle := OpenEvent(EVENT_ALL_ACCESS, True, PChar(TerminationEventName));

  if TerminationEventHandle = 0 then
  begin
    // ѕо всей видимости рабочий процесс работает автономно без управл€ющего cервиса.
    // —отздать сигнал дл€ самого себ€.
    // ѕарметр bManualReset нужен True чтобы сигналное состо€ние не сборасывалось в циклах TaskEngine
    // рабочий процесс не зависал и корректоно закрывалс€.
    TerminationEventHandle := CreateEvent(nil, True, False, PChar(TerminationEventName));
  end;

  Result := TerminationEventHandle <> 0;
end;

procedure FinalizeTerminationEvent;
begin
  CloseHandle(TerminationEventHandle);
end;

function CheckTerminationEvent: Boolean;
begin
  Result := (TerminationEventHandle <> 0) and (WaitForSingleObject(TerminationEventHandle, 0) = WAIT_OBJECT_0);
end;

procedure SetTerminationEvent;
begin
  if TerminationEventHandle <> 0 then
    SetEvent(TerminationEventHandle);
end;

const
  MillisecondsDelta = 250;

procedure SleepAndWakeOnTermination(AMilliseconds: LongWord);
begin
  if AMilliseconds <= MillisecondsDelta then
  begin
    Sleep(AMilliseconds);
  end
  else
  begin
    var MillisecondsTimes : LongWord := AMilliseconds div MillisecondsDelta;
    while (MillisecondsTimes > 0) and (not CheckTerminationEvent) do
    begin
      Sleep(MillisecondsDelta);
      Dec(MillisecondsTimes);
    end;
  end;
end;

end.
