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

{ Account & storage window: pick which backend holds the synced repos and
  supply whatever it needs -- one tab per backend.

    GitHub      device-flow sign-in, or a Personal Access Token
    GitLab      a Personal Access Token, on gitlab.com or your own instance
    Self-hosted an ssh:// base URL or a local folder (your ssh keys do the auth)
    S3          a bucket, through the git-remote-s3 helper and your AWS profile

  Tokens are validated against the server and written straight to the OS
  credential store by the worker threads below (keyed per backend, see
  gboxremote.CredAccount); only non-secret settings go back into the config. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, ComCtrls, Dialogs,
  LCLIntf, Graphics, Clipbrd, gboxconfigstore, gboxcredstore, gboxgithubapi,
  gboxgitlabapi, gboxbackend, gboxremote, gboxoauth, gboxlog, gboxmsg;

type
  TLoginForm = class(TForm)
    pcBackend: TPageControl;
    tsGitHub: TTabSheet;
    rgGhMethod: TRadioGroup;
    pnlDevice: TPanel;
    pnlDevTop: TPanel;
    pnlDevBottom: TPanel;
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
    tsGitLab: TTabSheet;
    lblGlHost: TLabel;
    eGlHost: TEdit;
    lblGlUser: TLabel;
    eGlUser: TEdit;
    lblGlNs: TLabel;
    eGlNs: TEdit;
    lblGlPat: TLabel;
    eGlPat: TEdit;
    lblGlHint: TLabel;
    lnkGlToken: TLabel;
    mGlMsg: TMemo;
    tsSelfHosted: TTabSheet;
    lblSsh: TLabel;
    eSshBase: TEdit;
    btnBrowseBase: TButton;
    mSshHelp: TMemo;
    tsS3: TTabSheet;
    lblS3Base: TLabel;
    eS3Base: TEdit;
    lblS3Profile: TLabel;
    eS3Profile: TEdit;
    lblS3Region: TLabel;
    eS3Region: TEdit;
    lblS3Helper: TLabel;
    mS3Help: TMemo;
    pnlButtons: TPanel;
    lblSignedIn: TLabel;
    btnSignOut: TButton;
    btnTest: TButton;
    btnValidate: TButton;
    btnCancel: TButton;
    procedure btnBrowseBaseClick(Sender: TObject);
    procedure btnCopyCodeClick(Sender: TObject);
    procedure btnDevCancelClick(Sender: TObject);
    procedure btnDeviceClick(Sender: TObject);
    procedure btnSignOutClick(Sender: TObject);
    procedure btnTestClick(Sender: TObject);
    procedure btnValidateClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure lnkGlTokenClick(Sender: TObject);
    procedure lnkTokenClick(Sender: TObject);
    procedure pcBackendChange(Sender: TObject);
    procedure pcBackendChanging(Sender: TObject; var AllowChange: Boolean);
    procedure rgGhMethodClick(Sender: TObject);
  private
    FToken: string;
    FAccount: string;         // credential-store key the token was saved under
    FS3Ready: Boolean;        // is the git-remote-s3 helper installed?
    FDevCancelled: Boolean;   // user pressed "Cancel sign-in" while polling
    FDevPolling: Boolean;     // a device-flow poll loop is running right now
    FCloseAfterCancel: Boolean;   // close the dialog once the poll has stopped
    FCfg: TGotConfig;         // the config this dialog is editing (not owned)
    FState: TAccountState;    // what the window may offer -- see ApplyState
    FLockKind: TBackendKind;  // the backend this folder belongs to, once it does
    procedure SetBusy(ABusy: Boolean);
    { Fills the read-only code box; an empty code greys it (and Copy) out, so
      neither invites a click before a sign-in has produced a code. }
    procedure SetCode(const ACode: string);
    { The backend the selected tab stands for. }
    function ActiveKind: TBackendKind;
    function TabForKind(AKind: TBackendKind): TTabSheet;
    { Shows the panel that belongs to the selected GitHub sign-in method. }
    procedure ApplyGhMethod;
    { Points the bottom buttons at whatever the active tab can do. }
    procedure ApplyTab;
    { Applies FState to the window: which backends may be chosen, whether the
      fields accept input, and whether the action is Save or Sign out. }
    procedure ApplyState;
    procedure LoadFromConfig(ACfg: TGotConfig);
    procedure SaveToConfig(ACfg: TGotConfig);
    { Cheap, local checks for the active tab; complains and focuses the offender
      on failure. Does not touch the network. }
    function ValidateActiveTab: Boolean;
    { Validates a token against GitHub/GitLab on a worker thread and stores it;
      sets ModalResult on success. }
    procedure DoTokenValidate(AKind: TBackendKind; const AHost, AToken: string);
  public
    { Shows the modal dialog. On OK, writes the chosen backend and its settings
      into ACfg; any token has already gone to the credential store. Returns
      True if the user confirmed. }
    function RunLogin(ACfg: TGotConfig): Boolean;
    property Token: string read FToken;
    property Account: string read FAccount;
  end;

var
  LoginForm: TLoginForm;

implementation

uses
  DateUtils, gboxgitrunner, gboxsuper;

  {$R *.lfm}

type
  { Runs the blocking token validation + keyring store off the GUI thread, so
    the dialog stays responsive (the HTTPS round-trip can take many seconds,
    especially over a remote link like x2go). The caller pumps the message loop
    while this runs, then reads the results. Both hosted backends come through
    here; only the client class and the credential key differ. }
  TValidateThread = class(TThread)
  private
    FKind: TBackendKind;
    FHost, FToken: string;
    FLogin, FErr, FAccount: string;
    FValidated, FSaved: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AKind: TBackendKind; const AHost, AToken: string);
    property Login: string read FLogin;
    property Err: string read FErr;
    property Account: string read FAccount;
    property Validated: Boolean read FValidated;
    property Saved: Boolean read FSaved;
  end;

