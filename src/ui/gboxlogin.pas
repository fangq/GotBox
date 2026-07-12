unit gboxlogin;

{ GitHub account window: capture username + Personal Access Token, validate the
  token, and (from M2 onward) persist the PAT into the OS credential store.
  In M1 the validation is a stub and only the username is saved to config. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Dialogs, LCLIntf, Graphics,
  gboxconfigstore, gboxcredstore, gboxgithubapi, gboxlog, gboxmsg;

type
  TLoginForm = class(TForm)
    lblUser: TLabel;
    eUser: TEdit;
    lblPat: TLabel;
    ePat: TEdit;
    lblHint: TLabel;
    lnkToken: TLabel;
    btnValidate: TButton;
    btnCancel: TButton;
    procedure btnValidateClick(Sender: TObject);
    procedure lnkTokenClick(Sender: TObject);
  private
    FToken: string;
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

{$R *.lfm}

procedure TLoginForm.btnValidateClick(Sender: TObject);
var
  api: TGitHubApi;
  cred: TCredStore;
  login, err: string;
begin
  if Trim(ePat.Text) = '' then
  begin
    MsgInfo('Please enter a Personal Access Token (scope: repo).');
    Exit;
  end;

  // Validate the token against GitHub (blocking, but a one-off action).
  Screen.Cursor := crHourGlass;
  btnValidate.Enabled := False;
  try
    api := TGitHubApi.Create(Trim(ePat.Text));
    try
      if not api.ValidateToken(login, err) then
      begin
        MsgError('Could not validate token:' + LineEnding + err);
        Exit;
      end;
    finally
      api.Free;
    end;
  finally
    btnValidate.Enabled := True;
    Screen.Cursor := crDefault;
  end;

  // GitHub tells us the canonical login name; trust it over the typed value.
  eUser.Text := login;
  FToken := Trim(ePat.Text);

  // Persist the token in the OS credential store keyed by login.
  cred := TCredStore.Create;
  try
    if not cred.SaveToken(login, FToken) then
      MsgError('Token validated but could not be saved to the credential store.');
  finally
    cred.Free;
  end;

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
  CenterForm(Self);
  Result := ShowModal = mrOK;
  if Result then
    ACfg.GithubUser := Trim(eUser.Text);
end;

end.
