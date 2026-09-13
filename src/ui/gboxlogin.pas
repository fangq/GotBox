{
  GotBox -- Cross-machine file sync over your own private git repositories.
  Copyright (C) 2026 Qianqian Fang <fangqq at gmail.com>.

  This program is free software: you can redistribute it and/or modify it under
  the terms of the GNU General Public License as published by the Free Software
  Foundation, either version 3 of the License, or (at your option) any later
  version.

  This program is distributed in the hope that it will be useful, but WITHOUT
  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
  FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

  You should have received a copy of the GNU General Public License along with
  this program.  If not, see <https://www.gnu.org/licenses/>.
}

unit gboxlogin;

{ GitHub account window: capture username + Personal Access Token, validate the
  token, and (from M2 onward) persist the PAT into the OS credential store.
  In M1 the validation is a stub and only the username is saved to config. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs, LCLIntf,
  Graphics, Clipbrd, gboxconfigstore, gboxcredstore, gboxgithubapi, gboxoauth,
  gboxlog, gboxmsg;

type
  TLoginForm = class(TForm)
    rgMethod: TRadioGroup;
    pnlDevice: TPanel;
    btnDevice: TButton;
    lblCode: TLabel;
    eCode: TEdit;
    btnCopyCode: TButton;
    mDevMsg: TMemo;
    btnDevCancel: TButton;
    pnlPat: TPanel;
    lblUser: TLabel;
    eUser: TEdit;
    lblPat: TLabel;
    ePat: TEdit;
    lblHint: TLabel;
    lnkToken: TLabel;
    btnValidate: TButton;
    btnCancel: TButton;
    procedure btnCopyCodeClick(Sender: TObject);
    procedure btnDevCancelClick(Sender: TObject);
    procedure btnDeviceClick(Sender: TObject);
    procedure btnValidateClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure lnkTokenClick(Sender: TObject);
    procedure rgMethodClick(Sender: TObject);
  private
    FToken: string;
    FDevCancelled: Boolean;   // user pressed "Cancel sign-in" while polling
    FDevPolling: Boolean;     // a device-flow poll loop is running right now
    FCloseAfterCancel: Boolean;   // close the dialog once the poll has stopped
    procedure SetBusy(ABusy: Boolean);
    { Fills the read-only code box; an empty code greys it (and Copy) out, so
      neither invites a click before a sign-in has produced a code. }
    procedure SetCode(const ACode: string);
    { Shows the panel that belongs to the selected sign-in method. }
    procedure ApplyMethod;
  public
    { Shows the modal login dialog. On OK, writes username into ACfg and keeps
      the entered token in FToken (for the caller to hand to the credential
      store in M2). Returns True if the user confirmed. }
    function RunLogin(ACfg: TGotConfig): Boolean;
    property Token: string read FToken;
  end;

var
  LoginForm: TLoginForm;

implementation

uses
  DateUtils;

  {$R *.lfm}

type
  { Runs the blocking GitHub token validation + keyring store off the GUI thread,
    so the dialog stays responsive (the HTTPS round-trip can take many seconds,
    especially over a remote link like x2go). The caller pumps the message loop
    while this runs, then reads the results. }
  TValidateThread = class(TThread)
  private
    FToken: string;
    FLogin, FErr: string;
    FValidated, FSaved: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AToken: string);
    property Login: string read FLogin;
    property Err: string read FErr;
    property Validated: Boolean read FValidated;
    property Saved: Boolean read FSaved;
  end;

constructor TValidateThread.Create(const AToken: string);
begin
  FToken := AToken;
  FreeOnTerminate := False;   // caller reads results then frees us
  inherited Create(False);    // run now
end;

procedure TValidateThread.Execute;
var
  api: TGitHubApi;
  cred: TCredStore;
begin
  api := TGitHubApi.Create(FToken);
  try
    FValidated := api.ValidateToken(FLogin, FErr);
  finally
    api.Free;
  end;
  if not FValidated then Exit;
  // Persist the token in the OS credential store keyed by the canonical login.
  cred := TCredStore.Create;
  try
    FSaved := cred.SaveToken(FLogin, FToken);
  finally
    cred.Free;
  end;
end;