constructor TValidateThread.Create(AKind: TBackendKind; const AHost, AToken: string);
begin
  FKind := AKind;
  FHost := AHost;
  FToken := AToken;
  FreeOnTerminate := False;   // caller reads results then frees us
  inherited Create(False);    // run now
end;

procedure TValidateThread.Execute;
var
  gh: TGitHubApi;
  gl: TGitLabApi;
  cred: TCredStore;
begin
  if FKind = bkGitLab then
  begin
    gl := TGitLabApi.Create(FToken, FHost);
    try
      FValidated := gl.ValidateToken(FLogin, FErr);
    finally
      gl.Free;
    end;
  end
  else
  begin
    gh := TGitHubApi.Create(FToken);
    try
      FValidated := gh.ValidateToken(FLogin, FErr);
    finally
      gh.Free;
    end;
  end;
  if not FValidated then Exit;
  // Persist the token in the OS credential store, keyed so that the same login
  // on another backend (or another GitLab host) cannot overwrite it.
  FAccount := CredKey(FKind, FHost, FLogin);
  cred := TCredStore.Create;
  try
    FSaved := cred.SaveToken(FAccount, FToken);
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
    FToken, FLogin, FErr, FAccount: string;
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
    property Account: string read FAccount;
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
  FAccount := CredKey(bkGitHub, '', FLogin);
  cred := TCredStore.Create;
  try
    FSaved := cred.SaveToken(FAccount, FToken);
  finally
    cred.Free;
  end;
  FStatus := psSuccess;
end;

{ ---- form ---- }

procedure TLoginForm.SetBusy(ABusy: Boolean);
begin
  if ABusy then Screen.Cursor := crHourGlass
  else
    Screen.Cursor := crDefault;
  btnDevice.Enabled := not ABusy;
  btnValidate.Enabled := not ABusy;
  btnTest.Enabled := not ABusy;
  btnCancel.Enabled := not ABusy;
  // a tab switch mid-validation would leave the result landing on the wrong
  // backend's fields
  pcBackend.Enabled := not ABusy;
end;

procedure TLoginForm.SetCode(const ACode: string);
begin
  eCode.Text := ACode;
  eCode.Enabled := ACode <> '';
  btnCopyCode.Enabled := eCode.Enabled;
end;

function TLoginForm.ActiveKind: TBackendKind;
begin
  if pcBackend.ActivePage = tsGitLab then Result := bkGitLab
  else if pcBackend.ActivePage = tsSelfHosted then Result := bkGit
  else if pcBackend.ActivePage = tsS3 then Result := bkS3
  else
    Result := bkGitHub;
end;

function TLoginForm.TabForKind(AKind: TBackendKind): TTabSheet;
begin
  case AKind of
    bkGitLab: Result := tsGitLab;
    bkGit: Result := tsSelfHosted;
    bkS3: Result := tsS3;
    else
      Result := tsGitHub;
  end;
end;

procedure TLoginForm.ApplyGhMethod;
var
  useDevice: Boolean;
