unit SmartInspect.Mobile.SiAuto;

interface

{$IFDEF SiDebugMobile}
{$Message HINT 'SmartInspect.Mobile добавлен в сборку'}

uses
  System.SysUtils,
  System.Messaging,
  SmartInspect.Mobile;

type
  // Целевой алгортим сбора телеметрии для мобильных приложений релазиует две стратегии
  //
  // Стратегия получить ошибки: Сбор информации только о причинах необработанных исключений
  //   - Режим работает по умолчанию от момента запуска приложения
  //   - SmartInspect конфигурируется на Memory-SIL-протокол
  //   - Ход работы пиложения логируется в Memory
  //   - В момент отработки ловушки исключений о тчет об исключении записывается в Memory-SIL-протокол
  //   - Memory-SIL-протокол зпкписсывается в SIL-файл по порядку ротации (на N частей)
  //   - Чтобы массовое исключение не переписало ротацию ведется атомарный счетчик отчетов полученных
  //     за один сеанс работы пролиожения
  //   - Фоновый процесс выполняет обаружение SIL-файлов по порядку ротации, архивирует их в ZIP
  //     и доставляет до Маркет-Сервера
  //   - Если прожение умело и не смогло отправить SIL-файлы на сервер, то доставка произойдет при
  //     следующем запуске приложения
  //
  // Стратегия получить всё: Сбор полной информации о текущем выполнении приложения на устройстве
  //   - Режим по умолчанию выклчен,
  //     Хотелосьбы включение выборочно дистанционно через сигнал от маркет сервера (алгорти продумать)
  //     Но первая реалзиация будет по кнопке в ирложении на мобильном устройсве
  //   - SmartInspect конфигурируется сразу на File-SIL-протокол с ротацией (час + размер).
  //     Memory-SIL-протокол при этом выключается.
  //   - Ход работы пиложения логируется в File-SIL-протокол
  //   - В момент отработки ловушки исключений о тчет об исключении просто записывается в File-SIL-протокол
  //   - Массовое исключение также просто продолжают записывается в File-SIL-протокол
  //   - Фоновый процесс выполняет обаружение SIL-файлов по порядку ротации, архивирует их в ZIP
  //     и доставляет до Маркет-Сервера
  //   - Отправлются все кроме текущего открытого File-SIL куска (он будет предан по завершению ротации)
  //   - Если прожение умело и не смогло отправить SIL-файлы на сервер, то доставка произойдет при
  //     следующем запуске приложения
  //
  //   Для первой версии "Фоновый процесс доставки" можно не делать.
  //   Sil-смотреть по проводу подключая устройсво к компютеру разработчика.

  TSiSessionMobile = class(TSiSessionCore)
  strict private
    FAppTitle : string;
    FAppVersion : string;
    FDownloadsLogsPath : string;
    FConnectionFile : string;

  public
    {$IFNDEF DisableGrijjy}
    procedure HandleExceptionReport(const Sender: TObject; const M: TMessage);
    {$ENDIF}

    constructor Create(const AParent: TSmartInspectCore; const ASessionName: UnicodeString);
    destructor Destroy; override;

    procedure LogMobileAppInfo;
    procedure OpenFileProtocol;
    procedure CloseFileProtocol;

    property AppTitle : string read FAppTitle;
    property AppVersion : string read FAppVersion;
    property DownloadsLogsPath : string read FDownloadsLogsPath;
  end;

var
  // Автоматически созданный экземпляр TSmartInspectCore
  Si: TSmartInspectCore;

  // Автоматически созданный экземпляр TSiSessionMobile.
  SiMobile: TSiSessionMobile;

{$ENDIF} // SiDebugMobile - не работает, гобально выключен до завершения экспериментов

implementation

{$IFDEF SiDebugMobile} // SiDebugMobile - не работает, гобально выключен до завершения экспериментов

uses
  System.Types,
  System.Classes,
  System.IOUtils,
  FMX.Forms,
  {$IFNDEF DisableGrijjy}
  Grijjy.ErrorReporting,
  {$ENDIF}
  FMX.Platform;

  //const
  //  MemConnectionBin  = 'mem(maxsize="20480", async.enabled="true", async.queue="5120")';
  //  MemConnectionText = 'mem(astext="true", pattern="[%timestamp% %thread%] %level%: %title%", indent="true", maxsize="20480")';
  //  FileConnection    = 'file(filename="Mobile.sil", maxparts="100", maxsize="102400", async.enabled="true", async.queue="10240")';

{ TSiSessionMobile }

