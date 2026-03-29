unit SlowpokeDetector;

// ѕример активации телеметрии медленных запросов дл€ Market.ini
//
//  [SlowpokeSQL]
//  ; DetectorEnable - јктиваци€ телеметрии дл€ медленных SQL (0 - выключено, 1 - включено)
//  DetectorEnable=1
//
//  ; DurationThreshold - ѕорог продолжительности в секундах дл€ определени€ медленных запросов (по умолчанию 30 секунд)
//  DurationThreshold=2
//
//  ; ExposeLimit -  оличество самых медленных запросов дл€ экспозиции в протокол (по умолчанию 3)
//  ExposeLimit=5

interface

uses
  System.Classes,
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections;

const
  // ѕорог продолжительности в секундах дл€ определени€ медленных запросов (по умолчанию 30 секунд)
  DurationThresholdSecsDefault = 30;

  // ѕериод времени в минутах дл€ периодической промежуточной экспозиции в протокол (в SecurityLog)
  SlowpokeSqlExposeIntervalMin = 60;

  //  оличество самых медленных запросов дл€ экспозиции в протокол (по умолчанию 3)
  SlowpokeSqlExposeLimitDefault = 3;

type
  TSlowpokeSQLMetric = class
  private
    FMaxSqlSample: string;
    FMaxTime: TDateTime;
    FMaxDuration: TDateTime;
    FSumDuration: TDateTime;
    FFirstTime: TDateTime;
    FLastTime: TDateTime;
    FCount: Integer;
    FDatabase: string;
    FHashTag: string;
    FExposed: Boolean;
    function GetAverageDuration: TDateTime;
  public
    property Database: string read FDatabase;
    property MaxSqlSample: string read FMaxSqlSample;
    property MaxTime: TDateTime read FMaxTime;
    property MaxDuration: TDateTime read FMaxDuration;
    property SumDuration: TDateTime read FSumDuration;
    property AverageDuration: TDateTime read GetAverageDuration;
    property FirstTime: TDateTime read FFirstTime;
    property LastTime: TDateTime read FLastTime;
    property Count: Integer read FCount;
    property HashTag: string read FHashTag;
  end;

  TSlowpokeSQLExposeProc = reference to procedure(ANumber: Integer; AMetric :TSlowpokeSQLMetric);

  TSlowpokeSQLDetector = class
  private
    FProfileMREW: TLightweightMREW;
    FProfileDict: TObjectDictionary<string, TSlowpokeSQLMetric>;
    FDurationThreshold: TDateTime;
    FExposeLimit: Integer;
    FEnable: Boolean;

  public
    constructor Create;
    destructor Destroy; override;
    function ReduceSqlKey(const ASQL : string) : string;
    procedure CollectProfile(ADuration : TDateTime; ASQL : string; ADatabase : string);
    procedure ExposeProfile(AExposeProc : TSlowpokeSQLExposeProc);
    procedure SetDurationThresholdSecs(ADurationThresholdSecs : Integer);
    property Enable: Boolean read FEnable write FEnable;
    property DurationThreshold: TDateTime read FDurationThreshold;
    property ExposeLimit: Integer read FExposeLimit write FExposeLimit;
  end;

var
  SlowpokeSQLDetector : TSlowpokeSQLDetector;

implementation

uses
  System.Generics.Defaults;