begin
  useDevice := rgGhMethod.Visible and (rgGhMethod.ItemIndex = 0);
  // the two panels share one rect, so this is pure show/hide -- no geometry
  pnlDevice.Visible := useDevice;
  pnlPat.Visible := not useDevice;
  if (not useDevice) and pnlPat.Visible and pnlPat.CanFocus then
    ActiveControl := ePat;
  ApplyTab;
end;

procedure TLoginForm.ApplyTab;
var
  kind: TBackendKind;
  ghDevice: Boolean;
begin
  kind := ActiveKind;
  ghDevice := (kind = bkGitHub) and rgGhMethod.Visible and (rgGhMethod.ItemIndex = 0);

  // the device flow completes by itself, so it has no Save step -- and when a
  // credential is already loaded there is nothing to save either
  btnValidate.Visible := (not ghDevice) and (FState <> asSignedIn);
  if BackendNeedsToken(kind) then btnValidate.Caption := 'Validate && Save'
  else
    btnValidate.Caption := 'Save';
  // the caption changes width with the backend; keep the button's right edge
  // pinned next to Cancel rather than letting a long caption clip
  if BackendNeedsToken(kind) then btnValidate.Width := 140
  else
    btnValidate.Width := 90;
  btnValidate.Left := btnCancel.Left - btnValidate.Width - 8;
  // only the backends we can probe cheaply offer a test
  btnTest.Visible := (kind in [bkGit, bkS3]) and (FState <> asSignedIn);
  btnTest.Left := btnValidate.Left - btnTest.Width - 8;
  btnValidate.Enabled := not ((kind = bkS3) and not FS3Ready);
  btnTest.Enabled := btnValidate.Enabled;

  if btnValidate.Visible then DefaultControl := btnValidate
  else
    DefaultControl := btnDevice;
end;

procedure TLoginForm.ApplyState;
var
  k: TBackendKind;
  ts: TTabSheet;
begin
  if FState <> asFresh then
    pcBackend.ActivePage := TabForKind(FLockKind);

  // Fresh: every backend is on the table. Otherwise this folder already belongs
  // to one, and the others are shown greyed rather than hidden, so it is obvious
  // which backend is in use instead of looking like the only one that exists.
  for k := Low(TBackendKind) to High(TBackendKind) do
  begin
    ts := TabForKind(k);
    if Assigned(ts) then ts.Enabled := (FState = asFresh) or (k = FLockKind);
  end;

  // Signed in: there is nothing to fill in and no Save. Disabling the whole page
  // control also greys the tab bar, which is the clearest way to say "this is
  // settled" -- and pcBackendChanging refuses the switch regardless.
  pcBackend.Enabled := FState <> asSignedIn;

  btnSignOut.Visible := FState = asSignedIn;
  lblSignedIn.Visible := FState = asSignedIn;
  if FState = asSignedIn then
  begin
    lblSignedIn.Caption := 'Signed in - ' + BackendSummary(FCfg);
    lblSignedIn.Left := btnSignOut.Left + btnSignOut.Width + 12;
  end;
  ApplyTab;
end;

procedure TLoginForm.btnSignOutClick(Sender: TObject);
var
  cred: TCredStore;
  acct: string;
begin
  if MessageDlg('Sign out', 'Sign out of ' + BackendSummary(FCfg) +
    '?' + LineEnding + LineEnding +
    'The stored token is deleted from your keyring and syncing stops until you ' +
    'sign in again. Your synced folder and its history are untouched, and this ' +
    'folder stays on ' + BackendLabel(FLockKind) + '.', mtConfirmation,
    [mbYes, mbNo], 0) <> mrYes then Exit;

  acct := CredAccount(FCfg);
  if acct <> '' then
  begin
    cred := TCredStore.Create;
    try
      if not cred.DeleteToken(acct) then
        if Assigned(Log) then
          Log.Warn('login', 'could not delete the stored token for ' + acct);
    finally
      cred.Free;
    end;
  end;
  if Assigned(Log) then Log.Info('login', 'signed out of ' + BackendLabel(FLockKind));

  // stay open on the same backend so the user can sign straight back in; the
  // backend itself is not up for grabs here (see ApplyState)
  FState := asPinnedSignedOut;
  ApplyState;
end;

procedure TLoginForm.pcBackendChange(Sender: TObject);
begin
  ApplyTab;
end;