constructor TSiSessionMobile.Create(const AParent: TSmartInspectCore; const ASessionName: UnicodeString);
begin
  inherited Create(AParent, ASessionName);

  // Заготовить парметры для файлового протокола
  FAppTitle := 'MobileApp';
  FAppVersion := '0.0.0';

  {$IFDEF WIN32}
  FAppTitle := ChangeFileExt(ExtractFileName(ParamStr(0)), String.Empty);
  {$ELSE}
  // Имя реального приложения можно получить от операционной системы
  var ApplicationSvc: IFMXApplicationService;
  if TPlatformServices.Current.SupportsPlatformService(IFMXApplicationService, ApplicationSvc) then
    if not ApplicationSvc.DefaultTitle.IsEmpty then
    begin
      FAppTitle := ApplicationSvc.DefaultTitle;
      FAppVersion := ApplicationSvc.AppVersion;
    end;
  {$ENDIF}

  // Каталог для журналов /storage/emulated/0/Android/data/<application ID>/files/Logs/*.sil)
  FDownloadsLogsPath := TPath.Combine(TPath.GetPublicPath, 'Logs');

  // Заготовка для файловго подключения
  // Cамо подключение создается не сразу.
  // Т.к. создвать директорию можно толко после того как прлоржение
  // проверит разрешения на доступ к файловой системе
  // Ромтация раз в сутки т.к. есть устросва Android с постоянным подключением
  // И лтмит рамера 5 файлов по 10 МБ (в сумме н еболее 500 МБ) т.к. экономим память на устройствах
  FConnectionFile := 'file(filename="' +
    TPath.Combine(FDownloadsLogsPath, FAppTitle + '.sil') +
    '", rotate="daily", maxparts="5", maxsize="10240", async.enabled="true", async.queue="10240")';

  {$IFNDEF DisableGrijjy}
  // Инициализации инфраструктуры для перехвата исключений
  FMX.Forms.Application.OnException := TgoExceptionReporter.ExceptionHandler;
  TMessageManager.DefaultManager.SubscribeToMessage(TgoExceptionReportMessage, HandleExceptionReport);
  {$ENDIF}
end;

destructor TSiSessionMobile.Destroy;
begin
  {$IFNDEF DisableGrijjy}
  // Отписка от перехвата ислючений
  TMessageManager.DefaultManager.Unsubscribe(TgoExceptionReportMessage, HandleExceptionReport);
  {$ENDIF}

  inherited;
end;

{$IFNDEF DisableGrijjy}
procedure TSiSessionMobile.HandleExceptionReport(const Sender: TObject; const M: TMessage);
begin
  Assert(M is TgoExceptionReportMessage);
  var Report: IgoExceptionReport := TgoExceptionReportMessage(M).Report;
  var ReportText: string := Report.Report;
  LogError(ReportText);

  // Это сообщение может быть отправлено из любого потока.
  // Поэтому, если мы хотим показать отчет в пользовательском
  // интерфейсе, нам нужно синхронизировать его с главным потоком.
  // Мы используем TThread.Queue, чтобы не блокировать процесс.

  // Пока так, но потом сделать специальную форму
  // Логирования пока что будет вполне достаточно
  (*TThread.Queue(nil,
    procedure
    begin
      ShowMessage(ReportText);
    end);*)
end;
{$ENDIF}

procedure TSiSessionMobile.LogMobileAppInfo;
begin
  TrackMethod('Информация о приложении');
  LogValue('AppTitle', FAppTitle);
  LogValue('AppVersion', FAppVersion);
  LogValue('DownloadsLogsPath', FDownloadsLogsPath);
end;

procedure TSiSessionMobile.OpenFileProtocol;
begin
  // Реальное включение записи телеметрии в файл можно делать
  // только поспосле того, как пользователь в прлоржении проверит
  // разрешения на доступ к файловой системе

  if not TDirectory.Exists(FDownloadsLogsPath) then
    try
      // TDirectory.CreateDirectory(FDownloadsLogsPath);
      ForceDirectories(FDownloadsLogsPath);
    except
      Exit;
    end;

  Si.Connections := SiMobile.FConnectionFile;
  Si.Enabled := True;

  var Info := 'Включена запись телеметрии в каталог: ' + FDownloadsLogsPath;
  SiMobile.LogMessage(Info);

  LogMobileAppInfo;
end;

procedure TSiSessionMobile.CloseFileProtocol;
begin
  var Info := 'Запись телеметрии завершена';
  SiMobile.LogMessage(Info);

  Si.Enabled := False;
end;

initialization
  TSmartInspectCore.SiInitCurrentProcessId;
  Si := TSmartInspectCore.Create('MobileApp');
  SiMobile := TSiSessionMobile.Create(Si, 'Mobile');
  Si.AppName := SiMobile.AppTitle;
  Si.AddSession(SiMobile);

finalization
  SiMobile := nil;
  FreeAndNil(Si);

{$ENDIF} // SiDebugMobile - не работает, гобально выключен до завершения экспериментов

end.

