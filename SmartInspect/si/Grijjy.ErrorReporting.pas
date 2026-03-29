unit Grijjy.ErrorReporting;

//  Модуль для регистратора исключений iOS, Android или macOS.
//  Отлавливает необработанные исключения и записывает их в журнал с
//  трассировкой стека.
//
//  Оригинал кода заимствован из проекта
//  https://github.com/grijjy/JustAddCode/tree/master/ErrorReporting
//
//  Переаод на русский язык сделан с помощю:
//  https://www.deepl.com/
//
//  Также может отлавливать исключения в Windows, но он не создает
//  трассировку стека на этой платформе.
//  Для Windows есть дургие бибилотеки например JEDI
//
//  DEVELOPER GUIDE
//  ===============
//
//  Для получения дополнительной информации смотрите эти статьи в блоге:
//  * Build your own Error Reporter – Part 1: iOS
//    https://blog.grijjy.com/2017/02/09/build-your-own-error-reporter-part-1-ios/
//  * Build your own Error Reporter – Part 2: Android
//    https://blog.grijjy.com/2017/02/21/build-your-own-error-reporter-part-2-android/
//  * Build your own Error Reporter – Part 3: Intel macOS64
//
//  Чтобы включить отчет об исключениях, необходимо сделать следующее:
//
//  * Назначить регистратору исключений перехвать необработанные исключения FMX
//    (добавить этот вызов гдето в начало работы, например, в конструктор главной формы)
//
//      Application.OnException := TgoExceptionReporter.ExceptionHandler;
//
//  * Подписаться на сообщение TgoExceptionReportMessage, чтобы получать
//    уведомления об сообщения об исключениях:
//
//      TMessageManager.DefaultManager.SubscribeToMessage(
//        TgoExceptionReportMessage, HandleExceptionReport);
//
//  * В этом обработчике сообщений обрабатывать отчет любым удобным для вас способом.
//
//    Например:
//    * Вы можете отправить его по электронной почте своей команде разработчиков.
//    * Вы можете отправить его на свой облачный бэкэнд.
//    * Вы можете показать его пользователю. Однако обратите внимание, что
//      сообщение может быть отправлено из другого потока, а не из потока
//      пользовательского интерфейса, поэтому вам необходимо синхронизировать
//      любые вызовы пользовательского интерфейса с главным потоком.
//    * Вы можете отправить его на сервис, например, HockeyApp.
//    * и т.д.
//
//    Однако, поскольку приложение сейчас может быть нестабильным
//    (в зависимости от типа исключения), безопаснее всего будет просто
//    записать отчет на диск и завершить работу приложение (вызвав Halt).
//    Тогда при следующем запуске приложение сможет проверить наличие
//    этого файла и обработать отчет в этот момент.
//
//  * Включите встраивание отладочной информации для получения
//    детализации стеков вызовов, установив следующие параметры проекта
//    (menu option "Project | Options..."):
//
//    * Compiling | Debugging:
//      * Debug information: Limited debug information
//      * Local symbols: False
//      * Symbol reference info: None
//      * Use debug .dcus: True (в случае, если вам нужна информация о символах для стандартных RTL и FXM)
//    * Linking | Debug information: True (checked)

//  NOTES FOR ANDROID
//  -----------------
//  Чтобы символизация работала на Android, необходимо установить
//  следующий параметр компоновщика:
//  * Go to "Project | Options..."
//  * Select the target "All configurations - Android platform"
//  * Go to the page "Delphi Compiler | Linking"
//  * Set "Options passed to the LD linker" to:
//      --version-script=Grijjy.Symbolication.vsr
//
//  Убедитесь, что файл Grijjy.Symbolication.vsr доступен в пути поиска, или
//  задайте его с помощью абсолютного или относительного пути, как в примере:
//      --version-script=Grijjy.Symbolication.vsr
//
//  Если вам нужна символика только для сборки Release (play store),
//  то выберите цель "Release configuration - Android platform" вместо этого
//  (или любую другую  другую конфигурацию).

// Grijjy.Symbolication.vsr - Этот файл представляет собой так называемый
// скрипт версии (отсюда расширение .vsr). Среди прочего, он указывает компоновщику,
// какие символы должны быть глобальными, а какие - локальными.
// Delphi генерирует файл, который делает глобальными только пару символов,
// а все остальные символы - локальными (с подстановочным знаком local: *; в файле).
// К счастью, мы можем создать дополнительный файл .vsr, который содержит еще
// несколько правил. В репозитории есть пример файла Grijjy.Symbolication.vsr,
// который делает все символы, о которых мы заботимся, глобальными:
//    SYMBOLS {
//      global:
//        _ZN*;
//        _ZZ*;
//    };
// В этом файле говорится, что все символы, начинающиеся с _ZN или _ZZ,
// должны быть глобальными. Это префиксы управляемых имен символов. Каждое
// управляемое имя начинается с _Z, а после него идут пространсва имен
// с буквой N. Поскольку Delphi включает имя модуля в каждый символ
// (типа такого MyUnit.MyProc), то почти каждый символ начинается с _ZN.
// Исключение составляют вложенные процедуры, которые начинаются с _ZZ.

//  NOTES FOR MACOS
//  ---------------
//  To enable line number information:
//  * Add the following post-build event to a 64-bit macOS configuration:
//      LNG.exe "$(OUTPUTPATH)"
//    Make sure the LNG (Line Number Generator) is in the system path, or use an
//    absolute or relative path. The source code for this tool can be found
//    in the Tools directory.
//    Make sure the "Cancel on error" option is checked.
//  * Deploy the .gol file:
//    * In the Deployment Mananger, add the .gol file (usually found in the
//      OSX64\<config>\ directory).
//    * Set the Remote Path to "Contents\MacOS\"
//  * Make sure you do *NOT* deploy the dSYM file, since this is not needed.
//    Uncheck it in the Deployment Manager.
//
//  Note: the LNG tool uses the dSYM file to extract line number information. If
//  the tool fails for some reason (for example, because the dSYM is not
//  available), then an error is logged to the Output window in Delphi, and the
//  Delphi compilation will fail. The tool creates a .gol file in the same
//  directory as the executable.

interface

{$IFDEF SiDebugMobile} // SiDebugMobile - не работает, глобально выключен до завершения экспериментов

uses
  {$IF Defined(MACOS64) and not Defined(IOS)}
  Grijjy.LineNumberInfo,
  {$ENDIF}
  System.SysUtils,
  System.Messaging;

type
  // Signature of the TApplication.OnException event
  // Сигнатура события TApplication.OnException
  TgoExceptionEvent = procedure(Sender: TObject; E: Exception) of object;