procedure TLoginForm.pcBackendChanging(Sender: TObject; var AllowChange: Boolean);
begin
  // a sign-in is in flight on this tab; its result must not land elsewhere
  AllowChange := not FDevPolling;
  // and once the folder belongs to a backend, it is not re-chosen here: the
  // window is already sitting on the locked tab, so any change is a switch away
  // from it. Disabling the other sheets greys them; this is what stops the click.
  if FState <> asFresh then AllowChange := False;
end;

procedure TLoginForm.rgGhMethodClick(Sender: TObject);
begin
  ApplyGhMethod;
end;

procedure TLoginForm.btnCopyCodeClick(Sender: TObject);
begin
  if eCode.Text = '' then Exit;
  Clipboard.AsText := eCode.Text;
  eCode.SelectAll;
end;

procedure TLoginForm.btnBrowseBaseClick(Sender: TObject);
var
  dir: string;
begin
  dir := Trim(eSshBase.Text);
  if (dir = '') or not DirectoryExists(dir) then dir := GetUserDir;
  if SelectDirectory('Folder to keep the repositories in', dir, dir) then
    eSshBase.Text := dir;
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
  err, login, tok, acct: string;
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
    'Enter the code above at ' + dev.VerificationUri + LineEnding +
    LineEnding + 'It is already on your clipboard and that page should be open in your '
    +
    'browser; if it is not, open the address by hand.' + LineEnding +
    LineEnding + 'Then authorize GotBox -- this window finishes the sign-in by itself. The '
    + 'code expires in about ' + IntToStr(dev.ExpiresIn div 60) + ' minutes.';
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
    acct := th.Account;
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
      FAccount := acct;
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

procedure TLoginForm.DoTokenValidate(AKind: TBackendKind; const AHost, AToken: string);
var
  th: TValidateThread;
  login, err, acct: string;
  okValidated, okSaved: Boolean;
begin
  // Validate against the server (blocking HTTPS) + save to the keyring on a
  // worker thread; pump events here so the window doesn't freeze / show
  // "not responding".
  SetBusy(True);
  th := TValidateThread.Create(AKind, AHost, AToken);
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
    acct := th.Account;
    err := th.Err;
  finally
    th.Free;
    SetBusy(False);
  end;

  if not okValidated then
  begin
    MsgError('Could not validate the ' + BackendLabel(AKind) +
      ' token:' + LineEnding + err);
    Exit;
  end;

  // the server tells us the canonical login; trust it over the typed value
  if AKind = bkGitLab then eGlUser.Text := login
  else
    eUser.Text := login;
  FToken := AToken;
  FAccount := acct;
  if not okSaved then
    MsgError('Token validated but could not be saved to the credential store.');

  if Assigned(Log) then
    Log.Info('login', BackendLabel(AKind) + ' token validated for ' + login);
  ModalResult := mrOK;
end;

function TLoginForm.ValidateActiveTab: Boolean;
var
  base: string;
  hostArg, port, path: string;
begin
  Result := False;
  case ActiveKind of
    bkGitHub:
      if Trim(ePat.Text) = '' then
      begin
        MsgInfo('Please enter a Personal Access Token (scope: repo).');
        ActiveControl := ePat;
        Exit;
      end;
    bkGitLab:
    begin
      if Trim(eGlHost.Text) = '' then
      begin
        MsgInfo('Please enter the GitLab server address.');
        ActiveControl := eGlHost;
        Exit;
      end;
      if Trim(eGlPat.Text) = '' then
      begin
        MsgInfo('Please enter a GitLab Personal Access Token (scope: api).');
        ActiveControl := eGlPat;
        Exit;
      end;
    end;
    bkGit:
    begin
      base := Trim(eSshBase.Text);
      if base = '' then
      begin
        MsgInfo('Please enter an ssh:// base URL or pick a folder.');
        ActiveControl := eSshBase;
        Exit;
      end;
      // saving needs no network, but a value that is neither an ssh target nor
      // an existing folder is almost certainly a typo
      if (not ParseSshTarget(base, hostArg, port, path)) and
        (not DirectoryExists(base)) and (Pos('@', base) = 0) then
        if not MsgConfirm('"' + base + '" is not an ssh URL and does not ' +
          'exist as a folder.' + LineEnding + LineEnding + 'Save it anyway?') then
        begin
          ActiveControl := eSshBase;
          Exit;
        end;
    end;
    bkS3:
    begin
      if not FS3Ready then
      begin
        MsgInfo(S3_HELPER_MISSING_MSG);
        Exit;
      end;
      base := LowerCase(Trim(eS3Base.Text));
      if Copy(base, 1, 5) <> 's3://' then
      begin
        MsgInfo('The bucket must look like s3://my-bucket/optional-prefix.');
        ActiveControl := eS3Base;
        Exit;
      end;
    end;
  end;
  Result := True;
