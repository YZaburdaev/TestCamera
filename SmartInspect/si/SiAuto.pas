unit SiAuto;

{$IF DEFINED(SiProd) or DEFINED(SiDebug)}
  {$DEFINE EnableUnitSiAuto}
  {$MESSAGE HINT 'Модули трассировки SiAuto включены}
{$ELSE}
  {$MESSAGE HINT 'Модули трассировки SiAuto отключены}
{$ENDIF}


interface

{$IFDEF EnableUnitSiAuto}
uses
  System.SysUtils,
  System.IOUtils,
  SmartInspect,
  {$IF DEFINED (SiExceptFMX) or DEFINED(SiExceptVCL)}
  System.UITypes,
  {$ENDIF}
  System.IniFiles;

var
  Si: TSmartInspect = nil;

  // Сессия для информации разрешенной на вывод ПРОД сборках
  // подготавливать информацию для вывода в эту сессию нужно
  // таким образом чтобы минимизировать накладные расходы на логирование
  // Содержимое этих догов должно быть адаптировано для
  // анализа Аналитиками и DevOps в продуктивном окружении.
  SiDevOps: TSiSession = nil;

  {$IFDEF SiDebug}
  {$MESSAGE WARN 'В сборку подключены отладочные сессии SiMain SiMainGood SiMainBad SiMainUgly трассировки Smartinspect подключен к сборке MarketServer'}
  // Отладочные сессии могут содержать избыточное логирование
  // и детализацию которую в ПРОД лучше не включать
  // из за высокой дополнительной нагрузки
  // для высоко нагруженных проектов не должна включаться в компиляцию
  // Содержимое этих догов должно быть ориентировано только
  // на отладочные сборки для среды разработки программистов.
  SiMain: TSiSession = nil;
  SiMainGood: TSiSession = nil;
  SiMainBad: TSiSession = nil;
  SiMainUgly: TSiSession = nil;
  {$ENDIF}

// Активация логирования через SIC-файл приложения
procedure SiAutoLoadSic;

// Активация логирования через INI-файл приложения
procedure SiMainReadIniFile(Ini: TCustomIniFile);

{$IFDEF MARKETCRMX}
// Для CRM логирование можно включить в INI-файле
procedure SiMainInitIni(const PrivateLogFolderName: string = string.Empty);
{$ENDIF}
{$ENDIF}

implementation

{$IFDEF EnableUnitSiAuto}
{$IFDEF MARKETCRMX}
uses
  TypeX;

{$ENDIF}

{$IF DEFINED (SiExceptFMX) or DEFINED(SiExceptVCL)}
uses
  SiExceptReport,
  SiExceptSession;
{$ENDIF}


{$IF DEFINED (SiExceptFMX) or DEFINED(SiExceptVCL)}
function BGR2RGB(BGR : TColor): TColor;
begin
  TAlphaColorRec(Result).R := TAlphaColorRec(BGR).B;
  TAlphaColorRec(Result).G := TAlphaColorRec(BGR).G;
  TAlphaColorRec(Result).B := TAlphaColorRec(BGR).R;
  TAlphaColorRec(Result).A := 0;
end;
{$ENDIF}

procedure SiAutoInit;
var
  SiAppName : string;
begin
  SiAppName := ExtractFileName(ParamStr(0));
  Si := TSmartInspect.Create(SiAppName);

  // Сессия контента из ПРОД окружения, ждя Аналитиков и DevOps
  SiDevOps := Si.AddSession('DevOps', True);

  {$IFDEF SiDebug}
  // Сессия для отладочного контента
  SiMain := Si.AddSession('Main', True);

  // Сессия для отладочного контента хорошего зеленым
  SiMainGood := Si.AddSession('Хороший', True);
  {$IF DEFINED (SiExceptFMX) or DEFINED(SiExceptVCL)}
  SiMainGood.Color := BGR2RGB($C6EFCE);
  {$ENDIF}

  // Сессия для отладочного контента плохого красным
  SiMainBad := Si.AddSession('Плохой', True);
  {$IF DEFINED (SiExceptFMX) or DEFINED(SiExceptVCL)}
  SiMainBad.Color := BGR2RGB($FFC7CE);
  {$ENDIF}

  // Сессия для отладочного контента непонятного желтым
  SiMainUgly := Si.AddSession('Непонятный', True);
  {$IF DEFINED (SiExceptFMX) or DEFINED(SiExceptVCL)}
  SiMainUgly.Color := BGR2RGB($FFEB9C);
  {$ENDIF}
  {$ENDIF}

  {$IF DEFINED (SiExceptFMX) or DEFINED(SiExceptVCL)}
  // Сессия для перехвата исключений в продуктах семейства MarketPosSale
  SiExcept := TSiExceptSession.Create(Si, SiAppName);
  {$ENDIF}

  {$IFDEF TASKENGINE}
  // все стандартные сессии, кроме SiDevOps, блокируются
  {$IFDEF SiDebug}
  SiMain.Active := False;
  SiMainGood.Active := False;
  SiMainBad.Active := False;
  SiMainUgly.Active := False;
  {$ENDIF}
  {$ENDIF}
end;

procedure SiAutoLoadSic;
begin
  // Активация по файлу конфигурации
  // Путь1 - SIC рядом с EXE, по имени EXE
  var SiSicName1 := ChangeFileExt(ParamStr(0), '.sic');
  if FileExists(SiSicName1) then
  begin
    si.LoadConfiguration(SiSicName1);
  end
  else
  begin
    // Путь2 - SIC в папке запуска, по имени EXE
    var SiSicName2 := ChangeFileExt(ExtractFileName(ParamStr(0)), '.sic');
    if FileExists(SiSicName2) then
      si.LoadConfiguration(SiSicName2);
  end;

  {$IFDEF SiDebug}
  {$IFDEF MARKETERP}
  SiMain.EnterProcess('MarketErp');
  {$ENDIF}
  {$IFDEF TASKENGINE}
  SiMain.EnterProcess('TaskEngine');
  {$ENDIF}
  {$IFDEF MarketServer}
  SiMain.EnterProcess('MarketServer');
  {$ENDIF}
  {$ENDIF}
end;

procedure SiMainReadIniFile(Ini: TCustomIniFile);
begin
  var SiLogPath : string := Ini.ReadString('SmartInspect', 'LogPath', '').Trim;

  if not SiLogPath.IsEmpty then
    if ForceDirectories(SiLogPath) then
    begin
      var SiAppName : string := ExtractFileName(ParamStr(0));
      var SiLogName : string := ChangeFileExt(SiAppName, '.sil');
      var SiMaxParts : Integer := Ini.ReadInteger('SmartInspect', 'MaxParts', 64);
      var SiMaxSize : Integer := Ini.ReadInteger('SmartInspect', 'MaxSize', 204800);

      Si.Connections := 'file(FileName=' + TPath.Combine(SiLogPath, SiLogName).QuotedString('"') +
        ', MaxParts=' + SiMaxParts.ToString +
        ', MaxSize=' + SiMaxSize.ToString +
        ', Rotate=Daily, Async.Enabled=True, Async.Queue=10240)';

      Si.Enabled := True;

      SiDevOps.EnterProcess('MainProcess');

      {$IF DEFINED (SiExceptFMX) or DEFINED(SiExceptVCL)}
      // Создать подписку на исключения только после реальной
      // активации логирования в конфигурационном файле
      SiExcept.SessionExceptionHandlerInitialize;
      SiExcept.LogCustomText(lvMessage, 'Запуск приложения '+SiAppName, ExceptReportCreate(nil, nil, 'Запуск приложения'), ltMessage, viData);
      {$ENDIF}
    end;
end;

{$IFDEF MARKETCRMX}
procedure SiMainInitIni(const PrivateLogFolderName: string = string.Empty);
begin
  // Для CRM логироание можно включить в INI-файле
  var PathLog : string := string.Empty;

  var Ini : TIniFile := TIniFile.Create(IniFileName);
  try
    PathLog:= Trim(Ini.ReadString('Exchange', 'PathLog', '')) ;

    if not DirectoryExists(PathLog) then
    begin
      // Если корневая папка для логов не сущесвует, то логи не писать
      PathLog:= string.Empty
    end
    else if not PrivateLogFolderName.IsEmpty then
    begin
      // Каждому пользователю сделать свою папку логов
      PathLog := TPath.Combine(PathLog, PrivateLogFolderName);
      if not ForceDirectories(PathLog) then
        PathLog:= string.Empty
    end;
  finally
    Ini.Free;
  end;

  if not PathLog.IsEmpty then
  begin
    // Включать только если папка определилась
    Si.Connections := 'file(filename="' + TPath.Combine(PathLog,'MarketCrmX-log.sil')+ '", maxparts=15, maxsize=20480, rotate="daily", async.enabled=true, async.queue="10240")';
    Si.Enabled := True;
    SiMain.EnterProcess('MarketCrmX');
  end
  else
    Si.Enabled := False;
end;
{$ENDIF}

procedure SiAutoDone;
begin
  {$IFDEF SiDebug}
  {$IFDEF MARKETERP}
  SiMain.LeaveProcess('MarketErp');
  {$ENDIF}
  {$IFDEF TASKENGINE}
  SiMain.LeaveProcess('TaskEngine');
  {$ENDIF}
  {$IFDEF MarketServer}
  SiMain.LeaveProcess('MarketServer');
  {$ENDIF}
  {$ENDIF}

  SiDevOps := nil;

  {$IFDEF SiDebug}
  SiMain := nil;
  SiMainGood := nil;
  SiMainBad := nil;
  SiMainUgly := nil;
  {$ENDIF}

  {$IF DEFINED (SiExceptFMX) or DEFINED(SiExceptVCL)}
  // Сессия для перехвата исключений в продуктах семейства MarketPosSale
  FreeAndNil(SiExcept);
  {$ENDIF}

  FreeAndNil(Si);
end;

initialization
  SiAutoInit;

finalization
  SiAutoDone;

{$ENDIF}
end.

