unit MarketPosCamera.Core;

interface

uses
  System.SysUtils,
  IPCManager.Hybrid,
  MarketPosCamera.VLCCamera.Grabber;

type
  TMarketPosCamera = class
  private
    FIPCManagerSender: TIPCManager;
    FIPCManagerReceiver: TIPCManager;
    FFrameGrabber: TVlcFrameGrabber;

    procedure OnReceiveMessage(const Msg: TIPCMessage);
    procedure OnSenderError(const ErrorMsg: string);
    procedure OnReceiverError(const ErrorMsg: string);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Start;
    procedure Stop;
  end;

implementation

uses
  SiAuto,
  System.IOUtils,
  System.JSON,
  MarketPosCamera.Common,
  MarketPosCamera.Settings;

{ TMarketPosCamera }

constructor TMarketPosCamera.Create;
begin
  var AppName: string := 'MarketPosCamera'; // ChangeFileExt(ExtractFileName(ParamStr(0)).ToUpper, string.Empty);

  FIPCManagerSender := TIPCManager.Create(AppName + '_Sender', c_SenderSharedMemSize);
  FIPCManagerSender.OnError := OnSenderError;

  FIPCManagerReceiver := TIPCManager.Create(AppName + '_Receiver', c_ReceiverSharedMemSize);
  FIPCManagerReceiver.OnMessage := OnReceiveMessage;
  FIPCManagerReceiver.OnError := OnReceiverError;

  FFrameGrabber := TVlcFrameGrabber.Create(Settings.Common.VLCLibPath);
end;

destructor TMarketPosCamera.Destroy;
begin
  Stop;

  FIPCManagerReceiver.Free;
  FIPCManagerSender.Free;

  inherited;
end;

procedure TMarketPosCamera.OnReceiveMessage(const Msg: TIPCMessage);
begin
  case Msg.MsgType of
    0: begin
      // Установка параметров
      var Data: string := TEncoding.UTF8.GetString(Msg.Data);
      var J: TJSONValue := TJSONValue.ParseJSONValue(Data);
      try
        var NewParams: TVlcInitParams := Default(TVlcInitParams);
        NewParams.OverrideParams := J.GetValue<Boolean>('OverrideParams', NewParams.OverrideParams);
        NewParams.DeviceName := J.GetValue<string>('DeviceName', NewParams.DeviceName);
        NewParams.Width := J.GetValue<Integer>('Width', NewParams.Width);
        NewParams.Height := J.GetValue<Integer>('Height', NewParams.Height);
        NewParams.Brightness := J.GetValue<Single>('Brightness', NewParams.Brightness);
        NewParams.Contrast := J.GetValue<Single>('Contrast', NewParams.Contrast);
        NewParams.Saturation := J.GetValue<Single>('Saturation', NewParams.Saturation);
        NewParams.Hue := J.GetValue<Integer>('Hue', NewParams.Hue);
        NewParams.Sharpness := J.GetValue<Single>('Sharpness', NewParams.Sharpness);
        NewParams.Exposure := J.GetValue<Single>('Exposure', NewParams.Exposure);

        if not FFrameGrabber.Params.IsEquals(NewParams) then
        begin
          var Active := FFrameGrabber.Active;
          try
            FFrameGrabber.Init(NewParams);
          finally
            if Active then
              FFrameGrabber.Start;
          end;
        end;
      finally
        J.Free;
      end;
    end;

    1: begin
      // Запрос параметров
      var Params: TVlcInitParams := FFrameGrabber.Params;
      var J := TJSONObject.Create;
      try
        J
          .AddPair('OverrideParams', TJSONBool.Create(Params.OverrideParams))
          .AddPair('Width', TJSONNumber.Create(Params.Width))
          .AddPair('Height', TJSONNumber.Create(Params.Height))
          .AddPair('Hue', TJSONNumber.Create(Params.Hue))
          .AddPair('Brightness', TJSONNumber.Create(Params.Brightness))
          .AddPair('Contrast', TJSONNumber.Create(Params.Contrast))
          .AddPair('Saturation', TJSONNumber.Create(Params.Saturation))
          .AddPair('Sharpness', TJSONNumber.Create(Params.Sharpness))
          .AddPair('Exposure', TJSONNumber.Create(Params.Exposure));

        FIPCManagerSender.Send(1, J.ToJSON);
      finally
        J.Free;
      end;
    end;

    2: begin
      // Запрос видео буффера
      FIPCManagerSender.Send(2, FFrameGrabber.GetBufferCopy);
    end;
  end;
//  case Msg.MsgType of
//    0: // Текстовое сообщение
//    begin
//      var Text: string := TEncoding.UTF8.GetString(Msg.Data);
//      Writeln('Получено: ' + Text);
//    end;
//
//    1: // Числовое значение
//    begin
//      if Length(Msg.Data) < SizeOf(Integer) then
//        Writeln('Ошибка получения числа: Недостаточно данных в массиве')
//      else
//        Writeln(Format('Получено число: %d', [PInteger(@Msg.Data[0])^]));
//    end;
//
//    2: // Команда
//    begin
//      if Length(Msg.Data) < SizeOf(Integer) then
//        Writeln('Ошибка получения команды: Недостаточно данных в массиве')
//      else
//        Writeln(Format('Получена команда: %d', [PInteger(@Msg.Data[0])^]));
//    end;
//  end;
end;

procedure TMarketPosCamera.OnReceiverError(const ErrorMsg: string);
begin
  SiDevOps.LogError('Ошибка получения: ' + ErrorMsg);
end;

procedure TMarketPosCamera.OnSenderError(const ErrorMsg: string);
begin
  SiDevOps.LogError('Ошибка передачи: ' + ErrorMsg);
end;

procedure TMarketPosCamera.Start;
begin
  var Params: TVlcInitParams;
  Params.OverrideParams := Settings.Camera.OverrideParams;
  Params.Width := Settings.Camera.Width;
  Params.Height := Settings.Camera.Height;
  Params.Brightness := Settings.Camera.Brightness;
  Params.Contrast := Settings.Camera.Contrast;
  Params.Saturation := Settings.Camera.Saturation;
  Params.Hue := Settings.Camera.Hue;
  Params.Sharpness := Settings.Camera.Sharpness;
  Params.Exposure := Settings.Camera.Exposure;

  FFrameGrabber.Init(Params);
  FFrameGrabber.Start;

  FIPCManagerReceiver.StartListener;
end;

procedure TMarketPosCamera.Stop;
begin
  FIPCManagerReceiver.StopListener;

  if Assigned(FFrameGrabber) then
  begin
    FFrameGrabber.Stop;
    FreeAndNil(FFrameGrabber);
  end;
end;

end.