end;

procedure TLoginForm.btnValidateClick(Sender: TObject);
begin
  if not ValidateActiveTab then Exit;
  case ActiveKind of
    bkGitHub: DoTokenValidate(bkGitHub, '', Trim(ePat.Text));
    bkGitLab: DoTokenValidate(bkGitLab, Trim(eGlHost.Text), Trim(eGlPat.Text));
    else
      ModalResult := mrOK;   // keyless backends have nothing to check remotely
  end;
end;

procedure TLoginForm.btnTestClick(Sender: TObject);
var
  git: TGitRunner;
  env: TStringList;
  prov: TS3Provider;
  url: string;
  ok: Boolean;
begin
  if not ValidateActiveTab then Exit;
  SetBusy(True);
  env := TStringList.Create;
  git := TGitRunner.Create('');
  try
    if ActiveKind = bkS3 then
    begin
      prov := TS3Provider.Create(Trim(eS3Base.Text), Trim(eS3Profile.Text),
        Trim(eS3Region.Text));
      try
        url := prov.PushUrl(GOTBOX_REPO);
        prov.GetRunnerEnv(env);
      finally
        prov.Free;
      end;
      git.SetExtraEnv(env);
    end
    else
      url := JoinRemote(Trim(eSshBase.Text), GOTBOX_REPO + '.git');
    // ls-remote on a repo that need not exist: we are testing reachability and
    // credentials, and "not found" still proves we got there
    ok := git.Git(['ls-remote', url]).Ok;
  finally
    git.Free;
    env.Free;
    SetBusy(False);
  end;

  if ok then
    MsgInfo('Reached ' + url + ' successfully.')
  else
    MsgError('Could not reach ' + url + '.' + LineEnding + LineEnding +
      'For a self-hosted server, check the address and that your ssh key ' +
      'works. For S3, check the bucket name, your AWS profile and that the ' +
      'bucket exists.');
end;

procedure TLoginForm.lnkTokenClick(Sender: TObject);
begin
  OpenURL('https://github.com/settings/tokens/new?scopes=repo&description=GotBox');
end;

procedure TLoginForm.lnkGlTokenClick(Sender: TObject);
var
  host: string;
begin
  host := Trim(eGlHost.Text);
  if host = '' then host := GITLAB_DEFAULT_HOST;
  if Pos('://', host) = 0 then host := 'https://' + host;
  while (host <> '') and (host[Length(host)] = '/') do
    SetLength(host, Length(host) - 1);
  OpenURL(host + '/-/user_settings/personal_access_tokens');
end;

procedure TLoginForm.LoadFromConfig(ACfg: TGotConfig);
var
  helper, tok: string;
  cred: TCredStore;
  hasToken: Boolean;