type
  // A single entry in a stack trace
  // Одна запись в трассировке стека
  TgoCallStackEntry = record
  public
    // The address of the code in the call stack.
    // Адрес кода в стеке вызовов
    CodeAddress: UIntPtr;

    // The address of the start of the routine in the call stack. The CodeAddress
    // value always lies inside the routine that starts at RoutineAddress.
    // This, the value "CodeAddress - RoutineAddress" is the offset into the
    // routine in the call stack.
    //
    // Адрес начала процедуры в стеке вызовов. CodeAddress  всегда находится
    // внутри процедуры, которая начинается по адресу RoutineAddress.
    // Таким образом, значение "CodeAddress - RoutineAddress" является
    // смещением в стеке вызовов.
    RoutineAddress: UIntPtr;

    // The (base) address of the module where CodeAddress is found.
    // Базовый адрес модуля, в котором находится CodeAddress
    ModuleAddress: UIntPtr;

    // The line number (of CodeAddress), or 0 if not available.
    // Номер строки (из CodeAddress), или 0, если строка недоступна.
    LineNumber: Integer;

    // The name of the routine at CodeAddress, if available.
    // Имя процедуры в CodeAddress, если доступно.
    RoutineName: String;

    // The name of the module where CodeAddress is found. If CodeAddress is
    // somewhere inside your (Delphi) code, then this will be the name of the
    // executable module (or .so file on Android).
    //
    // Имя модуля, в котором найден CodeAddress. Если CodeAddress находится
    // где-то внутри вашего кода (Delphi), то это будет имя
    // исполняемого модуля (или файла .so в Android).
    ModuleName: String;
  public
    // Clears the entry (sets everything to 0)
    // Очищает запись (устанавливает все в 0)
    procedure Clear;
  end;

type
  // A call stack (aka stack trace) is just an array of call stack entries.
  // Стек вызовов (он же трассировка стека) - это просто массив записей стека вызовов.
  TgoCallStack = TArray<TgoCallStackEntry>;

type
  //  Represents an exception report. When an unhandled exception is encountered,
  //  it creates an exception report and broadcasts is using a TgoExceptionReportMessage
  //
  //  Представляет собой отчет об исключении. Когда встречается необработанное исключение,
  //  создается отчет об исключении и передается с помощью TgoExceptionReportMessage
  IgoExceptionReport = interface
  ['{A949A858-3B30-4C39-9A18-AD2A86B4BD9F}']
    {$REGION 'Internal Declarations'}
    function _GetExceptionMessage: String;
    function _GetExceptionLocation: TgoCallStackEntry;
    function _GetCallStack: TgoCallStack;
    function _GetReport: String;
    {$ENDREGION 'Internal Declarations'}

    // The exception message (the value of the Exception.Message property)
    // Сообщение об исключении (значение свойства Exception.Message)
    property ExceptionMessage: String read _GetExceptionMessage;

    //  The location (address) of the exception. This is of type
    //  TgoCallStackEntry, so it also contains information about where and in
    //  which routine the exception happened.
    //
    //  Местоположение (адрес) исключения. Этот адрес имеет тип
    //  TgoCallStackEntry, поэтому он также содержит информацию о том,
    //  где и в какой процедуре произошло исключение.
    property ExceptionLocation: TgoCallStackEntry read _GetExceptionLocation;

    //  The call stack (aka stack trace) leading up the the exception. This
    //  also includes calls into the exception handler itself.
    //
    //  Стек вызовов (он же трассировка стека), приведший к возникновению
    //  исключения. Этот стек также включает вызовы самого обработчика исключения.
    property CallStack: TgoCallStack read _GetCallStack;

    //  A textual version of the exception. Contains the exception messages as
    //  well as a textual representation of the call stack.
    //
    //  Текстовая версия исключения. Содержит сообщения об исключении, а также
    //  текстовое представление стека вызовов.
    property Report: String read _GetReport;
  end;

type
  //  A type of TMessage that is used to broadcast exception reports.
  //  Subscribe to this message (using TMessageManager.DefaultManager.SubscribeToMessage)
  //  to get notified about exception reports.
  //
  //  Important: This message is sent from the thread where the exception
  //  occured, which may not always be the UI thread. So don't update the UI from
  //  this message, or synchronize it with the main thread.
  //
  //  Тип TMessage, который используется для передачи сообщений об исключениях.
  //  Подпишитесь на это сообщение (используя TMessageManager.DefaultManager.SubscribeToMessage),
  //  чтобы получать уведомления об  сообщениях об исключениях.
  //
  //  Важно: Это сообщение отправляется из потока, в котором произошло исключение.
  //  которое не всегда является потоком пользовательского интерфейса.
  //  Поэтому не обновляйте пользовательский интерфейс из этого сообщения
  //  или синхронизируйте его с главным потоком.

  TgoExceptionReportMessage = class(TMessage)
  {$REGION 'Internal Declarations'}
  private
    FReport: IgoExceptionReport;
  {$ENDREGION 'Internal Declarations'}
  public
    // Used internally to create the message.
    // Используется внутри для создания сообщения.
    constructor Create(const AReport: IgoExceptionReport);

    // The exception report.
    // Отчет об исключении.
    property Report: IgoExceptionReport read FReport;
  end;

type
  // Main class for reporting exceptions. See the documentation at the
  // top of this unit for usage information.
  //
  // Основной класс для создания отчетов об исключениях. Информацию об
  // использовании см. в документации в верхней части этого модуля.
  TgoExceptionReporter = class
  {$REGION 'Internal Declarations'}
  private class var
    FInstance: TgoExceptionReporter;
    {$IF Defined(MACOS64) and not Defined(IOS)}
    FLineNumberInfo: TgoLineNumberInfo;
    class function GetLineNumber(const AAddress: UIntPtr): Integer; static;
    {$ENDIF}
    class function GetExceptionHandler: TgoExceptionEvent; static;
    class function GetMaxCallStackDepth: Integer; static;
    class procedure SetMaxCallStackDepth(const Value: Integer); static;
  private
    FMaxCallStackDepth: Integer;
    FModuleAddress: UIntPtr;
    FReportingException: Boolean;
    FUnhandledExceptionCount: Int64;
  private
    constructor InternalCreate(const ADummy: Integer = 0);
    procedure ReportException(const AExceptionObject: TObject;
      const AExceptionAddress: Pointer);
  private
    class function GetCallStack(const AStackInfo: Pointer): TgoCallStack; static;
    class function GetCallStackEntry(var AEntry: TgoCallStackEntry): Boolean; static;
  private
    // Global hooks
    // Глобальные обработчики
    procedure GlobalHandleException(Sender: TObject; E: Exception);
    class procedure GlobalExceptionAcquiredHandler(Obj: {$IFDEF AUTOREFCOUNT}TObject{$ELSE}Pointer{$ENDIF}); static;
    class procedure GlobalExceptHandler(ExceptObject: TObject; ExceptAddr: Pointer); static;
    class function GlobalGetExceptionStackInfo(P: PExceptionRecord): Pointer; static;
    class procedure GlobalCleanUpStackInfo(Info: Pointer); static;
  {$ENDREGION 'Internal Declarations'}
  public
    // Don't call the constructor manually. This is a singleton.
    // Не вызывайте конструктор вручную. Это синглтон.
    constructor Create;

    // возвращает текущее значение счётчика необработанных исключений; счётчик при этом обнуляется
    class function GetUnhandledExceptionCountDelta: Int64;

    // Set to Application.OnException handler event to this value to report
    // unhandled exceptions in the main (UI) thread.
    //
    // Установите для события обработчика Application.OnException это значение,
    // чтобы сообщать о необработанных исключений в главном потоке (UI).
    //  Например:
    //    Application.OnException := TgoExceptionReporter.ExceptionHandler;
    class property ExceptionHandler: TgoExceptionEvent read GetExceptionHandler;

    //  Maximum depth of the call stack that is retrieved when an exception
    //  occurs. Defaults to 20.
    //
    //  Every time an exception is raised, we retrieve a call stack.
    //  This adds a little overhead, but raising exceptions is already
    //  an "expensive" operation anyway.
    //
    //  You can limit this overhead by decreasing the maximum number of entries
    //  in the call stack. You can also increase this number of you want a more
    //  detailed call stack.
    //
    //  Set to 0 to disable call stacks altogether.
    //
    //  Максимальная глубина стека вызовов, которая извлекается при
    //  возникновении исключения. По умолчанию равно 20.
    //
    //  Каждый раз, когда возникает исключение, мы извлекаем стек вызовов.
    //  Это добавляет немного накладных расходов, но поднятие исключений
    //  сао посебе и так является "дорогой" операцией в любом случае.
    //
    //  Вы можете ограничить эти накладные расходы, уменьшив максимальное
    //  количество записей в стеке вызовов. Вы также можете увеличить это
    //  число, если хотите получить более подробный стек вызовов.
    //
    //  Установите значение 0, чтобы полностью отключить стек вызовов.
    class property MaxCallStackDepth: Integer read GetMaxCallStackDepth write SetMaxCallStackDepth;
  end;

  procedure AddIgnoredException(const ExceptionClass: TClass);

