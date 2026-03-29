unit SiExceptReport;

{$IF DEFINED(MarketERP) or DEFINED(MarketCRMX) or DEFINED(AWM) or DEFINED(WMSLiteDashboard)}
{$DEFINE SiMainFmx}
{$ENDIF}
interface

uses

  {$IF DEFINED(SiMainFMX) or DEFINED(SiMainVCL)}
  {$IFDEF SiMainFMX}
  {$MESSAGE HINT 'Подключена версия модуля SiExceptReport для FMX графики}
  FMX.Graphics,
  {$ENDIF}
  {$IFDEF SiMainVCl}
  {$MESSAGE HINT 'Подключена версия модуля SiExceptReport для VCL графики}
  Vcl.Graphics,
  {$ENDIF}
  {$ELSE}
  {$MESSAGE HINT 'Подключена версия модуля SiExceptReport для консольных сервисов}
  {$ENDIF}

  System.SysUtils,
  FireDAC.Comp.Client,
  SmartInspect;

var
  ExceptReportAppStartTime : TDateTime;
  ExceptReportApplication : string;
  ExceptReportApplicationName : string;
  ExceptReportApplicationVersion : string;
  ExceptReportApplicationBuildTime : TDateTime;

function ExceptReportCreate(Sender: TObject; E: Exception; const ReportHashTag : string) : string;
function ExceptHashTag : string;
function ExceptReportHashTag : string;
procedure ExceptReportTest; deprecated 'ExceptReportTest - использтовать только для модульного теста'

{$IF DEFINED(SiMainFMX) or DEFINED(SiMainVCL)}
procedure ExceptReportCaptureCanvasInformation(ACanvas : TCanvas);
{$ENDIF}
procedure LogMemoryHeapStatus;

/// <summary>
///   Возвращает стандартное описание ошибки (исключения), возникшей при попытке окрытия набора данных
///  (представленного запросом или хранимой процедурой)
/// </summary>
function GetStdErrorDescription(const ErrorClass, ErrorMessage: string; DataSet: TFDRdbmsDataSet; AStatement: string = string.Empty): string;
function GetFDDataSetParamsInfo(ADataSet: TFDRdbmsDataSet): string;
function GetFDDataSetMacrosInfo(ADataSet: TFDRdbmsDataSet): string;
function GetCompresedStringSQL(const AText: string; addSquareSides : boolean = True): string;

function GetErrorReportInfo: String;
function GetStatement(DataSet: TFDRdbmsDataSet): String;
function GetFDDataBaseInfo(ADataSet : TFDRdbmsDataSet): String;

// записывает в предоставленную сессию краткую информацию о наборе данных
// (Query, StoredProc) и значениях его параметров (для табличных - только кол-во строк)
procedure LogDataSet(SiSession: TSiSession; DataSet: TFdRdbmsDataSet);

function GetStackTraceInfo: String;
function GetMemoryAllocated: Int64;
procedure SilentExceptionSecurityLog(ErrorTag: String; E: Exception);
function WinFileVersion(const FileName: String): String;
/// <summary>
///   Возвращает текст исключения, с учетом вложенных исключений
/// </summary>
function GetExceptionMessage(E: Exception): string;

// Функция возвращает строку имени приложения для использования в параметре Application Name строки подключения к БД.
// Имя формируется на основе названия приложения, цифр его версии и текущего PID процесса.
// Это позволяет администратору БД (DBA) при анализе соединений и ошибок быстро определить,
// какая именно версия приложения и какой экземпляр (по PID) установил соединение с БД.
function GetApplicationNameForSqlConnection: string;

implementation

uses
  SiAuto,
  System.Classes,
  System.DateUtils,
  System.Threading,
  System.StrUtils,
  Winapi.Windows,

  {$IFDEF SiMainFMX}
  FMX.Forms, FMX.Canvas.D2D,
  {$ENDIF}

  {$IFDEF SiMainVCL}
  VCL.Forms, Vcl.Direct2D,
  {$ENDIF}

  {$IF DEFINED(MarketERP) or DEFINED(MarketCRMX) or DEFINED(AWM) or DEFINED(WMSLiteDashboard)}
  UDmBaseConnect,
  {$ENDIF}
  System.ZLib,
  System.Variants,

  Data.DB,
  FireDAC.Stan.Param,
  FireDAC.Stan.Error,
  JclBase,
  JclFileUtils,
  JclHookExcept,
  JclPeImage,
  JclStrings,
  JclSysInfo,
  JclWin32,
  JclDebug;

{$WARN SYMBOL_PLATFORM OFF}

function ExceptHashTag : string;
begin
  Result := '#' + TGuid.NewGuid.ToString.GetHashCode.ToHexString;
end;

var
  // Разрешить запись в БД не более 5 хэштэгов шибки в 5 минут
  HashTagUnlockTime : TDateTime = 0;
  HashTagCountLimit : Integer = 5;

function ExceptReportHashTag : string;
begin
  Result := '';

  // разрешить снова 5 штук после пяти минут
  if (HashTagCountLimit <= 0) and (HashTagUnlockTime < Now) then
    HashTagCountLimit := 5;

  if HashTagCountLimit > 0 then
  begin
    Result := ExceptHashTag;
    InterlockedDecrement(HashTagCountLimit);

    // заморозить счетчик на 5 минут
    if HashTagCountLimit = 0 then
      HashTagUnlockTime := Now + 5/MinsPerDay;
  end;
end;

var
  AppCanvasInfo : string = 'Error Null Canvas';

const
  RsReportHashTag       = 'Report Hash Tag    : %s';
  RsReportCreation      = 'Report creation    : %s';
  RsAppStartTime        = 'Start time         : %s';
  RsApplication         = 'Application        : %s';
  RsApplicationName     = 'Application name   : %s';
  RsApplicationVersion  = 'Application version: %s';
  RsAllocatedMemory     = 'Allocated memory   : %d MB';
  RsExceptionClass      = 'Exception class    : %s';
  RsExceptionMessage    = 'Exception message  : %s';
  RsFullExceptionMessage= 'Detail exception message:';
  RsExceptionAddr       = 'Exception address  : %p';
  RsSenderClass         = 'Sender class       : %s';
  RsSenderAddr          = 'Sender address     : %p';
  RsSenderName          = 'Sender name        : %s';

  RsOSVersion           = 'OS       : %s %s, %s, version: %d.%d, build: %d, "%s"';
  RsComputerName        = 'Computer : %s';
  RsUserName            = 'User     : %s';
  RsProcessor           = 'Processor: %s, %s, %d MHz';
  RsOSMemory            = 'OS memory: Used %d%%, LoadPhys %d%%, AvailPhys %d MB, TotalPhys %d MB, AvailPageFile %d MB, TotalPageFile %d MB';

  {$IFDEF SiMainFMX}
  RsScreenRes           = 'Display  : %g x %g pixels, %d bpp';
  {$ENDIF}
  {$IFDEF SiMainVCL}
  RsScreenRes           = 'Display  : %d x %d pixels, %d bpp';
  {$ENDIF}
  RsCanvasInfo          = 'Canvas   : %s';

  RsExceptionStack      = 'Exception stack:';
  RsExceptionRawStack   = 'Exception raw stack:';
  RsMainThreadID        = 'Main thread ID: %d';
  RsMainThreadCallStack = 'Call stack for main thread:';
  RsThreadCallStack     = 'Call stack for thread %d %s "%s"';

  RsErrorInfoReportTime = 'Report Time: %s';
  RsErrorInfoStartTime  = 'Start Time : %s';
  RsErrorInfoProgram    = 'Program    : %s';
  RsErrorInfoVersion    = 'Version    : %s';
  RsErrorInfoComputer   = 'Computer   : %s';
  RsErrorInfoUserName   = 'User       : %s';

  RsDBInfoDataSet       = 'Dataset    : %s';
  RsDBInfoDatabase      = 'Database   : %s';
  RsDBInfoPooled        = 'Pooled     : %d';

function GetOSLanguage: String;
var
  Language: array [0..255] of Char;
begin
  VerLanguageName(GetSystemDefaultUILanguage, Language, Length(Language));
  Result := String(Language);
end;

function WinFileVersion(const FileName: String): String;
var
  VerInfoSize, VerValueSize, Dummy: Cardinal;
  PVerInfo: Pointer;
  PVerValue: PVSFixedFileInfo;
begin
  Result := '';
  VerInfoSize := GetFileVersionInfoSize(PChar(FileName), Dummy);

  if VerInfoSize > 0 then
  begin
    GetMem(PVerInfo, VerInfoSize);
    try
      if GetFileVersionInfo(PChar(FileName), 0, VerInfoSize, PVerInfo) and
         VerQueryValue(PVerInfo, '\', Pointer(PVerValue), VerValueSize) then
        with PVerValue^ do
          Result := Format('%d.%d.%d.%d',
                           [HiWord(dwFileVersionMS), //Major
                           LoWord(dwFileVersionMS), //Minor
                           HiWord(dwFileVersionLS), //Release
                           LoWord(dwFileVersionLS)]); //Build
    finally
      FreeMem(PVerInfo, VerInfoSize);
    end;
  end;
end;

function ExceptReportCreate(Sender: TObject; E: Exception; const ReportHashTag : string) : string;
var
  List: TStringList;
  SeparatorLong: String;
  // StackList: TJclStackInfoList;
  CpuInfo: TCpuInfo;
begin
  List := TStringList.Create;
  SeparatorLong := StringOfChar('-', 80);

  try
    with List do
    begin
      Add(Format(RsReportHashTag, [ReportHashTag]));
      Add(Format(RsReportCreation, [Now.Format('yyyy-mm-dd hh:nn:ss')]));
      Add(Format(RsAppStartTime, [ExceptReportAppStartTime.Format('yyyy-mm-dd hh:nn:ss')]));
      Add(Format(RsApplication, [ExceptReportApplication]));
      Add(Format(RsApplicationName, [ExceptReportApplicationName]));
      Add(Format(RsApplicationVersion, [ExceptReportApplicationVersion]));

      var AllocatedMemory := GetMemoryAllocated;
      Add(Format(RsAllocatedMemory, [AllocatedMemory shr 20]));

      if Assigned(E) then
      begin
        Add(Format(RsExceptionClass, [E.ClassName]));
        Add(Format(RsExceptionMessage, [StringReplace(E.Message, #13#10, ' ', [rfReplaceAll])]));
        Add(Format(RsExceptionAddr, [ExceptAddr]));
      end;

      if Assigned(Sender) then
      begin
        if Sender is TComponent then
          Add(Format(RsSenderName, [TComponent(Sender).Name]));

        Add(Format(RsSenderClass, [Sender.ClassName]));
        Add(Format(RsSenderAddr, [Pointer(Sender)]));
      end;

      Add(SeparatorLong);

      // Если имеются вложенные исключения - выводим их
      if Assigned(E) and Assigned(E.InnerException) then
      begin
        Add(RsFullExceptionMessage);
        Add(GetExceptionMessage(E));
        Add(SeparatorLong);
      end;

      // System and OS information

      Add(Format(RsComputerName, [GetLocalComputerName]));
      Add(Format(RsUserName, [GetLocalUserName]));

      Add(Format(RsOSVersion, [GetWindowsVersionString, NtProductTypeString, GetOSLanguage, Win32MajorVersion, Win32MinorVersion, Win32BuildNumber, Win32CSDVersion]));

      GetCpuInfo(CpuInfo);
      Add(Format(RsProcessor, [CpuInfo.Manufacturer, Trim(String(CpuInfo.CpuName)), RoundFrequency(CpuInfo.FrequencyInfo.NormFreq)]));

      var Memory: TMemoryStatusEx := Default(TMemoryStatusEx);
      Memory.dwLength := SizeOf(TMemoryStatusEx);

      if GlobalMemoryStatusEx(Memory) and ((Memory.ullTotalPhys + Memory.ullTotalPageFile) > 0) then
      begin
        // https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/ns-sysinfoapi-memorystatusex
        var MemoryUsed: Int64 := 100 - ((100 * (Memory.ullAvailPhys + Memory.ullAvailPageFile)) div (Memory.ullTotalPhys + Memory.ullTotalPageFile));
        Add(Format(RsOsMemory, [MemoryUsed, Memory.dwMemoryLoad, Memory.ullAvailPhys shr 20, Memory.ullTotalPhys shr 20, Memory.ullAvailPageFile shr 20, Memory.ullTotalPageFile shr 20]));
      end;

      {$IF DEFINED(SiMainFMX) or DEFINED(SiMainVCL)}
      Add(Format(RsScreenRes, [Screen.Width, Screen.Height, GetBPP]));
      Add(Format(RsCanvasInfo, [AppCanvasInfo]));
      {$ENDIF}

      if Assigned(E) then
      begin
        if E is EFDDBEngineException then
        begin
          // Телеметрия для типа исключения EFDDBEngineException полезно расшифровывать SQL
          var EFDDB := (E as EFDDBEngineException);

          Add(SeparatorLong);
          Add('SQL ObjName=' + EFDDB.FDObjName);
          Add('SQL ErrorCode=' + EFDDB.ErrorCode.ToString);
          Add('SQL Query:');
          Add(EFDDB.SQL);
          Add('SQL Params:');
          Add(EFDDB.Params.Text);
        end;

        Add(SeparatorLong);

        if stRawMode in JclStackTrackingOptions then
          Add(RsExceptionRawStack)
        else
          Add(RsExceptionStack);

        Add(E.StackTrace);
      end;
    end;

  finally
    Result := List.Text;
    List.Free;
  end;
end;

procedure ExceptReportTest;
begin
  {
  TTask.Run(procedure
  begin
    Sleep(Random(3000));
    StrToFloat('Тест исключения в TTask 1');
  end);

  TTask.Run(procedure
  begin
    Sleep(Random(3000));
    StrToFloat('Тест исключения в TTask 2');
  end);

  TTask.Run(procedure
  begin
    Sleep(Random(3000));
    StrToFloat('Тест исключения в TTask 3');
  end);
  }

  {
  TThread.CreateAnonymousThread(procedure
  begin
    Sleep(Random(10000));
    StrToFloat('Тест исключения в TThread 1');
  end);

  TThread.CreateAnonymousThread(procedure
  begin
    Sleep(Random(10000));
    StrToFloat('Тест исключения в TThread 2');
  end);

  TThread.CreateAnonymousThread(procedure
  begin
    Sleep(Random(10000));
    StrToFloat('Тест исключения в TThread 3');
  end);
  }

  StrToFloat('Тест исключения в основном потоке');
end;

{$IF DEFINED(SiMainFMX) or DEFINED(SiMainVCL)}
procedure ExceptReportCaptureCanvasInformation(ACanvas : TCanvas);
begin
  if Assigned(ACanvas) then
  begin
    AppCanvasInfo := ACanvas.ClassName;

    {$IFDEF SiMainFMX}
    if ACanvas is TCustomCanvasD2D then
    begin
      // Дополнителная информация для протокола, важна для исследования
      // ошибок выделения графических ресурсов при (Hardware) варианте
      AppCanvasInfo := AppCanvasInfo + IfThen((ACanvas as TCustomCanvasD2D).Direct3DHardware, ' (Hardware)', ' (Software)');
    end
    else
    begin
      // При использовании движка TCanvasGdiPlus в TTextLayoutGDIPlus.Create
      // FMX жестко и фатально реагирует на некорректные принтеры
      // PrinterRecondition.DiagnosisTerminate := true;
    end;
    {$ENDIF}
  end;
end;
{$ENDIF}

function GetMemoryAllocated: Int64;
var
  st: TMemoryManagerState;
  sb: TSmallBlockTypeState;
begin
  GetMemoryManagerState(st);

  Result := st.TotalAllocatedMediumBlockSize + st.TotalAllocatedLargeBlockSize;

  for sb in st.SmallBlockTypeStates do
  begin
    Result := Result + Int64(sb.UseableBlockSize * sb.AllocatedBlockCount);
  end;
end;

procedure LogMemoryHeapStatus;
begin
  {$IFDEF SiDebug}
  SiMain.LogValue('MemoryAllocated', GetMemoryAllocated);

  Var HeapStatus := GetHeapStatus;
  SiMain.LogValue('HeapStatus.TotalAddrSpace', HeapStatus.TotalAddrSpace);
  SiMain.LogValue('HeapStatus.TotalUncommitted', HeapStatus.TotalUncommitted);
  SiMain.LogValue('HeapStatus.TotalCommitted', HeapStatus.TotalCommitted);
  SiMain.LogValue('HeapStatus.TotalAllocated', HeapStatus.TotalAllocated);
  SiMain.LogValue('HeapStatus.TotalFree', HeapStatus.TotalFree);
  SiMain.LogValue('HeapStatus.FreeSmall', HeapStatus.FreeSmall);
  SiMain.LogValue('HeapStatus.FreeBig', HeapStatus.FreeBig);
  SiMain.LogValue('HeapStatus.Unused', HeapStatus.Unused);
  SiMain.LogValue('HeapStatus.Overhead', HeapStatus.Overhead);

  {
    TotalAddrSpace - (Текущее) общее адресное пространство, доступное вашей программе,
    в байтах. Это значение будет увеличиваться по мере роста использования
    динамической памяти вашей программой.

    TotalUncommitted - Общее количество байт (из TotalAddrSpace), для которых
    не было выделено место в файле подкачки.
    TotalCommitted - Общее количество байт (из TotalAddrSpace), для которых
    было выделено место в файле подкачки.
    Примечание: TotalUncommitted + TotalCommitted = TotalAddrSpace
    TotalAllocated -  Общее количество байт, динамически выделенных вашей программой.
    TotalFree - Общее количество свободных байт, доступных в (текущем)
    адресном пространстве для выделения вашей программой.
    Если это число превышено, и доступно достаточно виртуальной памяти,
    из ОС будет выделено больше адресного пространства;
    TotalAddrSpace будет соответственно увеличено.
    FreeSmall - Общее количество байт небольших блоков памяти,
    которые в данный момент не выделены вашей программой.
    FreeBig - Общее количество байт больших блоков памяти,
    которые в данный момент не выделены вашей программой.
    Большие свободные блоки могут быть созданы путем объединения меньших,
    смежных, свободных блоков или путем освобождения большого
    динамического выделения. (Точный размер блоков несущественен).
    Unused - Общее количество байтов, которые никогда не были выделены вашей программой.
    Примечание: Unused + FreeBig + FreeSmall = TotalFree.
    Эти три поля (Unused, FreeBig и FreeSmall) относятся к
    динамическому выделению программой пользователя.
    Overhead - Общее количество байт, необходимое менеджеру кучи
    для управления всеми блоками, динамически выделяемыми вашей программой.
    HeapErrorCode - Указывает текущее состояние кучи, определяемое внутренними средствами.
    Примечание: TotalAddrSpace, TotalUncommitted и TotalCommitted относятся
    к памяти ОС, используемой программой, в то время
    как TotalAllocated и TotalFree относятся к памяти кучи,
    используемой в программе динамическими выделениями.
    Поэтому для мониторинга динамической памяти, используемой в вашей
    программе, используйте TotalAllocated и TotalFree.
  }
  {$ENDIF}
end;

procedure SilentExceptionSecurityLog(ErrorTag: String; E: Exception);
begin
  // Простой обработчик для тихой ловушки исключений, без выдачи
  // сообщений пользователю. Диагностика записывается только
  // для перечисленных в $IF DEFINED программ, только тем способом
  // способом, который для этих программ является приемлемым.
  // В будущем, при расширении списка программ, подход к этой
  // телеметрии может измениться.

  {$IF DEFINED(MarketERP) or DEFINED(MarketCRMX) or DEFINED(AWM) or DEFINED(WMSLiteDashboard)}
  if DMBaseConnect.SQLConnectionServerSecurity.Connected then
    ExceptReportSecurityLog(ErrorTag, E.Message, ExceptReportCreate(nil, E, 'SilentOnException'));
  {$ENDIF}

  {$IF DEFINED(TASKENGINE) or DEFINED(WMSLiteDashboard)}
  SiDevOps.LogCustomText(
    TSiLevel.lvError,
    ErrorTag,
    ExceptReportCreate(nil, E, 'SilentOnException'),
    TSiLogEntryType.ltError, TSiViewerId.viData);
  {$ENDIF}
end;

function GetStdErrorDescription(const ErrorClass, ErrorMessage: string; DataSet: TFDRdbmsDataSet; AStatement: string = string.Empty): string;
begin
  if Assigned(DataSet) then
  begin
    if AStatement.IsEmpty then
      AStatement := GetStatement(DataSet);

    Exit(
      GetErrorReportInfo + sLineBreak +
      GetFDDataBaseInfo(DataSet) + sLineBreak + sLineBreak +
      ErrorClass + ' ' + ErrorMessage + sLineBreak + sLineBreak +
      AStatement + sLineBreak +
      GetFDDataSetParamsInfo(DataSet) + sLineBreak +
      GetFDDataSetMacrosInfo(DataSet) + sLineBreak +
      GetStackTraceInfo
    );
  end
  else
    Exit(
      GetErrorReportInfo + sLineBreak +
      ErrorMessage + sLineBreak + sLineBreak +
      GetStackTraceInfo
    );
end;

function GetStatement(DataSet: TFDRdbmsDataSet): String;
begin
  if (DataSet is TFdQuery) then
    Exit((DataSet as TFdQuery).SQL.Text)
  else if (DataSet is TFdStoredProc) then
  begin
    var Command := (DataSet as TFdStoredProc).Command;
    if Assigned(Command) and not Command.SqlText.IsEmpty then
    begin
      result := 'exec ' + (DataSet as TFdStoredProc).StoredProcName;
      var LineParams := String.Empty;
      for var i := 0 to Command.Params.Count - 1 do
      begin
        if Command.Params[i].SQLName = '@RETURN_VALUE' then
           continue;
        LineParams := LineParams + ifthen(LineParams.isEmpty, ' ', ', ') + Command.Params[i].SQLName;
      end;
      Exit(result + LineParams);
    end
    else
      Exit('Хранимая процедура "' + (DataSet as TFdStoredProc).StoredProcName + '"');
  end;
end;

function GetStackTraceInfo: String;
begin
  var StackInfoList: TJclStackInfoList := JclCreateStackList(True, 1, nil);
  var StackInfo : TStringList := TStringList.Create;
  try
    StackInfoList.AddToStrings(StackInfo, True, True, True);
    Result := 'Содержимое стека:'#13#19 + StackInfo.Text;
  finally
    StackInfoList.Free;
    StackInfo.Free;
  end;
end;

function GetErrorReportInfo: String;
begin
  Result := string.Join(#13#10,
  [
    Format(RsErrorInfoReportTime, [Now.Format('yyyy-mm-dd hh:nn:ss')]),
    Format(RsErrorInfoStartTime, [ExceptReportAppStartTime.Format('yyyy-mm-dd hh:nn:ss')]),
    Format(RsErrorInfoProgram, [ExceptReportApplication]),
    Format(RsErrorInfoVersion, [ExceptReportApplicationVersion]),
    Format(RsErrorInfoComputer, [GetLocalComputerName]),
    Format(RsErrorInfoUserName, [GetLocalUserName])
  ]);
end;

function GetFDDataBaseInfo(ADataSet : TFDRdbmsDataSet): String;
begin
  if ADataSet <> Nil then
  begin
    if ADataSet.Connection <> nil then
    begin
      if not ADataSet.Connection.ConnectionDefName.IsEmpty then
        Result := Format(RsDBInfoDatabase, [ADataSet.Connection.ConnectionDefName])
      else if not ADataSet.Connection.ConnectionName.IsEmpty then
      begin
        Result := Format(RsDBInfoDatabase, [ADataSet.Connection.ConnectionName]) + ', ' +
                  Format(RsDBInfoPooled, [ADataSet.Connection.Params.Pooled.ToInteger]);
      end
     else

        Result := Format(RsDBInfoDatabase, [ADataSet.Connection.Params.Values['Server']])
    end
    else
      Result := Format(RsDBInfoDatabase, ['nil']);

    if ADataSet.Name <> '' then
      Result := Result + #13#10 + Format(RsDBInfoDataSet, [ADataSet.Name]);
  end;
end;

procedure LogDataSet(SiSession: TSiSession; DataSet: TFdRdbmsDataSet);
begin
  var SB := TStringBuilder.Create;
  try
    for var P := 0 to DataSet.Params.Count - 1 do
    begin
      var Param := TFdParam(DataSet.Params[P]);
      if Param.Bound then
      begin
        SB.Append(Param.Name);
        if Param.IsNull then
          SB.Append('=null')
        else
          if Param.IsDataSet then
          begin
            var DataTypeName := Param.DataTypeName;
            SB.Append(': <');
            if DataTypeName.IsEmpty then
              SB.Append('dataset')
            else
              SB.Append(DataTypeName);

            SB.Append('>[');

            var DS := Param.AsDataSet;
            if Assigned(DS) then
              SB.Append(DS.RecordCount)
            else
              SB.Append('?');
            SB.Append(']')
          end
          else
            SB.Append('=').Append(VarToStr(Param.Value).QuotedString);
        SB.AppendLine;
      end;
    end;

    SiSession.LogText(DataSet.Command.SqlText, SB.ToString);
  finally
    SB.Free;
  end;
end;

function GetCompresedStringSQL(const AText: string; addSquareSides : boolean = True): string;
  function CompressString(const AText: string): TBytes;
  var
    strInput,
    strOutput: TStringStream;
    Zipper: TZCompressionStream;
  begin
    strInput:= TStringStream.Create(AText);
    strOutput:= TStringStream.Create;
    try
      Zipper:= TZCompressionStream.Create(strOutput, zcDefault, 15 + 16);
      try
        Zipper.CopyFrom(strInput, strInput.Size);
      finally
        Zipper.Free;
      end;

      Result := strOutput.Bytes;
      SetLength(Result, strOutput.Size);
      Result[8] := $04;
      Result[9] := $00;
    finally
      strInput.Free;
      strOutput.Free;
    end;
  end;

begin
  var Bytes :=  CompressString(ifthen(addSquareSides, '[' + AText + ']', AText));
  var S := string.Empty;
  S := '0x';  //Начало
  for var B in Bytes do
    S := S + B.ToHexString;
  Result := S;
end;

function GetFDDataSetParamsInfo(ADataSet: TFDRdbmsDataSet): string;
const
  cBlobTypes = [ftBlob, ftMemo, ftFmtMemo, ftWideMemo];
  cValidTypes = [ftUnknown, ftString, ftSmallint, ftInteger, ftWord, ftBoolean, ftFloat,
    ftCurrency, ftBCD, ftDate, ftTime, ftDateTime, ftBytes, ftVarBytes, ftAutoInc,
    ftLargeint, ftVariant, ftTimeStamp, ftFMTBcd, ftFixedWideChar, ftLongWord,
    ftShortint, ftByte, ftExtended, ftSingle];

  function GetParamValue(Param: TFDParam): string;
  begin
    if Param.IsNull then
      Result := 'null'
    else if Param.DataType in cBlobTypes then
      Result := '[blob]'
    else if Param.DataType in [ftDataSet] then
    begin
      var DataSet := Param.AsDataSet;
      var ListFields := String.Empty;
      for var i := 0 to DataSet.Fields.Count - 1 do
      begin
        if i = 0 then
          ListFields := DataSet.Fields[i].DisplayName
        else
          ListFields := ListFields + ', ' + DataSet.Fields[i].DisplayName;
      end;

      DataSet.First;
      var SQLScript := String.Empty;
      while not DataSet.eof do
      begin
        var SQLScriptOneRec : String := '(';
        for var i := 0 to DataSet.Fields.Count - 1 do
        begin
          if i > 0 then
            SQLScriptOneRec := SQLScriptOneRec + ', ';
          if DataSet.Fields[i].IsNull then
          begin
            SQLScriptOneRec := SQLScriptOneRec + 'null';
            continue;
          end;
          // пока по простому решил сделать, чтобы хотябы генерировались заготовки
          case DataSet.Fields[i].DataType of
          ftSmallint, ftInteger, ftWord :
            SQLScriptOneRec := SQLScriptOneRec + DataSet.Fields[i].AsString;
          ftFloat, ftCurrency, ftBCD :
            SQLScriptOneRec := SQLScriptOneRec + DataSet.Fields[i].AsString.Replace(',', '.');
          else
            SQLScriptOneRec := SQLScriptOneRec + DataSet.Fields[i].AsString.QuotedString;
          end;
        end;
        SQLScriptOneRec := SQLScriptOneRec + ')';
        SQLScript := SQLScript + ifthen(SQLScript.IsEmpty, '', ',') + SQLScriptOneRec;
        DataSet.next;
      end;


      SQLScript := String.Join(sLineBreak, [
        'select ' + ListFields,
        'from (values ',
        SQLScript,
        ') t (' + ListFields + ')'
       ]);
      // обрезаем имя БД так как Firedac добавляет его. а mssql ругается если запускать в Studia
      result := String.Join(sLineBreak, [
        'declare @Sql nvarchar(max) = cast(decompress(' + GetCompresedStringSQL(SQLScript, False) + ') as Varchar(max))',
        'declare ' + Param.Name + ' ' + UpperCase(Param.DataTypeName).Replace(UpperCase(ADataSet.Connection.CurrentCatalog) + '.', String.Empty),
        'insert into ' + Param.Name,
        '--EXECUTE sp_executesql @Sql -- раскоментаривать только когда доверяешь содержимому @Sql'
        ]);
      // сжимаем, чтобы влезло в телеметрию
      result := Result;
    end
    else if Param.DataType in cValidTypes then
    begin
      try
        Result := Param.AsString;
      except
        Result := '[conversion error]'
      end;
    end
    else
      Result := '[unsupported]';
  end;
begin
  Result := string.Empty;
  if not Assigned(ADataSet) or (ADataSet.Params.Count = 0) then
    Exit;
  var sb := TStringBuilder.Create;
  try
    sb.Append('Параметры:');
    for var I := 0 to ADataSet.Params.Count - 1 do
    begin
      var Param := ADataSet.Params[I];
      sb.Append(sLineBreak);

      if Param.ArrayType = atScalar then
        sb.Append(Param.Name + ': ' + GetParamValue(Param))
      else
        sb.Append(Param.Name + ': [array]');
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function GetFDDataSetMacrosInfo(ADataSet: TFDRdbmsDataSet): string;
begin
  Result := string.Empty;
  if (not Assigned(ADataSet)) or (not (ADataSet is TFDQuery)) then
    Exit;

  var ADataSetQuery := ADataSet as TFDQuery;
  if not Assigned(ADataSetQuery) or (ADataSetQuery.Macros.Count = 0) then
    Exit;
  var sb := TStringBuilder.Create;
  try
    sb.Append('Макросы:');
    for var I := 0 to ADataSetQuery.Macros.Count - 1 do
    begin
      var Macros := ADataSetQuery.Macros[I];
      sb.Append(sLineBreak);
      sb.Append(Macros.Name + ': ' + Macros.AsString);
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

/// <summary>
///   Возвращает текст исключения, с учетом вложенных исключений
/// </summary>
function GetExceptionMessage(E: Exception): string;
begin
  Result := E.Message;

  var InnerExc := E.InnerException;
  var Counter: Integer := 0;

  while Assigned(InnerExc) do
  begin
    Inc(Counter);
    Result := Result + #13#10 + '#' + Counter.ToString + ': ' + StringReplace(InnerExc.Message, #13#10, ' ', [rfReplaceAll]);

    InnerExc := InnerExc.InnerException;
  end;
end;

function GetApplicationNameForSqlConnection: string;
begin
  Result := Format('%s_%s_%d_%s', [ExceptReportApplicationName, ExceptReportApplicationVersion, GetCurrentProcessID, GetLocalUserName]);
end;

// =========================================================================
// Теоретическая основа для анализа массовой ошибки
// Exception class: EOSError "System Error.  Code: 8. Недостаточно памяти для обработки команды"
// Возможно это снова про утечку (GlobalAddAtom).
// Вероятная причина исчерпание таблицы атомов. Может быть это все еще актуально для FMX Delphi 11
// Проработать информацию из следующих источников
//   https://habr.com/ru/post/217189/
//   https://github.com/JordiCorbilla/atom-table-monitor
//   https://docs.microsoft.com/ru-ru/windows/win32/dataxchg/about-atom-tables?redirectedfrom=MSDN
//   https://stackoverflow.com/questions/507853/system-error-code-8-not-enough-storage-is-available-to-process-this-command/9066509#9066509
//   https://docs.microsoft.com/en-us/archive/blogs/ntdebugging/identifying-global-atom-table-leaks
// Выяснилось следующее:
// Для VCL всегда текут:
//   WindowAtomString := Format('Delphi%.8X',[GetCurrentProcessID]);
//   ControlAtomString := Format('ControlOfs%.8X%.8X', [HInstance, GetCurrentThreadID]);
//     в Vcl.Controls.pas
//   StrFmt(AtomText,'WndProcPtr%.8X%.8X', [HInstance, GetCurrentThreadID])
//     в Vcl.Dialogs.pas
// Для FMX текут при крахе:
//   WindowAtomString := Format('FIREMONKEY%.8X', [GetCurrentProcessID]);
//     в FMX.Platform.Win.pas
//   AtomString := Format('STYLEY%.8X', [GetCurrentProcessID]);
//     в FMX.Presentation.Win.Style.pas
// Максимальное количество атомов 16383. Но пока не понятоно это на одну сессию или на все.
// Решения пока нет - продолжаем наблюдение.
// =========================================================================

initialization
  ExceptReportAppStartTime := Now;
  ExceptReportApplication := ParamStr(0);
  ExceptReportApplicationName := 'MarketApp';
  ExceptReportApplicationVersion := WinFileVersion(ParamStr(0));
  ExceptReportApplicationBuildTime := PeReadLinkerTimeStamp(ParamStr(0)).IncHour(3);

end.