const
  SpaceChars = [#1..#9, #11, #12, #14..#32];
  IdentChars = ['A'..'Z', 'a'..'z', '0'..'9', ':', '.', '_', '@', '#', '$'];

type
  TSqlParserTokenKind = (
    TokenNone,
    TokenComment1,  // /*Comment1*/
    TokenComment2,  // --Comment2
    TokenStr,       // 'Str'
    TokenName,      // "Name"
    TokenNumber,    // 123.123
    TokenIdent1,    // Name_123  @Name_123 #Name_123
    TokenIdent2,    // [Name 123]
    TokenCommand,   // все операторы
    TokenLineBreak, // #13, #10
    TokenSpace      // #1..#9, #11, #12, #14..#32
  );

  // ќблегченный лексический трансл€тор дл€ SQL-запросов
  // Ќеобходим чтобы получить редуцированную форму запроса
  // Ѕез комментариев и без параметров, переданных литералами
  // “ак похожие запросы будут подсчитыватьс€ в едином профиле
  TSqlParser = class
  private
    FText: string;
    FRunIndex: Integer;
    FTokenPos: Integer;
    FTokenKind : TSqlParserTokenKind;

    function GetTokenText: String;
    function GetTokenLen: Integer;
    function TextChar(AIndex: Integer): Char;
  public
    constructor Create(const AText: String);
    property Text: string read FText;
    property TokenKind: TSqlParserTokenKind read FTokenKind;
    property TokenText: String read GetTokenText;
    property TokenLen: Integer read GetTokenLen;
    procedure Next;
  end;

constructor TSqlParser.Create(const AText: String);
begin
  inherited Create;
  FText := AText;
  FTokenKind := TokenNone;
  FRunIndex := 0;
  Next;
end;

function TSqlParser.GetTokenText: String;
begin
  Result := FText.Substring(FTokenPos, GetTokenLen);
end;

function TSqlParser.GetTokenLen: Integer;
begin
  Result := FRunIndex - FTokenPos;
end;

function TSqlParser.TextChar(AIndex: Integer): Char;
begin
  if (AIndex >= 0) and (AIndex < FText.Length) then
    Result := FText[AIndex+1]
  else
    Result := #0;
end;

procedure TSqlParser.Next;
begin
  FTokenPos := FRunIndex;
  FTokenKind := TokenNone;

  // ѕримитивный лексический разбор SQL

  case TextChar(FRunIndex) of
    #0:
      FTokenKind := TokenNone;

    #10, #13:
      begin
        FTokenKind := TokenLineBreak;
        Inc(FRunIndex);

        while CharInSet(TextChar(FRunIndex), [#13, #10]) do
          Inc(FRunIndex);
      end;

    #1..#9, #11, #12, #14..#32:
      begin
        FTokenKind := TokenSpace;
        Inc(FRunIndex);

        while CharInSet(TextChar(FRunIndex), SpaceChars) do
          Inc(FRunIndex);
      end;

    '[':
      begin
        FTokenKind := TokenIdent2;
        Inc(FRunIndex);

        while not CharInSet(TextChar(FRunIndex), [#0, ']']) do
          Inc(FRunIndex);
      end;

    '/':
      begin
        FTokenKind := TokenCommand;
        Inc(FRunIndex);

        if TextChar(FRunIndex) = '*' then
        begin
          FTokenKind := TokenComment1;
          Inc(FRunIndex);
          var CommentLevel : Integer := 1;

          while (CommentLevel > 0) and (TextChar(FRunIndex) <> #0) do
          begin
            if (TextChar(FRunIndex)='/') and (TextChar(FRunIndex+1)='*') then
            begin
              Inc(CommentLevel);
              Inc(FRunIndex, 2);
            end
            else
            if (TextChar(FRunIndex)='*') and (TextChar(FRunIndex+1)='/') then
            begin
              Dec(CommentLevel);
              Inc(FRunIndex, 2);
            end
            else
              Inc(FRunIndex);
          end;
        end;
      end;

    '-':
      begin
        FTokenKind := TokenCommand;
        Inc(FRunIndex);

        if TextChar(FRunIndex) = '-' then
        begin
          FTokenKind := TokenComment1;
          Inc(FRunIndex);

          while not CharInSet(TextChar(FRunIndex), [#0, #13, #10]) do
            Inc(FRunIndex);
        end;
      end;

    '''':
      begin
        FTokenKind := TokenStr;
        Inc(FRunIndex);

        while TextChar(FRunIndex) <> #0 do
        begin
          if TextChar(FRunIndex)='''' then
          begin
            Inc(FRunIndex);
            if TextChar(FRunIndex)='''' then
              Inc(FRunIndex)
            else
              Break;
          end
          else
            Inc(FRunIndex);
        end
      end;

    '"':
      begin
        FTokenKind := TokenStr;
        Inc(FRunIndex);

        while TextChar(FRunIndex) <> #0 do
        begin
          if TextChar(FRunIndex)='"' then
          begin
            Inc(FRunIndex);
            if TextChar(FRunIndex)='"' then
              Inc(FRunIndex)
            else
              Break;
          end
          else
            Inc(FRunIndex);
        end
      end;

     '0'..'9':
        begin
          FTokenKind := TokenNumber;
          Inc(FRunIndex);

          while CharInSet(TextChar(FRunIndex), ['0'..'9', '.']) do
            Inc(FRunIndex);
        end;

    '@', '#', 'A'..'Z', 'a'..'z', '_':
        begin
          FTokenKind := TokenIdent1;
          Inc(FRunIndex);

          while CharInSet(TextChar(FRunIndex), IdentChars) do
            Inc(FRunIndex);
        end;

  else
    FTokenKind := TokenCommand;
    Inc(FRunIndex);
  end;
end;

function TSlowpokeSQLMetric.GetAverageDuration: TDateTime;
begin
  if FCount > 0 then
    Result := FSumDuration / FCount
  else
    Result := 0;
end;

constructor TSlowpokeSQLDetector.Create;
begin
  SetDurationThresholdSecs(DurationThresholdSecsDefault);
  FEnable := False;
  FProfileDict := TObjectDictionary<string, TSlowpokeSQLMetric>.Create([doOwnsValues]);
  FExposeLimit := SlowpokeSqlExposeLimitDefault;
end;

destructor TSlowpokeSQLDetector.Destroy;
begin
  FProfileDict.Free;
end;

procedure TSlowpokeSQLDetector.SetDurationThresholdSecs(ADurationThresholdSecs: Integer);
begin
  if ADurationThresholdSecs < 0 then
    FDurationThreshold := DurationThresholdSecsDefault / SecsPerDay
  else
    FDurationThreshold := ADurationThresholdSecs / SecsPerDay;
end;

procedure TSlowpokeSQLDetector.CollectProfile(ADuration: TDateTime; ASQL, ADatabase: string);
begin
  if not FEnable then
    Exit;

  // –асчет и накопление метрики записываетс€ в словарь по редуцированному тексту запроса
  var SqlKey := ReduceSqlKey(ASQL).Trim;

  FProfileMREW.BeginWrite;
  try
    var Metric : TSlowpokeSQLMetric;
    if not FProfileDict.TryGetValue(SqlKey, Metric) then
    begin
      Metric := TSlowpokeSQLMetric.Create;
      Metric.FFirstTime := Now;
      Metric.FHashTag := '#' + SqlKey.GetHashCode.ToHexString;
      FProfileDict.Add(SqlKey, Metric);
    end;

    Metric.FLastTime := Now;
    Metric.FSumDuration := Metric.FSumDuration + ADuration;
    Inc(Metric.FCount);

    if Metric.FMaxDuration < ADuration then
    begin
      Metric.FMaxDuration := ADuration;
      Metric.FMaxSqlSample := ASQL;
      Metric.FMaxTime := Now;
      Metric.FDatabase := ADatabase;
    end;

    Metric.FExposed := False;

  finally
    FProfileMREW.EndWrite;
  end;
end;

procedure TSlowpokeSQLDetector.ExposeProfile(AExposeProc : TSlowpokeSQLExposeProc);
begin
  FProfileMREW.BeginWrite;
  try
    var Metrics := FProfileDict.Values.ToArray;

    // ƒл€ экспозиции метрик, сначала идет сортировка в пор€дке убывани€
    // максимальной продолжительности запросов
    // „тобы опубликовать топ-N самых медленных запросов.

    TArray.Sort<TSlowpokeSQLMetric>(Metrics, TComparer<TSlowpokeSQLMetric>.Construct(
    function(const Left, Right: TSlowpokeSQLMetric): Integer
    begin
      if Left.FMaxDuration = Right.FMaxDuration then
        result := 0
      else if Left.FMaxDuration > Right.FMaxDuration then
        result := -1
      else
        result := 1;
    end));

    var i : Integer := 1;
    for var Metric in Metrics do
      if not Metric.FExposed then
      begin
        if i > FExposeLimit then
          break;

        AExposeProc(i, Metric);
        Metric.FExposed := True;

        Inc(i);
      end;

    // ќчистить профиль дл€ независимого измерени€ следующей экспозиции
    FProfileDict.Clear;
  finally
    FProfileMREW.EndWrite;
  end;
end;

function TSlowpokeSQLDetector.ReduceSqlKey(const ASQL: string): string;
begin
  var Parser := TSqlParser.Create(ASQL);
  var SB := TStringBuilder.Create;

  try
    while Parser.TokenKind <> TokenNone do
    begin
      case Parser.TokenKind of
        TokenComment1, TokenComment2, TokenSpace:
          SB.Append(' ');

        TokenLineBreak:
          SB.Append(sLineBreak);

        TokenStr, TokenName, TokenNumber:
          SB.Append('?');

        else
          SB.Append(Parser.TokenText);
      end;
      Parser.Next;
    end;

    Result := SB.ToString;

  finally
    SB.Free;
    Parser.Free;
  end;
end;

initialization
  SlowpokeSQLDetector := TSlowpokeSQLDetector.Create;

finalization
  FreeAndNil(SlowpokeSQLDetector);

end.