{$ENDIF} // SiDebugMobile - не работает, глобально выключен до завершения экспериментов

implementation

{$IFDEF SiDebugMobile} // SiDebugMobile - не работает, глобально выключен до завершения экспериментов

uses
  {$IF Defined(MACOS) or Defined(ANDROID)}
  Posix.Dlfcn,
  Posix.Stdlib,
  {$ENDIF}
  System.Classes;

  //  В оригиналной библиотеке здесь еще был подключен модуль Grijjy.SymbolTranslator
  //  Для приблизителного превода символическиих названий методов из стиля C++
  //  в стиль Pascal. Перевод в Grijjy.SymbolTranslator приблизительный и не может
  //  перевести все конструкции C++, поэтому часть возвращаемой строки может быть
  //  непереведенными. Однако результат достаточно хорош, чтобы можно было найти его
  //  в исходном коде Pascal.
  //  Решено Grijjy.SymbolTranslator по ка не использовать. По краней мере на первых порах.

{$RANGECHECKS OFF}

type
  TgoExceptionReport = class(TInterfacedObject, IgoExceptionReport)
  private
    FCallStack: TgoCallStack;
    FExceptionClass: TClass;
    FExceptionLocation: TgoCallStackEntry;
    FExceptionMessage: String;
    FReport: String;
  private
    function BuildReport: String;
    class function AddressToString(const AAddress: UIntPtr): String; static;
  protected
    { IgoExceptionReport }
    function _GetExceptionMessage: String;
    function _GetExceptionLocation: TgoCallStackEntry;
    function _GetCallStack: TgoCallStack;
    function _GetReport: String;
  public
    constructor Create(const AExceptionClass: TClass; const AExceptionMessage: String;
      const AExceptionLocation: TgoCallStackEntry;
      const ACallStack: TgoCallStack);
  end;

{ TgoExceptionReport }

class function TgoExceptionReport.AddressToString(
  const AAddress: UIntPtr): String;
begin
  {$IFDEF CPU64BITS}
  Result := '$' + IntToHex(AAddress, 16);
  {$ELSE}
  Result := '$' + IntToHex(AAddress, 8);
  {$ENDIF}
end;

function TgoExceptionReport.BuildReport: String;
var
  SB: TStringBuilder;
  Entry: TgoCallStackEntry;
const
  TabSeparator = ' ';
begin

  SB := TStringBuilder.Create;
  try
    SB.AppendLine(FExceptionMessage);

    SB.AppendLine.AppendLine('Exception class:');
    if Assigned(FExceptionClass) then
      SB.AppendLine(FExceptionClass.QualifiedClassName)
    else
      SB.AppendLine('<none>');

    SB.AppendLine.AppendLine('Exception address:').Append(AddressToString(FExceptionLocation.CodeAddress));

    if not FExceptionLocation.ModuleName.IsEmpty then
      SB.Append(TabSeparator).Append(ExtractFilename(FExceptionLocation.ModuleName));

    if not FExceptionLocation.RoutineName.IsEmpty then
    begin
      SB.Append(TabSeparator).Append(FExceptionLocation.RoutineName).Append(' + ').Append(FExceptionLocation.CodeAddress - FExceptionLocation.RoutineAddress);
      if (FExceptionLocation.LineNumber > 0) then
      begin
        SB.Append(', line ').Append(FExceptionLocation.LineNumber)
      end;
      SB.AppendLine;
    end
    else
      SB.AppendLine;

    SB.AppendLine;

    if (FCallStack <> nil) then
    begin
      SB.AppendLine('Call stack:');
      for Entry in FCallStack do
      begin
        if Entry.CodeAddress = 0 then
        begin
          // Значение CodeAddress = 0 означает, что в
          // TgoExceptionReporter.GetCallStack смогли найти LR.
          // Подумать что с этим делать? (поэксперементировать с Grijjy.Symbolication.vsr)
          SB.Append(AddressToString(Entry.CodeAddress)).Append(TabSeparator).AppendLine(Entry.RoutineName);
        end
        else
        begin
          SB.Append(AddressToString(Entry.CodeAddress)).Append(TabSeparator).Append(ExtractFilename(Entry.ModuleName));

          if not Entry.RoutineName.IsEmpty then
          begin
            SB.Append(TabSeparator).Append(Entry.RoutineName).Append(' + ').Append(Entry.CodeAddress - Entry.RoutineAddress);
            if (Entry.LineNumber > 0) then
            begin
              SB.Append(', line ').Append(Entry.LineNumber)
            end;
          end;
          SB.AppendLine;
        end;
      end;
    end;

    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

constructor TgoExceptionReport.Create(const AExceptionClass: TClass; const AExceptionMessage: String;
  const AExceptionLocation: TgoCallStackEntry; const ACallStack: TgoCallStack);
begin
  inherited Create;
  FExceptionClass := AExceptionClass;
  FExceptionMessage := AExceptionMessage;
  FExceptionLocation := AExceptionLocation;
  FCallStack := ACallStack;
end;

function TgoExceptionReport._GetCallStack: TgoCallStack;
begin
  Result := FCallStack;
end;

function TgoExceptionReport._GetExceptionLocation: TgoCallStackEntry;
begin
  Result := FExceptionLocation;
end;

function TgoExceptionReport._GetExceptionMessage: String;
begin
  Result := FExceptionMessage;
end;

function TgoExceptionReport._GetReport: String;
begin
  if (FReport = '') then
    FReport := BuildReport;
  Result := FReport;
end;

{ TgoExceptionReportMessage }