type
  { Polls the GitHub device-flow token endpoint off the GUI thread until the user
    authorizes (or it is denied/expires), then validates the token and stores it.
    The GUI pumps the message loop while this runs. }
  TDeviceThread = class(TThread)
  private
    FClientId, FDeviceCode: string;
    FInterval, FExpiresIn: Integer;
    FToken, FLogin, FErr: string;
    FStatus: TPollStatus;
    FSaved: Boolean;
  protected
    procedure Execute; override;
    { Sleeps ASec seconds in short slices; returns False as soon as the GUI asks
      us to stop, so "Cancel sign-in" does not wait out a whole poll interval. }
    function NapUnlessTerminated(ASec: Integer): Boolean;
  public
    constructor Create(const AClientId: string; const ADev: TDeviceCode);
    property Status: TPollStatus read FStatus;
    property Token: string read FToken;
    property Login: string read FLogin;
    property Err: string read FErr;
    property Saved: Boolean read FSaved;
  end;

constructor TDeviceThread.Create(const AClientId: string; const ADev: TDeviceCode);
begin
  FClientId := AClientId;
  FDeviceCode := ADev.DeviceCode;
  FInterval := ADev.Interval;
  FExpiresIn := ADev.ExpiresIn;
  FStatus := psError;
  FreeOnTerminate := False;
  inherited Create(False);
end;

function TDeviceThread.NapUnlessTerminated(ASec: Integer): Boolean;
var
  i: Integer;
begin
  for i := 1 to ASec * 10 do
  begin
    if Terminated then Exit(False);
    Sleep(100);
  end;
  Result := not Terminated;
end;

procedure TDeviceThread.Execute;
var
  api: TGitHubApi;
  cred: TCredStore;
  started: TDateTime;
  tok, perr: string;
  st: TPollStatus;
begin
  started := Now;
  // poll no faster than the server's interval; give the user time to authorize
  repeat
    if not NapUnlessTerminated(FInterval) then Exit;
    if SecondsBetween(Now, started) > FExpiresIn then
    begin
      FStatus := psExpired;
      Exit;
    end;
    if not PollForToken(FClientId, FDeviceCode, tok, st, perr) then
    begin
      FErr := perr;
      FStatus := psError;
      Exit;
    end;
    case st of
      psPending: ;                 // not yet -- keep waiting
      psSlowDown: Inc(FInterval, 5);
      psSuccess:
      begin
        FToken := tok;
        Break;
      end
      else
      begin
        FStatus := st;
        FErr := perr;
        Exit;
      end;
    end;
  until False;

  // authorized: confirm the token and learn the canonical login, then store it
  api := TGitHubApi.Create(FToken);
  try
    if not api.ValidateToken(FLogin, FErr) then
    begin
      FStatus := psError;
      Exit;
    end;
  finally
    api.Free;
  end;
  cred := TCredStore.Create;
  try
    FSaved := cred.SaveToken(FLogin, FToken);
  finally
    cred.Free;
  end;
  FStatus := psSuccess;
end;

procedure TLoginForm.SetBusy(ABusy: Boolean);
begin
  if ABusy then Screen.Cursor := crHourGlass
  else
    Screen.Cursor := crDefault;
  btnDevice.Enabled := not ABusy;
  btnValidate.Enabled := not ABusy;
  btnCancel.Enabled := not ABusy;
end;

procedure TLoginForm.SetCode(const ACode: string);
begin
  eCode.Text := ACode;
  eCode.Enabled := ACode <> '';
  btnCopyCode.Enabled := eCode.Enabled;
end;

procedure TLoginForm.ApplyMethod;
const
  PAT_PANEL_H = 160;   // the PAT fields need far less room than the device panel
var
  useDevice: Boolean;
  y, h: Integer;
begin
  useDevice := rgMethod.Visible and (rgMethod.ItemIndex = 0);
  pnlDevice.Visible := useDevice;
  pnlPat.Visible := not useDevice;
  // "Validate & Save" only applies to a hand-typed token; the device flow
  // finishes by itself once GitHub accepts the code.
  btnValidate.Visible := not useDevice;
  // shrink the window around whichever panel is showing, so the PAT form does
  // not sit above a tall empty gap
  if useDevice then
  begin
    y := pnlDevice.Top;
    h := pnlDevice.Height;
  end
  else
  begin
    y := pnlPat.Top;
    h := PAT_PANEL_H;
    pnlPat.Height := h;   // the .lfm sizes both panels alike; trim this one
  end;
  btnValidate.Top := y + h + 14;
  btnCancel.Top := btnValidate.Top;
  ClientHeight := btnCancel.Top + btnCancel.Height + 14;
  if not useDevice then
    ActiveControl := ePat;
