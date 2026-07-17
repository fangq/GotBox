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
  Classes, SysUtils, Forms, Controls, StdCtrls, Dialogs, LCLIntf, Graphics,
  Clipbrd, gboxconfigstore, gboxcredstore, gboxgithubapi, gboxoauth, gboxlog,
  gboxmsg;

type
  TLoginForm = class(TForm)
    btnDevice: TButton;
    lblOr: TLabel;
    lblUser: TLabel;
    eUser: TEdit;
    lblPat: TLabel;
    ePat: TEdit;
    lblHint: TLabel;
    lnkToken: TLabel;
    btnValidate: TButton;
    btnCancel: TButton;
    procedure btnDeviceClick(Sender: TObject);
    procedure btnValidateClick(Sender: TObject);
    procedure lnkTokenClick(Sender: TObject);
  private
    FToken: string;
    procedure SetBusy(ABusy: Boolean);
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
    Sleep(FInterval * 1000);
    if Terminated then Exit;
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
  SetBusy(True);
  try
    if not RequestDeviceCode(OAuthClientId, dev, err) then
    begin
      MsgError('Could not start GitHub sign-in:' + LineEnding + err);
      Exit;
    end;
  finally
    SetBusy(False);
  end;

  // 2. show the user code, copy it, and open the verification page
  Clipboard.AsText := dev.UserCode;
  lblHint.Caption := 'Enter code ' + dev.UserCode + ' at ' +
    dev.VerificationUri + ' (copied to clipboard)';
  lblHint.Update;
  OpenURL(dev.VerificationUri);

  // 3. poll on a worker thread while pumping the GUI
  SetBusy(True);
  th := TDeviceThread.Create(OAuthClientId, dev);
  try
    while not th.Finished do
    begin
      Application.ProcessMessages;
      CheckSynchronize(50);
      Sleep(10);
    end;
    th.WaitFor;
    status := th.Status;
    login := th.Login;
    tok := th.Token;
    saved := th.Saved;
    err := th.Err;
  finally
    th.Free;
    SetBusy(False);
  end;

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
    psDenied: MsgError('Authorization was denied on GitHub.');
    psExpired: MsgError('The sign-in code expired. Please try again.');
    else
      MsgError('GitHub sign-in did not complete:' + LineEnding + err);
  end;
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
  eUser.Text := ACfg.GithubUser;
  ePat.Text := '';
  // device-flow sign-in only when a client id is configured; otherwise the form
  // is the plain manual-PAT dialog
  btnDevice.Visible := OAuthAvailable;
  lblOr.Visible := OAuthAvailable;
  CenterForm(Self);
  Result := ShowModal = mrOK;
  if Result then
    ACfg.GithubUser := Trim(eUser.Text);
end;

end.