constructor TgoExceptionReportMessage.Create(const AReport: IgoExceptionReport);
begin
  inherited Create;
  FReport := AReport;
end;

{ TgoCallStackEntry }

procedure TgoCallStackEntry.Clear;
begin
  CodeAddress := 0;
  RoutineAddress := 0;
  ModuleAddress := 0;
  LineNumber := 0;
  RoutineName := '';
  ModuleName := '';
end;


var
  IgnoredExceptions: TThreadList = nil;

procedure AddIgnoredException(const ExceptionClass: TClass);
begin
  if Assigned(ExceptionClass) then
  begin
    if not Assigned(IgnoredExceptions) then
      IgnoredExceptions := TThreadList.Create;

    IgnoredExceptions.Add(ExceptionClass);
  end;
end;

function IsIgnoredException(const ExceptionClass: TClass): Boolean;
var
  ClassList: TList;
  Index: Integer;
begin
  Result := False;
  if Assigned(IgnoredExceptions) then
  begin
    ClassList := IgnoredExceptions.LockList;
    try
      for Index := 0 to ClassList.Count - 1 do
        if ExceptionClass.InheritsFrom(TClass(ClassList.Items[Index])) then
      begin
        Result := True;
        Break;
      end;
    finally
      IgnoredExceptions.UnlockList;
    end;
  end;
end;

{ TgoExceptionReporter }

constructor TgoExceptionReporter.Create;
begin
  raise EInvalidOperation.Create('Invalid singleton TgoExceptionReporter constructor call');
end;

class function TgoExceptionReporter.GetExceptionHandler: TgoExceptionEvent;
begin
  //  HandleException is usually called in response to the FMX
  //  Application.OnException event, which is called for exceptions that aren't
  //  handled in the main thread. This event is only fired for exceptions that
  //  occur in the main (UI) thread though.
  //
  //  HandleException обычно вызывается в ответ на событие FMX
  //  Application.OnException, которое вызывается для исключений, которые не были
  //  обрабатываются в главном потоке. Это событие вызывается только для исключений,
  //  которые происходят в главном потоке (UI).
  if Assigned(FInstance) then
    Result := FInstance.GlobalHandleException
  else
    Result := nil;
end;

class function TgoExceptionReporter.GetMaxCallStackDepth: Integer;
begin
  if Assigned(FInstance) then
    Result := FInstance.FMaxCallStackDepth
  else
    Result := 20;
end;

class procedure TgoExceptionReporter.GlobalCleanUpStackInfo(Info: Pointer);
begin
  // Free memory allocated by GlobalGetExceptionStackInfo
  // Освободить память, выделенную GlobalGetExceptionStackInfo
  if (Info <> nil) then
    FreeMem(Info);
end;

class procedure TgoExceptionReporter.GlobalExceptHandler(ExceptObject: TObject; ExceptAddr: Pointer);
begin
  if Assigned(FInstance) then
    FInstance.ReportException(ExceptObject, ExceptAddr);
end;

class procedure TgoExceptionReporter.GlobalExceptionAcquiredHandler(
  Obj: {$IFDEF AUTOREFCOUNT}TObject{$ELSE}Pointer{$ENDIF});
begin
  if Assigned(FInstance) then
    FInstance.ReportException(Obj, ExceptAddr);
end;

procedure TgoExceptionReporter.GlobalHandleException(Sender: TObject; E: Exception);
begin
  ReportException(E, ExceptAddr);
end;

class function TgoExceptionReporter.GetUnhandledExceptionCountDelta: Int64;
begin
  if Assigned(FInstance) then
    Exit(AtomicExchange(FInstance.FUnhandledExceptionCount, 0))
  else
    Exit(0);
end;

constructor TgoExceptionReporter.InternalCreate(const ADummy: Integer);
{$IF Defined(IOS) or Defined(ANDROID)}
var
  Info: dl_info;
{$ENDIF}
begin
  inherited Create;
  FMaxCallStackDepth := 20;

  //  Assign the global ExceptionAcquired procedure to our own implementation (it
  //  is nil by default). This procedure gets called for unhandled exceptions that
  //  happen in other threads than the main thread.
  //
  //  Назначить глобальную процедуру ExceptionAcquired нашей собственной реализации
  //  (по умолчанию она по умолчанию равна nil). Эта процедура вызывается для
  //  необработанных исключений, которые происходят в других потоках, кроме основного.

  ExceptionAcquired := @GlobalExceptionAcquiredHandler;

  //  The global ExceptProc method can be called for certain unhandled exception.
  //  By default, it calls the ExceptHandler procedure in the System.SysUtils
  //  unit, which shows the exception message and terminates the app.
  //  We set it to our own implementation.
  //
  //  Глобальный метод ExceptProc может быть вызван для определенного
  //  необработанного исключения. По умолчанию он вызывает процедуру ExceptHandler
  //  в блоке System.SysUtils которая выводит сообщение об исключении и завершает
  //  работу приложения. Мы настроим ее на нашу собственную реализацию.

  ExceptProc := @GlobalExceptHandler;

  //  We hook into the global static GetExceptionStackInfoProc and
  //  CleanUpStackInfoProc methods of the Exception class to provide a call stack
  //  for the exception. These methods are unassigned by default.
  //  The Exception.GetExceptionStackInfoProc method gets called soon after the
  //  exception is created, before the call stack is unwound. This is the only
  //  place where we can get the call stack at the point closest to the exception
  //  as possible. The Exception.CleanUpStackInfoProc just frees the memory
  //  allocated by GetExceptionStackInfoProc.
  //
  //  Мы подключаемся к глобальным статическим методам GetExceptionStackInfoProc и
  //  методы CleanUpStackInfoProc класса Exception, чтобы предоставить стек вызовов
  //  для исключения. По умолчанию эти методы не назначены.
  //  Метод Exception.GetExceptionStackInfoProc вызывается вскоре после того как
  //  исключение создано, но до того, как стек вызовов будет развернут.
  //  Это единственное место, где мы можем получить стек вызовов в точке,
  //  наиболее близкой к исключению насколько это возможно.
  //  Exception.CleanUpStackInfoProc просто освобождает память,
  //  выделенную GetExceptionStackInfoProc.

  Exception.GetExceptionStackInfoProc := GlobalGetExceptionStackInfo;
  Exception.CleanUpStackInfoProc := GlobalCleanUpStackInfo;

  {$IF Defined(IOS) or Defined(ANDROID)}
  //  Get address of current module. We use this to see if an entry in the call
  //  stack is part of this module.
  //  We use the dladdr API as a "trick" to get the address of this method, which
  //  is obviously part of this module.
  //
  //  Получить адрес текущего модуля. Мы используем это, чтобы узнать,
  //  является ли запись в стеке вызовов частью этого модуля.
  //  Мы используем API dladdr как "трюк", чтобы получить адрес этого
  //  метода, который очевидно, является частью этого модуля.

  if (dladdr(UIntPtr(@TgoExceptionReporter.InternalCreate), Info) <> 0) then
    FModuleAddress := UIntPtr(Info.dli_fbase);
  {$ENDIF}
end;

