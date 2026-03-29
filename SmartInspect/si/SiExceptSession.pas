unit SiExceptSession;

{$IF DEFINED (SiExceptFMX) or DEFINED(SiExceptVCL)}
  {$DEFINE EnableUnitSiExceptSession}

  {$IFDEF SiExceptFMX}
  {$MESSAGE HINT 'Подключена версия модуля SiExceptSession для трассировки продуктов ветки FMX}
  {$ENDIF}

  {$IFDEF SiExceptVCL}
  {$MESSAGE HINT 'Подключена версия модуля SiExceptSession для трассировки продуктов ветки VCL}
  {$ENDIF}
{$ELSE}
  {$MESSAGE ERROR 'Модуль SiExceptSession не предназначен для данного семейства ПО}
{$ENDIF}

interface

{$IFDEF EnableUnitSiExceptSession}

uses
  SmartInspect,
  System.Classes,
  System.SysUtils;

type
  TSiExceptSession = class(TSiSession)
  strict private
    procedure SessionExceptionHandlerLogMode(Sender: TObject; E: Exception);
    procedure SessionExceptionHandlerUIMode(Sender: TObject; E: Exception);
  public
    procedure SessionExceptionHandlerInitialize;
    procedure SessionExceptionHandlerFinalize;
    procedure SetLogMode;
  end;

var
  SiExcept: TSiExceptSession = nil;

// Функция вывода в лог информации об исключении
// Простой обработчик для тихой ловушки исключений, без выдачи сообщений пользователю.
// Рекомендуется использовать в секции try except on ...
procedure SiMainExceptionLog(ErrorTag: String; E: Exception);

// Функция для вывода лог стека вызова текущей функции
// Рекомендуется использовать для исследования вопросов типа "Кто же вызвал эту функцию?"
procedure SiMainStackTrace(MessageTag: String);

{$ENDIF}

implementation

{$IFDEF EnableUnitSiExceptSession}

uses
  System.IOUtils,
  System.UITypes,
  FireDAC.Phys,
  SiExceptReport,
  JclDebug,
  JclHookExcept,
  {$IFDEF SiExceptFMX}
  FMX.Forms,
  FMX.Dialogs,
  FMX.DialogService,
  {$ENDIF}
  {$IFDEF SiExceptVCL}
  VCL.Forms,
  VCL.Dialogs,
  {$ENDIF}
  Winapi.Windows;

procedure SiMainExceptionLog(ErrorTag: String; E: Exception);
begin
  SiExcept.LogCustomText(lvMessage, ErrorTag, ExceptReportCreate(nil, E, ErrorTag), ltError, viData);
end;

procedure SiMainStackTrace(MessageTag: String);
begin
  var StackInfoList: TJclStackInfoList := JclCreateStackList(True, 0, nil);
  var StackInfo : TStringList := TStringList.Create;
  try
    StackInfoList.AddToStrings(StackInfo, True, True, True);
    SiExcept.LogCustomText(lvMessage, MessageTag, StackInfo.Text, ltDebug, viData);
  finally
    StackInfoList.Free;
    StackInfo.Free;
  end;
end;

{ TSiExceptSession }

procedure TSiExceptSession.SessionExceptionHandlerLogMode(Sender: TObject; E: Exception);
begin
  // Для сервисных-приложений с неотрезанным GUI эта ловушка зафиксирует Application.OnException
  // после отрезания GUI должна быть другая обработка
  var ErrorHashCode: string := ExceptReportHashTag;
  var ErrorTelemetryReport : string := ExceptReportCreate(Sender, E, ErrorHashCode);
  LogCustomText(lvError, 'Ловушка исключения уровня приложения', ErrorTelemetryReport, ltError, viData);
end;

procedure TSiExceptSession.SessionExceptionHandlerUIMode(Sender: TObject; E: Exception);
begin
  // Для продуктивной среды пользователям детализацию ошибки не показывать, а только код
  var ErrorHashCode: string := ExceptReportHashTag;
  var ErrorUserMessageCode : string := 'Код ошибки '+ErrorHashCode;
  var ErrorTelemetryReport : string := ExceptReportCreate(Sender, E, ErrorHashCode);

  // Полную детализацию ошибки записать в протокол
  LogCustomText(lvError, ErrorUserMessageCode, ErrorTelemetryReport, ltError, viData);

  {$IFDEF SiExceptFMX}
  if not ErrorHashCode.IsEmpty then
  begin
    // На экран выдавать текс ошибки с помощью стандартного диалога Windows
    // т.к. FMX может быть не готов для отображения текста.
    TDialogService.MessageDialog(ErrorUserMessageCode,
      TMsgDlgType.mtError, [TMsgDlgBtn.mbClose], TMsgDlgBtn.mbClose, 0, nil);
  end
  else
  begin
    // После многократных ошибок в сообщение добавить кнопку "Прервать" и снять приложение
    TDialogService.MessageDialog(ErrorUserMessageCode,
      TMsgDlgType.mtError, [TMsgDlgBtn.mbAbort, TMsgDlgBtn.mbClose],  TMsgDlgBtn.mbClose, 0,
      procedure(const AResult: TModalResult)
      begin
        if AResult = mrAbort then
          TerminateProcess(GetCurrentProcess, 1);
      end);
  end;
  {$ENDIF}

  {$IFDEF SiExceptVCL}
  if not ErrorHashCode.IsEmpty then
  begin
    // На экран выдавать текс ошибки с помощью стандартного диалога Windows
    // т.к. FMX может быть не готов для отображения текста.
    MessageDlg(ErrorUserMessageCode,
      TMsgDlgType.mtError, [TMsgDlgBtn.mbClose], 0, TMsgDlgBtn.mbClose);
  end
  else
  begin
    // После многократных ошибок в сообщение добавить кнопку "Прервать" и снять приложение
    if MessageDlg(ErrorUserMessageCode,
      TMsgDlgType.mtError, [TMsgDlgBtn.mbAbort, TMsgDlgBtn.mbClose],  0, TMsgDlgBtn.mbClose) = mrAbort then
    begin
      TerminateProcess(GetCurrentProcess, 1);
    end
  end;
  {$ENDIF}
end;

procedure TSiExceptSession.SessionExceptionHandlerInitialize;
begin
  // По умолчанию, задать вариант обработчика для графических Desktop-приложений
  // с выдаечей на экран сообщения.
  Application.OnException := SessionExceptionHandlerUIMode;

  // Настройка "сырой" трассировки стека [stRawMode]
  // Нужна для анализа самых тяжелых ошибок.
  // При анализе нужно учитывать что в отчете по стеку может быть мусор
  JclStackTrackingOptions := JclStackTrackingOptions + [stRawMode];

  JclStackTrackingOptions := JclStackTrackingOptions + [stStaticModuleList];
  JclStackTrackingOptions := JclStackTrackingOptions + [stExceptFrame];

  // Фильтрация исключений для оптимизации производительности, добавлять те, для которых не нужна раскрутка стека
  AddIgnoredExceptionByName('EIdSocketError');
  AddIgnoredExceptionByName('EIdNotASocket');
  AddIgnoredExceptionByName('EIdConnectTimeout');
  AddIgnoredExceptionByName('EIdConnClosedGracefully');
  AddIgnoredExceptionByName('EIdOSSLAcceptError');
  AddIgnoredExceptionByName('ENamedPipeAbort');
end;

procedure TSiExceptSession.SessionExceptionHandlerFinalize;
begin
  {$IFDEF SiExceptVCL}
  VCL.Forms.Application.OnException := nil;
  {$ENDIF}

  {$IFDEF SiExceptFMX}
  FMX.Forms.Application.OnException := nil;
  {$ENDIF}
end;

procedure TSiExceptSession.SetLogMode;
begin
  // Перепоределить вариант обработчика для сервисных-приложений
  // с не отрезным GUI (типа MarketServer) с выводом сообщений только в лог.
  // После отрезания GUI от таких приложений этот обработчик должен быть
  // отключен и переработан.
  {$IFDEF SiExceptVCL}
  VCL.Forms.Application.OnException := SessionExceptionHandlerLogMode;
  {$ENDIF}

  {$IFDEF SiExceptFMX}
  FMX.Forms.Application.OnException := SessionExceptionHandlerLogMode;
  {$ENDIF}
end;

{$ENDIF}

end.

