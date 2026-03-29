unit MarketPosCamera.VLCCamera.Grabber;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  FMX.Graphics,
  PasLibVlcUnit,
  PasLibVlcClassUnit;

type
  TVlcInitParams = record
    OverrideParams: Boolean;
    DeviceName: string;
    Width: Integer;
    Height: Integer;
    Brightness: Single; // between 0 and 2. Defaults to 1.
    Contrast: Single;   // between 0 and 2. Defaults to 1
    Saturation: Single; // between 0 and 3. Defaults to 1.
    Hue: Integer;       // between 0 and 360. Defaults to 0.
    Sharpness: Single;  // коэффициент резкости
    Exposure: Single;   // коэффициент экспозиции
    // Gamma: Single;   // between 0.01 and 10. Defaults to 1

    class operator Initialize(out Dest: TVlcInitParams);
    function IsEquals(OtherParams: TVlcInitParams): Boolean;
  end;

  TVlcFrameGrabber = class
  private
    FVLC: libvlc_instance_t_ptr;
    FMedia: libvlc_media_t_ptr;
    FPlayer: libvlc_media_player_t_ptr;

    FBuffer: TBytes;

    FActive: Boolean;
    FInitialized: Boolean;

    FParams: TVlcInitParams;
    FBytesPerPixel: Integer;
    FLastFrameTime: TDateTime;

    FVlcLibPath: string;

    class function LockCallback(opaque: Pointer; var planes: Pointer): Pointer; cdecl; static;
    class procedure UnlockCallback(opaque, picture: Pointer; const planes: Pointer); cdecl; static;
    class procedure DisplayCallback(opaque, picture: Pointer); cdecl; static;

    function GetParams: TVlcInitParams;

    procedure InternalRelease;
    function IsInitialized: Boolean;

    procedure ApplyExposureTo(var Buf: TBytes; Factor: Single);
    procedure ApplySharpenTo(var Buf: TBytes; Factor: Single);
  public
    constructor Create(const VlcLibPath: string = string.Empty);
    destructor Destroy; override;

    function GetBufferCopy: TBytes;

    procedure CopyToBitmap(ABitmap: TBitmap);

    procedure Init(const Params: TVlcInitParams);
    procedure Start;
    procedure Stop;


    property Active: Boolean read FActive;
    property Initialized: Boolean read FInitialized;
    property Params: TVlcInitParams read GetParams;
    property LastFrameTime: TDateTime read FLastFrameTime;
  end;

implementation

uses
  System.Math,
  System.UITypes,
  MarketPosCamera.Common;

{ TVlcInitParams }

class operator TVlcInitParams.Initialize(out Dest: TVlcInitParams);
begin
  Dest.OverrideParams := False;
  Dest.DeviceName := '';
  Dest.Width := 640;
  Dest.Height := 480;
  Dest.Brightness := 0.5;
  Dest.Contrast := 1.0;
  Dest.Saturation := 1.0;
  Dest.Hue := 0;
  Dest.Sharpness := 0.0;
  Dest.Exposure := 1.0;
end;

function TVlcInitParams.IsEquals(OtherParams: TVlcInitParams): Boolean;
begin
  Result :=
    (OtherParams.OverrideParams = OverrideParams) and
    (OtherParams.DeviceName = DeviceName) and
    (OtherParams.Width = Width) and
    (OtherParams.Height = Height) and
    (OtherParams.Brightness = Brightness) and
    (OtherParams.Contrast = Contrast) and
    (OtherParams.Saturation = Saturation) and
    (OtherParams.Hue = Hue) and
    (OtherParams.Sharpness = Sharpness) and
    (OtherParams.Exposure = Exposure);
end;

{ TVlcFrameGrabber }

constructor TVlcFrameGrabber.Create(const VlcLibPath: string = '');
begin
  inherited Create;
  FInitialized := False;
  FActive := False;
  FLastFrameTime := 0;
  FBytesPerPixel := 4; // pf32bit;
  FVlcLibPath := VlcLibPath;
end;

destructor TVlcFrameGrabber.Destroy;
begin
  Stop;
  InternalRelease;
  inherited;
end;

procedure TVlcFrameGrabber.InternalRelease;
begin
  if FPlayer <> nil then
  begin
    libvlc_media_player_stop(FPlayer);
    libvlc_media_player_release(FPlayer);
    FPlayer := nil;
  end;

  if FMedia <> nil then
  begin
    libvlc_media_release(FMedia);
    FMedia := nil;
  end;

  if FVLC <> nil then
  begin
    libvlc_release(FVLC);
    FVLC := nil;
  end;

  TMonitor.Enter(Self);
  try
    SetLength(FBuffer, 0);
    FLastFrameTime := 0;
    FInitialized := False;
  finally
    TMonitor.Exit(Self);
  end;
end;

function TVlcFrameGrabber.IsInitialized: Boolean;
begin
  Result := FInitialized and (FVLC <> nil) and (FPlayer <> nil);