procedure TgoExceptionReporter.ReportException(const AExceptionObject: TObject;
  const AExceptionAddress: Pointer);
var
  E: Exception;
  ExceptionClass: TClass;
  ExceptionMessage: String;
  CallStack: TgoCallStack;
  ExceptionLocation: TgoCallStackEntry;
  Report: IgoExceptionReport;
  I: Integer;
begin
  // Ignore exception that occur while we are already reporting another
  // exception. That can happen when the original exception left the application
  // in such a state that other exceptions would happen (cascading errors).
  //
  // Игнорировать исключения, возникающие в то время, когда мы уже сообщаем
  // о другом исключение. Это может произойти, когда исходное исключение
  // оставило приложение в таком состоянии, что могут возникнуть
  // другие исключения (каскадные ошибки).

  if (FReportingException) then
    Exit;

  FReportingException := True;
  try
    CallStack := nil;
    if (AExceptionObject = nil) then
    begin
      ExceptionClass := nil;
      ExceptionMessage := 'Unknown Error';
    end
    else if (AExceptionObject is EAbort) then
      Exit //  do nothing
    else if (AExceptionObject is Exception) then
    begin
      E := Exception(AExceptionObject);
      ExceptionClass := E.ClassType;

      if IsIgnoredException(E.ClassType) then
        Exit;

      ExceptionMessage := E.Message;
      if (E.StackInfo <> nil) then
      begin
        CallStack := GetCallStack(E.StackInfo);
        for I := 0 to Length(Callstack) - 1 do
        begin
          // If entry in call stack is for this module, then try to translate the routine name to Pascal.
          // Если запись в стеке вызовов относится к этому модулю, то попробавать перевести имя процедуры на язык Pascal.
          // Выключил - т.к. решено Grijjy.SymbolTranslator по ка не использовать.
          //   if (CallStack[I].ModuleAddress = FModuleAddress) then
          //     CallStack[I].RoutineName := goCppSymbolToPascal(CallStack[I].RoutineName);
        end;
      end;
    end
    else
    begin
      ExceptionClass := AExceptionObject.ClassType;
      ExceptionMessage := 'Unknown Error';
    end;

    AtomicIncrement(FUnhandledExceptionCount);

    ExceptionLocation.Clear;
    ExceptionLocation.CodeAddress := UIntPtr(AExceptionAddress);
    GetCallStackEntry(ExceptionLocation);

    // Выключил - т.к. решено Grijjy.SymbolTranslator по ка не использовать.
    //   if (ExceptionLocation.ModuleAddress = FModuleAddress) then
    //     ExceptionLocation.RoutineName := goCppSymbolToPascal(ExceptionLocation.RoutineName);

    Report := TgoExceptionReport.Create(ExceptionClass, ExceptionMessage, ExceptionLocation, CallStack);
    try
      TMessageManager.DefaultManager.SendMessage(Self,
        TgoExceptionReportMessage.Create(Report));
    except
      // Ignore any exceptions in the report message handler.
      // Игнорировать любые исключения в обработчике сообщений отчета.
    end;
  finally
    FReportingException := False;
  end;
end;

class procedure TgoExceptionReporter.SetMaxCallStackDepth(const Value: Integer);
begin
  if Assigned(FInstance) then
    FInstance.FMaxCallStackDepth := Value;
end;

{$IF Defined(MACOS)}

(*****************************************************************************)
(*** iOS/macOS specific ******************************************************)
(*****************************************************************************)

const
  libSystem = '/usr/lib/libSystem.dylib';

function backtrace(buffer: PPointer; size: Integer): Integer;
  external libSystem name 'backtrace';

function cxa_demangle(const mangled_name: MarshaledAString;
  output_buffer: MarshaledAString; length: NativeInt;
  out status: Integer): MarshaledAString; cdecl;
  external libSystem name '__cxa_demangle';

type
  TCallStack = record
    { Number of entries in the call stack }
    Count: Integer;

    { The entries in the call stack }
    Stack: array [0..0] of UIntPtr;
  end;
  PCallStack = ^TCallStack;

class function TgoExceptionReporter.GlobalGetExceptionStackInfo(
  P: PExceptionRecord): Pointer;
var
  CallStack: PCallStack;
begin
  { Don't call into FInstance here. That would only add another entry to the
    call stack. Instead, retrieve the entire call stack from within this method.
    Just return nil if we are already reporting an exception, or call stacks
    are disabled. }
  if (FInstance = nil) or (FInstance.FReportingException) or (FInstance.FMaxCallStackDepth <= 0) then
    Exit(nil);

  { Allocate a PCallStack record large enough to hold just MaxCallStackDepth
    entries }
  GetMem(CallStack, SizeOf(Integer{TCallStack.Count}) +
    FInstance.FMaxCallStackDepth * SizeOf(Pointer));

  { Use backtrace API to retrieve call stack }
  CallStack.Count := backtrace(@CallStack.Stack, FInstance.FMaxCallStackDepth);
  Result := CallStack;
end;

class function TgoExceptionReporter.GetCallStack(
  const AStackInfo: Pointer): TgoCallStack;
var
  CallStack: PCallStack;
  I: Integer;
begin
  { Convert TCallStack to TgoCallStack }
  CallStack := AStackInfo;
  SetLength(Result, CallStack.Count);
  for I := 0 to CallStack.Count - 1 do
  begin
    Result[I].CodeAddress := CallStack.Stack[I];
    GetCallStackEntry(Result[I]);
  end;
end;

{$IF Defined(MACOS64) and not Defined(IOS)}
class function TgoExceptionReporter.GetLineNumber(const AAddress: UIntPtr): Integer;
begin
  if (FLineNumberInfo = nil) then
    FLineNumberInfo := TgoLineNumberInfo.Create;
  Result := FLineNumberInfo.Lookup(AAddress);
end;
{$ENDIF}

{$ELSEIF Defined(ANDROID64)}

(*****************************************************************************)
(*** Android64 specific ******************************************************)
(*****************************************************************************)

function cxa_demangle(const mangled_name: MarshaledAString;
  output_buffer: MarshaledAString; length: NativeInt;
  out status: Integer): MarshaledAString; cdecl;
  external 'libc++abi.a' name '__cxa_demangle';

type
  _PUnwind_Context = Pointer;
  _Unwind_Ptr = UIntPtr;

type
  _Unwind_Reason_code = Integer;

const
  _URC_NO_REASON = 0;
  _URC_FOREIGN_EXCEPTION_CAUGHT = 1;
  _URC_FATAL_PHASE2_ERROR = 2;
  _URC_FATAL_PHASE1_ERROR = 3;
  _URC_NORMAL_STOP = 4;
  _URC_END_OF_STACK = 5;
  _URC_HANDLER_FOUND = 6;
  _URC_INSTALL_CONTEXT = 7;
  _URC_CONTINUE_UNWIND = 8;
type
  _Unwind_Trace_Fn = function(context: _PUnwind_Context; userdata: Pointer): _Unwind_Reason_code; cdecl;

const
  LIB_UNWIND = 'libunwind.a';