end;

procedure TLoginForm.rgMethodClick(Sender: TObject);
begin
  ApplyMethod;
end;

procedure TLoginForm.btnCopyCodeClick(Sender: TObject);
begin
  if eCode.Text = '' then Exit;
  Clipboard.AsText := eCode.Text;
  eCode.SelectAll;
end;

procedure TLoginForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if not FDevPolling then Exit;   // nothing pending -- close as usual
  { Closing now would pull the dialog out from under the running poll handler,
    so refuse the close, ask, and let the handler shut the window down once the
    worker thread has actually stopped. }
  CanClose := False;
  if not MsgConfirm('A GitHub sign-in is still waiting for you to authorize ' +
    'GotBox.' + LineEnding + LineEnding + 'Cancel it and close this window?') then
    Exit;
  FCloseAfterCancel := True;
  btnDevCancelClick(nil);
end;

procedure TLoginForm.btnDevCancelClick(Sender: TObject);
begin
  if not FDevPolling then Exit;
  { Only flips the flag; the poll loop in btnDeviceClick stops the worker thread
    and restores the dialog. }
  FDevCancelled := True;
  btnDevCancel.Enabled := False;
  mDevMsg.Lines.Text := 'Cancelling sign-in...';
  mDevMsg.Update;
end;

procedure TLoginForm.btnDeviceClick(Sender: TObject);
var
  dev: TDeviceCode;
  th: TDeviceThread;
  err, login, tok: string;
  status: TPollStatus;
  saved: Boolean;
begin
  if not OAuthAvailable then Exit;

  // 1. start the device authorization (one quick request)
  SetCode('');
  mDevMsg.Lines.Text := 'Contacting GitHub...';
  mDevMsg.Update;
  SetBusy(True);
  try
    if not RequestDeviceCode(OAuthClientId, dev, err) then
    begin
      mDevMsg.Lines.Text := 'Could not start GitHub sign-in:' + LineEnding + err;
      MsgError('Could not start GitHub sign-in:' + LineEnding + err);
      Exit;
    end;
  finally
    SetBusy(False);
  end;

  // 2. show the user code in the read-only box, copy it, open the browser
  SetCode(dev.UserCode);
  Clipboard.AsText := dev.UserCode;
  mDevMsg.Lines.Text :=
    'Enter the code above at ' + dev.VerificationUri + LineEnding + LineEnding +
    'It is already on your clipboard and that page should be open in your ' +
    'browser; if it is not, open the address by hand.' + LineEnding + LineEnding +
    'Then authorize GotBox -- this window finishes the sign-in by itself. The ' +
    'code expires in about ' + IntToStr(dev.ExpiresIn div 60) + ' minutes.';
  mDevMsg.Update;
  OpenURL(dev.VerificationUri);

  // 3. poll on a worker thread while pumping the GUI, so the dialog keeps
  //    repainting and "Cancel sign-in" stays clickable the whole time
  FDevCancelled := False;
  SetBusy(True);
  // the wait is minutes long and the window stays usable, so no hourglass --
  // an hourglass here is what makes the dialog look hung
  Screen.Cursor := crDefault;
  FDevPolling := True;
  btnDevCancel.Enabled := True;
  th := TDeviceThread.Create(OAuthClientId, dev);
  try
    while not th.Finished do
    begin
      Application.ProcessMessages;
      CheckSynchronize(50);
      Sleep(10);
      if FDevCancelled and not th.Terminated then th.Terminate;
    end;
    th.WaitFor;
    status := th.Status;
    login := th.Login;
    tok := th.Token;
    saved := th.Saved;
    err := th.Err;
  finally
    th.Free;
    FDevPolling := False;
    btnDevCancel.Enabled := False;
    SetBusy(False);
  end;

  // a cancel that lost the race against a completed authorization still counts
  // as a successful sign-in -- the token is already validated and stored
  if FDevCancelled and (status <> psSuccess) then
  begin
    FDevCancelled := False;
    SetCode('');
    mDevMsg.Lines.Text := 'Sign-in cancelled. Press "Sign in with GitHub" to ' +
      'start over, or switch to a Personal Access Token above.';
    // the cancel came from the window's close button: honour the close now
    if FCloseAfterCancel then
    begin
      FCloseAfterCancel := False;
      ModalResult := mrCancel;
    end;
    Exit;
  end;
  FDevCancelled := False;
  FCloseAfterCancel := False;

  case status of
    psSuccess:
    begin
      eUser.Text := login;
      FToken := tok;
      if not saved then
        MsgError('Signed in, but the token could not be saved to the credential store.');
      if Assigned(Log) then Log.Info('login', 'device-flow sign-in for ' + login);
      ModalResult := mrOK;
    end;
    psDenied:
    begin
      mDevMsg.Lines.Text := 'Authorization was denied on GitHub.';
      MsgError('Authorization was denied on GitHub.');
    end;
    psExpired:
    begin
      mDevMsg.Lines.Text := 'The sign-in code expired. Press "Sign in with ' +
        'GitHub" for a fresh code.';
      MsgError('The sign-in code expired. Please try again.');
    end;
    else
    begin
      mDevMsg.Lines.Text := 'GitHub sign-in did not complete:' + LineEnding + err;
      MsgError('GitHub sign-in did not complete:' + LineEnding + err);
    end;
  end;
  if ModalResult <> mrOK then SetCode('');