end;

procedure TVlcFrameGrabber.Init(const Params: TVlcInitParams);
var
  Source: AnsiString;
begin
  ConsoleWriteMessage('Инициализация граббера...');

  Stop;
  InternalRelease;

  FParams := Params;

  TMonitor.Enter(Self);
  try
    SetLength(FBuffer, FParams.Width * FParams.Height * FBytesPerPixel);
  finally
    TMonitor.Exit(Self);
  end;

  // Инициализация DLL VLC при необходимости
  if not FVlcLibPath.IsEmpty then
  begin
    libvlc_dynamic_dll_init_with_path(FVlcLibPath);
    if libvlc_dynamic_dll_error <> '' then
      raise Exception.Create('Ошибка инициализации VLC: ' + libvlc_dynamic_dll_error);
  end;

  // Создание инстанса VLC
  with TArgcArgs.Create([
    libvlc_dynamic_dll_path,
    '--no-audio',
    '--drop-late-frames',
    '--intf=dummy',
    '--ignore-config',
    '--quiet',
    '--no-video-title-show',
    '--no-video-on-top']) do
  try
    FVLC := libvlc_new(ARGC, ARGS);
  finally
    Free;
  end;

  if FVLC = nil then
    raise Exception.Create('Ошибка создания экземпляра VLC');

  // Источник видео
  if FParams.DeviceName = '' then
    Source := 'dshow://'
  else
    Source := 'dshow://:dshow-vdev="' + AnsiString(FParams.DeviceName) + '"';

//  Source := 'dshow:// :dshow-vdev=5Mega Webcam :dshow-adev= :dshow-size=640x480 :dshow-aspect-ratio=4\:3 :dshow-chroma=4 :dshow-fps=0 :no-dshow-config :no-dshow-tuner :dshow-tuner-channel=0 :dshow-tuner-frequency=0 :dshow-tuner-country=0 :dshow-tuner-standard=0 :dshow-tuner-input=0 :dshow-video-input=-1 :dshow-video-output=-1 :dshow-audio-input=-1 :dshow-audio-output=-1 :dshow-amtuner-mode=1 :dshow-audio-channels=0 :dshow-audio-samplerate=0 :dshow-audio-bitspersample=0 :live-caching=300';

  FMedia := libvlc_media_new_location(FVLC, PAnsiChar(Source));
  if FMedia = nil then
    raise Exception.Create('Ошибка создания медиа-источника');

  var VideoSize: AnsiString := ':dshow-size=' + FParams.Width.ToString + 'x' + FParams.Height.ToString;
  libvlc_media_add_option(FMedia, PAnsiChar(VideoSize));

  FPlayer := libvlc_media_player_new_from_media(FMedia);
  libvlc_media_release(FMedia);
  FMedia := nil;

  if FPlayer = nil then
    raise Exception.Create('Ошибка создания медиаплеера');

  libvlc_video_set_callbacks(FPlayer, @LockCallback, @UnlockCallback, @DisplayCallback, Self);
  libvlc_video_set_format(FPlayer, 'RV32', FParams.Width, FParams.Height,
    FParams.Width * FBytesPerPixel);
//  libvlc_video_set_crop_ratio
//  libvlc_video_set_crop_geometry(FPlayer, '4:3');
//  libvlc_video_set_aspect_ratio(FPlayer, '4:3');

  // Базовые настройки изображения на стороне VLC

  if FParams.OverrideParams then
  begin
    libvlc_video_set_adjust_int(FPlayer, libvlc_adjust_Enable, 1);
    libvlc_video_set_adjust_float(FPlayer, libvlc_adjust_Contrast, FParams.Contrast);
    libvlc_video_set_adjust_float(FPlayer, libvlc_adjust_Brightness, FParams.Brightness);
    libvlc_video_set_adjust_float(FPlayer, libvlc_adjust_Saturation, FParams. Saturation);
    libvlc_video_set_adjust_int(FPlayer, libvlc_adjust_Hue, FParams.Hue);
//    libvlc_adjust_Gamma
  end;

  FInitialized := True;
  ConsoleWriteMessage('Инициализация граббера завершена.');
end;

procedure TVlcFrameGrabber.Start;
begin
  if not IsInitialized then
    raise Exception.Create('Граббер не инициализирован. Вызовите Init.');

  if not FActive then
  begin
    // Восстанавливаем буфер, если он пуст
    TMonitor.Enter(Self);
    try
      if Length(FBuffer) = 0 then
        SetLength(FBuffer, FParams.Width * FParams.Height * FBytesPerPixel);
    finally
      TMonitor.Exit(Self);
    end;

    FActive := True;
    libvlc_media_player_play(FPlayer);
  end;
end;