procedure _Unwind_Backtrace(fn: _Unwind_Trace_Fn; userdata: Pointer); cdecl; external LIB_UNWIND;
function _Unwind_GetIP(context: _PUnwind_Context): _Unwind_Ptr; cdecl; external LIB_UNWIND;

type
  TCallStack = record
    // Number of entries in the call stack
    // Количество записей в стеке вызовов
    Count: Integer;

    // The entries in the call stack
    // Элементы в стеке вызовов
    Stack: array [0..0] of UIntPtr;
  end;
  PCallStack = ^TCallStack;

function UnwindCallback(AContext: _PUnwind_Context; AUserData: Pointer): _Unwind_Reason_code; cdecl;
var
  Callstack: PCallstack;
begin
  Callstack := AUserData;
  if (TgoExceptionReporter.FInstance = nil) or (Callstack.Count >= TgoExceptionReporter.FInstance.FMaxCallStackDepth) then
    Exit(_URC_END_OF_STACK);

  Callstack.Stack[Callstack.Count] := _Unwind_GetIP(AContext);
  Inc(Callstack.Count);
  Result := _URC_NO_REASON;
end;

class function TgoExceptionReporter.GlobalGetExceptionStackInfo(P: PExceptionRecord): Pointer;
var
  CallStack: PCallStack;
begin
  //  Don't call into FInstance here. That would only add another entry to the
  //  call stack. Instead, retrieve the entire call stack from within this method.
  //  Just return nil if we are already reporting an exception, or call stacks
  //  are disabled.
  //
  //  Не вызывать здесь FInstance. Это только добавит еще одну запись в стек
  //  вызовов. Вместо этого получть весь стек вызовов из этого метода.
  //  Просто вернуть nil, если мы уже сообщаем об исключении, или если
  //  стек вызовов отключен.

  if (FInstance = nil) or (FInstance.FReportingException) or (FInstance.FMaxCallStackDepth <= 0) then
    Exit(nil);

  //  Allocate a PCallStack record large enough to hold just MaxCallStackDepth entries
  //  Выделить запись PCallStack столько, чтобы вместить только MaxCallStackDepth элементов

  GetMem(CallStack, SizeOf(Integer{TCallStack.Count}) +
    FInstance.FMaxCallStackDepth * SizeOf(Pointer));

  // Use _Unwind_Backtrace API to retrieve call stack
  // Использовать API _Unwind_Backtrace для получения стека вызовов

  CallStack.Count := 0;
  _Unwind_Backtrace(UnwindCallback, Callstack);
  Result := CallStack;
end;

class function TgoExceptionReporter.GetCallStack(const AStackInfo: Pointer): TgoCallStack;
var
  CallStack: PCallStack;
  I: Integer;
begin
  // Convert TCallStack to TgoCallStack
  // Преобразование TCallStack в TgoCallStack

  CallStack := AStackInfo;
  SetLength(Result, CallStack.Count);
  for I := 0 to CallStack.Count - 1 do
  begin
    Result[I].CodeAddress := CallStack.Stack[I];
    GetCallStackEntry(Result[I]);
  end;
end;

{$ELSEIF Defined(ANDROID)}

(*****************************************************************************)
(*** Android32 specific ******************************************************)
(*****************************************************************************)

type
  TGetFramePointer = function: NativeUInt; cdecl;

const

  //  We need a function to get the frame pointer. The address of this frame
  //  pointer is stored in register R7.
  //  In assembly code, the function would look like this:
  //    ldr R0, [R7]       // Retrieve frame pointer
  //    bx  LR             // Return to caller
  //  The R0 register is used to store the function result.
  //  The "bx LR" line means "return to the address stored in the LR register".
  //  The LR (Link Return) register is set by the calling routine to the address
  //  to return to.
  //
  //  We could create a text file with this code, assemble it to a static library,
  //  and link that library into this unit. However, since the routine is so
  //  small, it assembles to just 8 bytes, which we store in an array here.
  //
  //  Нам нужна функция для получения указателя кадра. Адрес этого указателя кадра
  //  хранится в регистре R7.
  //  В ассемблерном коде функция будет выглядеть следующим образом:
  //    ldr R0, [R7]       // Получение указателя кадра
  //    bx  LR             // Возврат к вызывающей стороне
  //
  //  Регистр R0 используется для хранения результата функции.
  //  Строка "bx LR" означает "вернуться по адресу, хранящемуся в регистре LR".
  //  Регистр LR (Link Return) устанавливается вызывающей программой на адрес
  //  по которому следует вернуться.
  //
  //  Мы можем создать текстовый файл с этим кодом, собрать его в статическую библиотеку,
  //  и подключить эту библиотеку к данному модулю. Однако, поскольку процедура настолько
  //  маленькая, она собирается всего в 8 байт, которые мы храним в массиве здесь.

  GET_FRAME_POINTER_CODE: array [0..7] of Byte = (
    $00, $00, $97, $E5,  // ldr R0, [R7]
    $1E, $FF, $2F, $E1); // bx  LR

var
  // Now define a variable of a procedural type, that is assigned to the assembled code above
  // Теперь определить переменную процедурного типа, которая будет присвоена собранному выше коду

  GetFramePointer: TGetFramePointer = @GET_FRAME_POINTER_CODE;

function cxa_demangle(const mangled_name: MarshaledAString;
  output_buffer: MarshaledAString; length: NativeInt;
  out status: Integer): MarshaledAString; cdecl;
  external {$IF (RTLVersion < 34)}'libgnustl_static.a'{$ELSE}'libc++abi.a'{$ENDIF} name '__cxa_demangle';

type
  //  For each entry in the call stack, we save 7 values for inspection later.
  //  See GlobalGetExceptionStackInfo for explaination.
  //
  //  Для каждой записи в стеке вызовов мы сохраняем 7 значений для последующей проверки.
  //  Объяснение см. в GlobalGetExceptionStackInfo.

  TStackValues = array [0..6] of UIntPtr;

type
  TCallStack = record
    // Number of entries in the call stack
    // Количество записей в стеке вызовов
    Count: Integer;

    // The entries in the call stack
    // Элементы в стеке вызовов
    Stack: array [0..0] of TStackValues;
  end;
  PCallStack = ^TCallStack;

class function TgoExceptionReporter.GlobalGetExceptionStackInfo(P: PExceptionRecord): Pointer;
const
  // On most Android systems, each thread has a stack of 1MB
  // В большинстве систем Android каждый поток имеет стек размером 1 МБ

  MAX_STACK_SIZE = 1024 * 1024;
var
  MaxCallStackDepth, Count: Integer;
  FramePointer, MinStack, MaxStack: UIntPtr;
  Address: Pointer;
  CallStack: PCallStack;
