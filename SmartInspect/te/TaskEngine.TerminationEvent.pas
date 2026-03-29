unit TaskEngine.TerminationEvent;

interface
  // Инициализация управляющих сигналов завершения от родительской управляющей службы
  // и обратно признаков жизни от рабочего процесса
  function InitializeTerminationEvent: Boolean;

  // Освобождение управляющих сигналов
  procedure FinalizeTerminationEvent;

  // Проверка управляющего сигнала завершения от родительской управляющей службы
  // Если результат True, то пора завершать работу рабочего процесса
  function CheckTerminationEvent: Boolean;

  // Установка управляющего сигнала завершения.
  // Рабочий процесс может сам себе скомандовать остановку
  procedure SetTerminationEvent;

  // Установка ответного сигнала, признака жизни рабочего процесса
  // Вызвать нужно из основных циклов выполняющих ползную нагрузку рабочего процесса.
  // Если этот сигнал долго не приходит, то управляющая служба назначит и выполнит
  // утилизазию рабочего процесса по ричине отсутствия признаков жизни
  // включая жесткий вариант через TerminateProcess
  procedure SetHealthcareEvent;

  // Сон с пробуждением от управляющего сигнала завершения
  // рекомендуется использовать в циклах ожэидания
  procedure SleepAndWakeOnTermination(AMilliseconds: LongWord);

implementation

uses
  System.SysUtils,
  Winapi.Windows;

var
  // Хендл управляющего сигнала от родительской управляющей службы TaskServivce.exe
  // Устанавливается управляющей службой, чтобы проинформировать дочерние рабочие
  // процессы о необходимости завершения работы.
  TerminationEventHandle: THandle = 0;

  // Хендл ответного сигнала признака жизни рабочего процесса
  HealthcareEventHandle: THandle = 0;

function GetSchedulerAppName: String;
begin
  Result := ExtractFileName(ParamStr(0)).ToUpper;
end;

function GetTerminationEventName: String;
begin
  Result := GetSchedulerAppName + ':' + GetCurrentProcessId.ToString;
end;

function InitializeTerminationEvent: Boolean;
begin
  Result := (TerminationEventHandle <> 0) and (HealthcareEventHandle <> 0);

  if Result then
    Exit;

  var TerminationEventName := GetTerminationEventName;
  if TerminationEventHandle = 0 then
    TerminationEventHandle := OpenEvent(EVENT_ALL_ACCESS, True, PChar(TerminationEventName));

  if TerminationEventHandle = 0 then
  begin
    // По всей видимости рабочий процесс работает автономно без управляющего cервиса.
    // Сотздать сигнал для самого себя.
    // Парметр bManualReset нужен True чтобы сигналное состояние не сборасывалось в циклах TaskEngine
    // рабочий процесс не зависал и корректоно закрывался.
    TerminationEventHandle := CreateEvent(nil, True, False, PChar(TerminationEventName));
  end;

  var HealthcareEventName := TerminationEventName + ':HEALTHCARE';
  if HealthcareEventHandle = 0 then
    // Парметр bManualReset нужен True чтобы сигналное состояние не сборасывалось при его чтении
    // Управляющий процесс сделает ResetEvent когда просканиует признак живучести
    HealthcareEventHandle := CreateEvent(nil, True, False, PChar(HealthcareEventName));

  Result := (TerminationEventHandle <> 0) and (HealthcareEventHandle <> 0);
end;

procedure FinalizeTerminationEvent;
begin
  CloseHandle(TerminationEventHandle);
  CloseHandle(HealthcareEventHandle);
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

procedure SetHealthcareEvent;
begin
  if HealthcareEventHandle <> 0 then
    SetEvent(HealthcareEventHandle);
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
