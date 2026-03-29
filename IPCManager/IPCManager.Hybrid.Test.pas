unit MainFormUnit;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, IPCManager.Hybrid;

type
  TfrmMain = class(TForm)
    btnStartListener: TButton;
    btnStopListener: TButton;
    mmoLog: TMemo;
    edtMessage: TEdit;
    btnSend: TButton;
    StatusBar1: TStatusBar;
    tmrStatus: TTimer;
    btnClear: TButton;
    Label1: TLabel;
    Label2: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnStartListenerClick(Sender: TObject);
    procedure btnStopListenerClick(Sender: TObject);
    procedure btnSendClick(Sender: TObject);
    procedure tmrStatusTimer(Sender: TObject);
    procedure btnClearClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  private
    FIPC: TIPCManager;
    FMessageCount: Integer;
    FStartTime: TDateTime;
    
    procedure HandleIPCMessage(const Msg: TIPCMessage);
    procedure HandleIPCError(const ErrorMsg: string);
    procedure Log(const Text: string);
    procedure UpdateStatus;
  public
    { Public declarations }
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  FMessageCount := 0;
  FStartTime := Now;
  
  // Создаем IPC
  FIPC := TUniversalIPC.Create('MyAppIPC');
  
  // Настраиваем обработчики
  FIPC.OnMessage := HandleIPCMessage;
  FIPC.OnError := HandleIPCError;
  
  Log('IPC создан. Имя: MyAppIPC');
  UpdateStatus;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  // Останавливаем listener перед уничтожением
  if FIPC.ListenerActive then
    FIPC.StopListener;
    
  FreeAndNil(FIPC);
end;

procedure TfrmMain.HandleIPCMessage(const Msg: TIPCMessage);
var
  TextMsg: string;
begin
  Inc(FMessageCount);
  
  // Декодируем сообщение
  if Length(Msg.Data) > 0 then
    TextMsg := TEncoding.UTF8.GetString(Msg.Data)
  else
    TextMsg := '[No data]';
  
  // Выводим в лог (в потоке UI)
  TThread.Queue(nil, procedure
  begin
    Log(Format('[%s] Type:%d Size:%d - %s',
      [FormatDateTime('hh:nn:ss.zzz', Msg.Timestamp),
       Msg.MsgType,
       Length(Msg.Data),
       TextMsg]));
       
    UpdateStatus;
  end);
end;

procedure TfrmMain.HandleIPCError(const ErrorMsg: string);
begin
  TThread.Queue(nil, procedure
  begin
    Log('ОШИБКА: ' + ErrorMsg);
  end);
end;

procedure TfrmMain.Log(const Text: string);
begin
  if mmoLog.Lines.Count > 1000 then
    mmoLog.Lines.Clear;
    
  mmoLog.Lines.Add(Text);
  
  // Автопрокрутка
  mmoLog.Perform(EM_LINESCROLL, 0, mmoLog.Lines.Count);
end;

procedure TfrmMain.UpdateStatus;
var
  Elapsed: Double;
  MsgPerSec: Double;
begin
  Elapsed := (Now - FStartTime) * 24 * 60 * 60;
  if Elapsed > 0 then
    MsgPerSec := FMessageCount / Elapsed
  else
    MsgPerSec := 0;
    
  StatusBar1.Panels[0].Text := Format('Сообщений: %d', [FMessageCount]);
  StatusBar1.Panels[1].Text := Format('Скорость: %.1f/сек', [MsgPerSec]);
  StatusBar1.Panels[2].Text := Format('Listener: %s', 
    [BoolToStr(FIPC.ListenerActive, 'Активен', 'Остановлен')]);
end;

procedure TfrmMain.btnStartListenerClick(Sender: TObject);
begin
  if not FIPC.ListenerActive then
  begin
    FIPC.StartListener(5); // Интервал 5 мс
    Log('Listener запущен');
    btnStartListener.Enabled := False;
    btnStopListener.Enabled := True;
  end;
end;

procedure TfrmMain.btnStopListenerClick(Sender: TObject);
begin
  if FIPC.ListenerActive then
  begin
    FIPC.StopListener;
    Log('Listener остановлен');
    btnStartListener.Enabled := True;
    btnStopListener.Enabled := False;
  end;
end;

procedure TfrmMain.btnSendClick(Sender: TObject);
var
  MsgText: string;
begin
  MsgText := Trim(edtMessage.Text);
  if MsgText <> '' then
  begin
    try
      FIPC.Send(1, MsgText); // MsgType = 1 для текстовых сообщений
      Log('Отправлено: ' + MsgText);
      edtMessage.Clear;
      edtMessage.SetFocus;
    except
      on E: Exception do
        Log('Ошибка отправки: ' + E.Message);
    end;
  end;
end;

procedure TfrmMain.tmrStatusTimer(Sender: TObject);
begin
  UpdateStatus;
end;

procedure TfrmMain.btnClearClick(Sender: TObject);
begin
  mmoLog.Clear;
end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FIPC.ListenerActive then
  begin
    if MessageDlg('Listener активен. Остановить и закрыть?',
      mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    begin
      FIPC.StopListener;
      CanClose := True;
    end
    else
      CanClose := False;
  end
  else
    CanClose := True;
end;

end.