begin
  //  Don't call into FInstance here. That would only add another entry to the
  //  call stack. Instead, retrieve the entire call stack from within this method.
  //  Just return nil if we are already reporting an exception, or call stacks
  //  are disabled.
  //
  //  Не вызывать здесь FInstance. Это только добавит еще одну запись в стек
  //  вызовов. Вместо этого получть весь стек вызовов из этого метода.
  //  Просто вернуть nil, если мы уже сообщаем об исключении, или если
  //  стек вызовов отключен.

  if (FInstance = nil) or (FInstance.FReportingException) or (FInstance.FMaxCallStackDepth <= 0) then
    Exit(nil);

  MaxCallStackDepth := FInstance.FMaxCallStackDepth;

  //  Allocate a PCallStack record large enough to hold just MaxCallStackDepth entries
  //  Выделить запись PCallStack столько, чтобы вместить только MaxCallStackDepth элементов

  GetMem(CallStack, SizeOf(Integer{TCallStack.Count}) +
    MaxCallStackDepth * SizeOf(TStackValues));

  //  We manually walk the stack to create a stack trace. This is possible since
  //  Delphi creates a stack frame for each routine, by starting each routine with
  //  a prolog. This prolog is similar to the one used by the iOS ABI (Application
  //  Binary Interface, see
  //  https://developer.apple.com/library/content/documentation/Xcode/Conceptual/iPhoneOSABIReference/Articles/ARMv7FunctionCallingConventions.html
  //
  //  The prolog looks like this:
  //  * Push all registers that need saving. Always push the R7 and LR registers.
  //  * Set R7 (frame pointer) to the location in the stack where the previous
  //    value of R7 was just pushed.
  //
  //  A minimal prolog (used in many small functions) looks like this:
  //
  //    push {R7, LR}
  //    mov  R7, SP
  //
  //  We are interested in the value of the LR (Link Return) register. This
  //  register contains the address to return to after the routine finishes. We
  //  can use this address to look up the symbol (routine name). Using the
  //  example prolog above, we can get to the LR value and walk the stack like
  //  this:
  //  1. Set FramePointer to the value of the R7 register.
  //  2. At this location in the stack, you will find the previous value of the
  //     R7 register. Lets call this PreviousFramePointer.
  //  3. At the next location in the stack, we will find the LR register. Add its
  //     value to our stack trace so we can use it later to look up the routine
  //     name at this address.
  //  4. Set FramePointer to PreviousFramePointer and go back to step 2, until
  //     FramePointer is 0 or falls outside of the stack.
  //
  //  Unfortunately, Delphi doesn't follow the iOS ABI exactly, and it may push
  //  other registers between R7 and LR. For example:
  //
  //    push {R4, R5, R6, R7, R8, R9, LR}
  //    add  R7, SP, #12
  //
  //  Here, it pushed 3 registers (R4-R6) before R7, so in the second line it sets
  //  R7 to point 12 bytes into the stack (so it still points to the previous R7,
  //  as required). However, it also pushed registers R8 and R9, before it pushes
  //  the LR register. This means we cannot assume that the LR register will be
  //  directly located after the R7 register in the stack. There may be (up to 6)
  //  registers in between. We don't know which one represents LR, so we just
  //  store all 7 values after R7, and later try to figure out which one
  //  represents LR (in the GetCallStack method).
  //
  //  --------------------------------------------------------------------------
  //  Мы вручную проходим по стеку, чтобы создать трассировку стека. Это возможно, поскольку
  //  Delphi создает кадр стека для каждой процедуры, начиная каждую процедуру с
  //  пролог. Этот пролог похож на тот, который используется в iOS ABI (Application
  //  Binary Interface, см.
  //    https://developer.apple.com/library/content/documentation/Xcode/Conceptual/iPhoneOSABIReference/Articles/ARMv7FunctionCallingConventions.html
  //
  //  Пролог выглядит следующим образом:
  //    * Поместить в стек все регистры, которые нужно сохранить. Всегда помещает регистры R7 и LR.
  //    * Установить R7 (указатель кадра) в то место в стеке, куда только что было помещено предыдущее значение R7.
  //
  //  Минимальный пролог (используемый во многих небольших функциях) выглядит следующим образом:
  //    push {R7, LR}
  //    mov  R7, SP
  //
  //  Нас интересует значение регистра LR (Link Return). Этот регистр содержит
  //  адрес, по которому следует вернуться после завершения работы программы.
  //  Мы можем использовать этот адрес для поиска символа (имени процедуры).
  //  Используя приведенный выше пример пролога, мы можем получить значение LR
  //  и пройтись по стеку следующим образом:
  //    1. Установить FramePointer в значение регистра R7.
  //    2. В этом месте в стеке вы найдем предыдущее значение регистра R7.
  //       Назовем это значение PreviousFramePointer.
  //    3. В следующем месте стека мы найдем регистр LR. Добавим его значение
  //       в трассировку стека, чтобы позже использовать его для поиска имени
  //       процедуры по этому адресу.
  //    4. Установить FramePointer в PreviousFramePointer и вернуться к шагу 2,
  //       пока FramePointer не станет равным 0 или не выйдет за пределы стека.
  //
  //  К сожалению, Delphi не совсем точно следует ABI iOS, и он может помещать
  //  другие регистры между R7 и LR. Например:
  //
  //    push {R4, R5, R6, R7, R8, R9, LR}
  //    add  R7, SP, #12
  //
  //  Здесь он поместил 3 регистра (R4-R6) перед R7, поэтому во второй строке
  //  он устанавливает R7 на 12 байт в стек (так что он все еще указывает на
  //  предыдущий R7, как и требуется). Однако, он также поместил регистры R8 и R9,
  //  прежде чем поместить регистр LR. Это означает, что мы не можем предположить,
  //  что регистр LR будет находиться непосредственно после регистра R7 в стеке.
  //  Там может быть (до 6) регистров между ними. Мы не знаем, какой из них
  //  представляет LR, поэтому мы просто сохраним все 7 значений после R7,
  //  а позже попытаемся выяснить, какой из них представляет LR (в методе GetCallStack).

  FramePointer := GetFramePointer;

  //  The stack grows downwards, so all entries in the call stack leading to this
  //  call have addresses greater than FramePointer. We don't know what the start
  //  and end address of the stack is for this thread, but we do know that the
  //  stack is at most 1MB in size, so we only investigate entries from
  //  FramePointer to FramePointer + 1MB.
  //
  //  Стек растет вниз, поэтому все записи в стеке вызовов, ведущие к этому
  //  вызову, имеют адреса больше, чем FramePointer. Мы не знаем, каковы
  //  начальный и конечный адреса стека для этого потока, но мы знаем, что
  //  размер стека составляет не более 1 МБ, поэтому мы исследуем только
  //  записи от FramePointer до FramePointer + 1 МБ.

  MinStack := FramePointer;
  MaxStack := MinStack + MAX_STACK_SIZE;

  // Now we can walk the stack using the algorithm described above.
  // Теперь мы можем пройтись по стеку, используя алгоритм, описанный выше.

  Count := 0;
  while (Count < MaxCallStackDepth) and (FramePointer <> 0)
    and (FramePointer >= MinStack) and (FramePointer < MaxStack) do
  begin
    // The first value at FramePointer contains the previous value of R7.
    // Store the 7 values after that.
    //
    // Первое значение в FramePointer содержит предыдущее значение R7.
    // Сохранить 7 последующих значений.

    Address := Pointer(FramePointer + SizeOf(UIntPtr));
    Move(Address^, CallStack.Stack[Count], SizeOf(TStackValues));
    Inc(Count);

    // The FramePointer points to the previous value of R7, which contains
    // the previous FramePointer.
    //
    // Указатель FramePointer указывает на предыдущее значение R7,
    // которое содержит предыдущий указатель фрейма.

    FramePointer := PNativeUInt(FramePointer)^;
  end;

  CallStack.Count := Count;
  Result := CallStack;