begin
  FCfg := ACfg;
  // Ask the keyring what it actually holds. The window used to assume nobody was
  // signed in every time it opened, which is why it offered four backends to a
  // user who was already syncing on one of them.
  hasToken := False;
  if BackendNeedsToken(ParseBackendKind(ACfg.RemoteKind)) and
    (CredAccount(ACfg) <> '') then
  begin
    cred := TCredStore.Create;
    try
      hasToken := cred.LoadToken(CredAccount(ACfg), tok);
    finally
      cred.Free;
    end;
  end;
  FLockKind := ParseBackendKind(ACfg.RemoteKind);
  FState := AccountStateOf(ACfg, hasToken);

  // GitHub
  eUser.Text := ACfg.RemoteUser;
  ePat.Text := '';
  SetCode('');
  mDevMsg.Lines.Text := 'Press "Sign in with GitHub" to get a one-time code. ' +
    'GotBox copies it to the clipboard and opens the GitHub page where you ' +
    'paste it; no token to create by hand.';
  // device-flow sign-in only when a client id is configured; without one the
  // tab is the plain manual-PAT form (Height 0 reclaims the space with no
  // arithmetic of our own -- the layout engine does it)
  rgGhMethod.Visible := OAuthAvailable;
  rgGhMethod.ItemIndex := 0;
  if OAuthAvailable then rgGhMethod.Height := 52
  else
    rgGhMethod.Height := 0;

  // GitLab
  if ACfg.GitLabHost <> '' then eGlHost.Text := ACfg.GitLabHost
  else
    eGlHost.Text := GITLAB_DEFAULT_HOST;
  eGlNs.Text := ACfg.GitLabNamespace;
  eGlPat.Text := '';
  if ParseBackendKind(ACfg.RemoteKind) = bkGitLab then eGlUser.Text := ACfg.RemoteUser
  else
    eGlUser.Text := '';
  mGlMsg.Lines.Text :=
    'GotBox creates one private project per synced folder and pushes over ' +
    'HTTPS with this token. The token goes into your OS keyring, never into ' +
    'the config file or a remote URL.' + LineEnding + LineEnding +
    'Browser sign-in (device flow) is GitHub-only for now.';

  // self-hosted
  eSshBase.Text := ACfg.SshBase;
  mSshHelp.Lines.Text :=
    'Examples:  ssh://git@server.example.edu/srv/git   |   ' +
    'git@server:srv/git   |   /mnt/backup/git' + LineEnding +
    LineEnding + 'GotBox authenticates with your existing ssh keys, so there is nothing to '
    + 'store in the keyring. A missing repository is created on the server with ' +
    '`git init --bare`.';

  // S3
  eS3Base.Text := ACfg.S3Base;
  eS3Profile.Text := ACfg.AwsProfile;
  eS3Region.Text := ACfg.AwsRegion;
  helper := S3HelperPath;
  FS3Ready := helper <> '';
  if FS3Ready then lblS3Helper.Caption := 'git-remote-s3: found at ' + helper
  else
    lblS3Helper.Caption := 'git-remote-s3: NOT FOUND on PATH. Install it to ' +
      'use the S3 backend.';
  eS3Base.Enabled := FS3Ready;
  eS3Profile.Enabled := FS3Ready;
  eS3Region.Enabled := FS3Ready;
  mS3Help.Lines.Text :=
    'S3 is reached through the git-remote-s3 helper (git itself has no S3 ' +
    'transport). Install it with:  pipx install git-remote-s3' +
    LineEnding + LineEnding +
    'Credentials come from your AWS profile or environment -- GotBox stores ' +
    'no AWS keys. The bucket must already exist. Note that GotBox polls S3 at ' +
    'most once a minute, so changes from another machine can take that long ' +
    'to appear.';

  pcBackend.ActivePage := TabForKind(ParseBackendKind(ACfg.RemoteKind));
end;

procedure TLoginForm.SaveToConfig(ACfg: TGotConfig);
var
  s: string;
begin
  // Only the active tab's settings are written, but the other tabs' values are
  // left alone in the config, so switching back and forth does not lose them.
  case ActiveKind of
    bkGitHub:
    begin
      ACfg.RemoteKind := 'github';
      ACfg.RemoteUser := Trim(eUser.Text);
    end;
    bkGitLab:
    begin
      ACfg.RemoteKind := 'gitlab';
      ACfg.RemoteUser := Trim(eGlUser.Text);
      s := Trim(eGlHost.Text);
      if (s <> '') and (Pos('://', s) = 0) then s := 'https://' + s;
      while (s <> '') and (s[Length(s)] = '/') do
        SetLength(s, Length(s) - 1);
      ACfg.GitLabHost := s;
      ACfg.GitLabNamespace := Trim(eGlNs.Text);
    end;
    bkGit:
    begin
      ACfg.RemoteKind := 'git';
      s := Trim(eSshBase.Text);
      while (Length(s) > 1) and (s[Length(s)] = '/') do
        SetLength(s, Length(s) - 1);
      ACfg.SshBase := s;
    end;
    bkS3:
    begin
      ACfg.RemoteKind := 's3';
      s := Trim(eS3Base.Text);
      while (Length(s) > 5) and (s[Length(s)] = '/') do
        SetLength(s, Length(s) - 1);
      ACfg.S3Base := s;
      ACfg.AwsProfile := Trim(eS3Profile.Text);
      ACfg.AwsRegion := Trim(eS3Region.Text);
    end;
  end;
end;

function TLoginForm.RunLogin(ACfg: TGotConfig): Boolean;
begin
  Result := False;
  if Visible then begin
    BringToFront;
    Exit;
  end;
  FToken := '';
  FAccount := '';
  FDevCancelled := False;
  FCloseAfterCancel := False;
  LoadFromConfig(ACfg);
  ApplyGhMethod;   // also calls ApplyTab
  ApplyState;      // ... which ApplyState then overrides to suit the state
  CenterForm(Self);
  Result := ShowModal = mrOK;
  if Result then SaveToConfig(ACfg);
end;

end.