end;

procedure TLoginForm.btnValidateClick(Sender: TObject);
var
  th: TValidateThread;
  login, err: string;
  okValidated, okSaved: Boolean;
begin
  if Trim(ePat.Text) = '' then
  begin
    MsgInfo('Please enter a Personal Access Token (scope: repo).');
    Exit;
  end;

  // Validate against GitHub (blocking HTTPS) + save to the keyring on a worker
  // thread; pump events here so the window doesn't freeze / show "not responding".
  Screen.Cursor := crHourGlass;
  btnValidate.Enabled := False;
  btnCancel.Enabled := False;
  th := TValidateThread.Create(Trim(ePat.Text));
  try
    while not th.Finished do
    begin
      Application.ProcessMessages;
      CheckSynchronize(50);   // also runs any queued Synchronize calls
    end;
    th.WaitFor;
    okValidated := th.Validated;
    okSaved := th.Saved;
    login := th.Login;
    err := th.Err;
  finally
    th.Free;
    btnValidate.Enabled := True;
    btnCancel.Enabled := True;
    Screen.Cursor := crDefault;
  end;

  if not okValidated then
  begin
    MsgError('Could not validate token:' + LineEnding + err);
    Exit;
  end;

  // GitHub tells us the canonical login name; trust it over the typed value.
  eUser.Text := login;
  FToken := Trim(ePat.Text);
  if not okSaved then
    MsgError('Token validated but could not be saved to the credential store.');

  if Assigned(Log) then Log.Info('login', 'token validated for ' + login);
  ModalResult := mrOK;
end;

procedure TLoginForm.lnkTokenClick(Sender: TObject);
begin
  OpenURL('https://github.com/settings/tokens/new?scopes=repo&description=GotBox');
end;

function TLoginForm.RunLogin(ACfg: TGotConfig): Boolean;
begin
  Result := False;
  if Visible then begin
    BringToFront;
    Exit;
  end;
  FToken := '';
  FDevCancelled := False;
  FCloseAfterCancel := False;
  eUser.Text := ACfg.GithubUser;
  ePat.Text := '';
  SetCode('');
  mDevMsg.Lines.Text := 'Press "Sign in with GitHub" to get a one-time code. ' +
    'GotBox copies it to the clipboard and opens the GitHub page where you ' +
    'paste it; no token to create by hand.';
  // device-flow sign-in only when a client id is configured; otherwise the form
  // is the plain manual-PAT dialog
  rgMethod.Visible := OAuthAvailable;
  if OAuthAvailable then
  begin
    rgMethod.ItemIndex := 0;
    pnlPat.Top := pnlDevice.Top;
  end
  else
    pnlPat.Top := rgMethod.Top;   // reclaim the hidden selector's space
  ApplyMethod;
  CenterForm(Self);
  Result := ShowModal = mrOK;
  if Result then
    ACfg.GithubUser := Trim(eUser.Text);
end;

end.