end;

class function TgoExceptionReporter.GetCallStack(const AStackInfo: Pointer): TgoCallStack;
var
  CallStack: PCallStack;
  I, J: Integer;
  FoundLR: Boolean;
begin
  // Convert TCallStack to TgoCallStack
  // Преобразование TCallStack в TgoCallStack

  CallStack := AStackInfo;
  SetLength(Result, CallStack.Count);
  for I := 0 to CallStack.Count - 1 do
  begin
    //  For each entry in the call stack, we have up to 7 values now that may
    //  represent the LR register. Most of the time, it will be the first value.
    //  We try to find the correct LR value by passing up to all 7 addresses to
    //  the dladdr API (by calling GetCallStackEntry). If the API call succeeds,
    //  we assume we found the value of LR. However, this is not fool proof
    //  because an address value we pass to dladdr may be a valid code address,
    //  but not the LR value we are looking for.
    //
    //  Also, the LR value contains the address of the next instruction after the
    //  call instruction. Delphi usually uses the BL or BLX instruction to call
    //  another routine. These instructions takes 4 bytes, so LR will be set to 4
    //  bytes after the BL(X) instruction (the return address). However, we want
    //  to know at what address the call was made, so we need to subtract 4
    //  bytes.
    //
    //  There is one final complication here: the lowest bit of the LR register
    //  indicates the mode the CPU operates in (ARM or Thumb). We need to clear
    //  this bit to get to the actual address, by AND'ing it with "not 1".
    //
    //  ------------------------------------------------------------------------
    //  Для каждой записи в стеке вызовов у нас теперь есть до 7 значений,
    //  которые могут представлять регистр LR. Чаще всего это будет первое значение.
    //  Мы пытаемся найти правильное значение LR, передавая все 7 адресов
    //  API dladdr (вызывая GetCallStackEntry). Если вызов API прошел успешно,
    //  мы считаем, что нашли значение LR. Однако это не является надежным
    //  решением, поскольку значение адреса, которое мы передаем dladdr,
    //  может быть действительным адресом кода, но не значением LR, которое мы ищем.
    //
    //  Кроме того, значение LR содержит адрес следующей инструкции после
    //  инструкции вызова. Delphi обычно использует инструкцию BL или BLX
    //  для вызова другой программы. Эти инструкции занимают 4 байта,
    //  поэтому значение LR будет установлено в 4 байта после инструкции
    //  BL(X) (адрес возврата). Однако мы хотим знать, по какому адресу
    //  был сделан вызов, поэтому нам нужно вычесть 4 байта.
    //
    //  Здесь есть одно последнее осложнение: младший бит регистра LR
    //  указывает на режим работы процессора (ARM или Thumb). Чтобы узнать
    //  фактический адрес, нам нужно очистить этот бит, сделать AND на NOT 1.


    FoundLR := False;
    for J := 0 to Length(CallStack.Stack[I]) - 1 do
    begin
      var Ptr : UIntPtr := CallStack.Stack[I, J];
      Ptr := (Ptr and not 1);
      if Ptr > 4 then
      begin
        Ptr := Ptr - 4;
        Result[I].CodeAddress := Ptr;
        if GetCallStackEntry(Result[I]) then
        begin
          // Assume we found LR
          // Предположим, что мы нашли LR

          FoundLR := True;
          Break;
        end;
      end;
    end;

    if (not FoundLR) then
    begin
      // None of the 7 values were valid.
      // Set CodeAddress to 0 to signal we couldn't find LR.
      //
      // None of the 7 values were valid.
      // Установить CodeAddress в 0, чтобы сообщить, что мы не смогли найти LR.
      Result[I].CodeAddress := 0;
      // регистры вместо имени функции; могут оказаться полезными
      Result[I].RoutineName :=
        Format(
          '$%.8X $%.8X $%.8X $%.8X $%.8X $%.8X $%.8X',
          [
            CallStack.Stack[I, 0],
            CallStack.Stack[I, 1],
            CallStack.Stack[I, 2],
            CallStack.Stack[I, 3],
            CallStack.Stack[I, 4],
            CallStack.Stack[I, 5],
            CallStack.Stack[I, 6]
          ]
        );
    end;
  end;
end;

{$ELSE}

(*****************************************************************************)
(*** Non iOS/Android *********************************************************)
(*****************************************************************************)

class function TgoExceptionReporter.GlobalGetExceptionStackInfo(
  P: PExceptionRecord): Pointer;
begin
  // Call stacks are only supported on iOS, Android and macOS
  // Стеки вызовов поддерживаются только на iOS, Android и macOS

  Result := nil;
end;

class function TgoExceptionReporter.GetCallStack(
  const AStackInfo: Pointer): TgoCallStack;
begin
  // Call stacks are only supported on iOS, Android and macOS
  // Стеки вызовов поддерживаются только на iOS, Android и macOS

  Result := nil;
end;

class function TgoExceptionReporter.GetCallStackEntry(
  var AEntry: TgoCallStackEntry): Boolean;
begin
  // Call stacks are only supported on iOS, Android and macOS
  // Стеки вызовов поддерживаются только на iOS, Android и macOS

  Result := False;
end;

{$ENDIF}

{$IF Defined(MACOS) or Defined(ANDROID)}
class function TgoExceptionReporter.GetCallStackEntry(
  var AEntry: TgoCallStackEntry): Boolean;
var
  Info: dl_info;
  Status: Integer;
  Demangled: MarshaledAString;
begin
  Result := (dladdr(AEntry.CodeAddress, Info) <> 0) and (Info.dli_saddr <> nil);
  if (Result) then
  begin
    AEntry.RoutineAddress := UIntPtr(Info.dli_saddr);
    AEntry.ModuleAddress := UIntPtr(Info.dli_fbase);

    Demangled := cxa_demangle(Info.dli_sname, nil, 0, Status);
    if (Demangled = nil) then
      AEntry.RoutineName := String(Info.dli_sname)
    else
    begin
      AEntry.RoutineName := String(Demangled);
      Posix.Stdlib.free(Demangled);
    end;

    AEntry.ModuleName := String(Info.dli_fname);
    {$IF Defined(MACOS64) and not Defined(IOS)}
    AEntry.LineNumber := GetLineNumber(AEntry.CodeAddress);
    {$ELSE}
    AEntry.LineNumber := 0;
    {$ENDIF}
  end;
end;
{$ENDIF}

initialization
  TgoExceptionReporter.FInstance := TgoExceptionReporter.InternalCreate;

finalization
  FreeAndNil(TgoExceptionReporter.FInstance);
  FreeAndNil(IgnoredExceptions);

{$ENDIF} // SiDebugMobile - не работает, глобально выключен до завершения экспериментов

end.