procedure TVlcFrameGrabber.Stop;
begin
  if FActive then
  begin
    FActive := False;
    if IsInitialized and (libvlc_media_player_is_playing(FPlayer) = 1) then
    begin
      if (libvlc_dynamic_dll_vlc_version_bin < VLC_VERSION_BIN_040000) then
        libvlc_media_player_stop(FPlayer)
      else
        libvlc_media_player_stop_async(FPlayer);

      Sleep(50);

      while (libvlc_media_player_is_playing(FPlayer) = 1) do
        Sleep(50);
    end;

    TMonitor.Enter(Self);
    try
      SetLength(FBuffer, 0);
      FLastFrameTime := 0;
    finally
      TMonitor.Exit(Self);
    end;
  end;
end;

procedure TVlcFrameGrabber.CopyToBitmap(ABitmap: TBitmap);
var
  MapData: TBitmapData;

begin
  if not IsInitialized or not FActive or (ABitmap = nil) then
    Exit;

  ABitmap.SetSize(FParams.Width, FParams.Height);

  var Buffer := GetBufferCopy;
  if ABitmap.Map(TMapAccess.Write, MapData) then
    try
      Move(Buffer[0], MapData.Data^, Length(Buffer));
    finally
      ABitmap.Unmap(MapData);
    end;
end;


function TVlcFrameGrabber.GetBufferCopy: TBytes;
begin
  Result := nil;
  if not IsInitialized or not FActive then Exit;

  // Берём копию "сырого" буфера под защитой
  TMonitor.Enter(Self);
  try
    Result := Copy(FBuffer, 0, Length(FBuffer));
  finally
    TMonitor.Exit(Self);
  end;

  // Применяем обработку к копии (оригинал остаётся нетронутым)
  if (Length(Result) > 0) and FParams.OverrideParams then
  begin
    if FParams.Exposure <> 1.0 then
      ApplyExposureTo(Result, FParams.Exposure);

    if FParams.Sharpness > 0 then
      ApplySharpenTo(Result, FParams.Sharpness);
  end;
end;

function TVlcFrameGrabber.GetParams: TVlcInitParams;
begin
  FParams.OverrideParams := libvlc_video_get_adjust_int(FPlayer, libvlc_adjust_Enable) > 0;
  FParams.Contrast := libvlc_video_get_adjust_float(FPlayer, libvlc_adjust_Contrast);
  FParams.Brightness := libvlc_video_get_adjust_float(FPlayer, libvlc_adjust_Brightness);
  FParams.Saturation := libvlc_video_get_adjust_float(FPlayer, libvlc_adjust_Saturation);
  FParams.Hue := libvlc_video_get_adjust_int(FPlayer, libvlc_adjust_Hue);

  Result := FParams;
end;

procedure TVlcFrameGrabber.ApplyExposureTo(var Buf: TBytes; Factor: Single);
var
  i: Integer;
  p: PByte;
begin
  if Length(Buf) = 0 then Exit;

  p := @Buf[0];
  for i := 0 to (Length(Buf) div 4) - 1 do
  begin
    p^ := Byte(Min(255, Round(p^ * Factor))); Inc(p);
    p^ := Byte(Min(255, Round(p^ * Factor))); Inc(p);
    p^ := Byte(Min(255, Round(p^ * Factor))); Inc(p);
    Inc(p);
  end;
end;

procedure TVlcFrameGrabber.ApplySharpenTo(var Buf: TBytes; Factor: Single);
var
  i: Integer;
  p: PByte;
begin
  if (Factor <= 0) or (Length(Buf) = 0) then Exit;

  p := @Buf[0];
  for i := 0 to (Length(Buf) div 4) - 1 do
  begin
    p^ := Byte(Min(255, Max(0, Round((p^ - 128) * Factor + 128)))); Inc(p);
    p^ := Byte(Min(255, Max(0, Round((p^ - 128) * Factor + 128)))); Inc(p);
    p^ := Byte(Min(255, Max(0, Round((p^ - 128) * Factor + 128)))); Inc(p);
    Inc(p);
  end;
end;

{ --- VLC callbacks --- }

class function TVlcFrameGrabber.LockCallback(opaque: Pointer; var planes: Pointer): Pointer; cdecl;
var
  Grabber: TVlcFrameGrabber;
begin
  Grabber := TVlcFrameGrabber(opaque);
  if (Grabber = nil) or not Grabber.IsInitialized then
    Exit(nil);

  TMonitor.Enter(Grabber);
  planes := @Grabber.FBuffer[0];
  Result := planes;
end;

class procedure TVlcFrameGrabber.UnlockCallback(opaque, picture: Pointer; const planes: Pointer); cdecl;
var
  Grabber: TVlcFrameGrabber;
begin
  Grabber := TVlcFrameGrabber(opaque);
  if (Grabber <> nil) and Grabber.IsInitialized then
  begin
    Grabber.FLastFrameTime := Now;
    TMonitor.Exit(Grabber);
  end;
end;

class procedure TVlcFrameGrabber.DisplayCallback(opaque, picture: Pointer); cdecl;
begin
  // Отрисовка не требуется
end;

end.

