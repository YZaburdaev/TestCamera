unit MarketPosCamera.Settings;

interface

uses
  System.SysUtils;

type
  TSettings = record
    Common: record
      VLCLibPath: string;
    end;

    Camera: record
      OverrideParams: Boolean;
      Width: Integer;
      Height: Integer;
      Brightness: Single;
      Contrast: Single;
      Saturation: Single;
      Hue: Integer;
      Sharpness: Single; // коэффициент резкости
      Exposure: Single;  // коэффициент экспозиции
    end;

    procedure Read;
  end;

var
  Settings: TSettings;

implementation

uses
  System.IniFiles,
  System.IOUtils;


procedure TSettings.Read;
var
  LocalFormatSettings: TFormatSettings;

  function ReadSingle(Ini: TIniFile; const Section, Name: string; DefValue: Single): Single;
  begin
    var S: string := FloatToStr(DefValue, LocalFormatSettings);

    S := Ini.ReadString(Section, Name, S);

    if S.IsEmpty then
      Exit(DefValue);

    if not TryStrToFloat(S, Result, LocalFormatSettings) then
      Exit(DefValue);
  end;

begin
  LocalFormatSettings := TFormatSettings.Invariant;
  LocalFormatSettings.DecimalSeparator := '.';

  var Ini: TIniFile := TIniFile.Create(ChangeFileExt(ParamStr(0), '.ini'));
  try
    Settings.Common.VLCLibPath := Ini.ReadString('Common', 'VLCLibPath', string.Empty);
    if Settings.Common.VLCLibPath.Trim.IsEmpty then
      Settings.Common.VLCLibPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'VLC');

    Settings.Camera.OverrideParams := Ini.ReadInteger('Camera', 'Override', 0) > 0;
    Settings.Camera.Width := Ini.ReadInteger('Camera', 'Width', 640);
    Settings.Camera.Height := Ini.ReadInteger('Camera', 'Height', 480);

    Settings.Camera.Brightness := ReadSingle(Ini, 'Camera', 'Brightness', 1);
    Settings.Camera.Contrast := ReadSingle(Ini, 'Camera', 'Contrast', 1);
    Settings.Camera.Saturation := ReadSingle(Ini, 'Camera', 'Saturation', 1);
    Settings.Camera.Hue := Ini.ReadInteger('Camera', 'Hue', 1);
    Settings.Camera.Sharpness := ReadSingle(Ini, 'Camera', 'Sharpness', 0); // коэффициент резкости
    Settings.Camera.Exposure := ReadSingle(Ini, 'Camera', 'Exposure', 1); // коэффициент экспозиции
  finally
    Ini.Free;
  end;
end;

end.
