unit gboxremote;

{ Abstracts where repos live so GotBox can back folders with either GitHub
  (HTTPS + PAT, repos auto-created via the REST API) or a self-maintained git
  server reached over ssh:// (or a plain filesystem / file:// path). For the
  generic backend, a missing repo is created with `git init --bare` -- over ssh
  for ssh targets, locally for path targets. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxgitrunner, gboxgithubapi, gboxconfigstore;

type
  TEnsureRemote = (erExists, erCreated, erError);

  TRemoteProvider = class
  public
    { URL used for clone/push (may embed the user for https). }
    function PushUrl(const AName: string): string; virtual; abstract;
    { URL stored in config / shown to the user (no secrets). }
    function DisplayUrl(const AName: string): string; virtual; abstract;
    { Make sure the remote repo exists, creating it when possible. }
    function EnsureRemote(const AName: string; out ADetail: string): TEnsureRemote;
      virtual; abstract;
    function AuthUser: string; virtual;
    function AuthToken: string; virtual;
  end;

  TGitHubProvider = class(TRemoteProvider)
  private
    FUser, FToken: string;
  public
    constructor Create(const AUser, AToken: string);
    function PushUrl(const AName: string): string; override;
    function DisplayUrl(const AName: string): string; override;
    function EnsureRemote(const AName: string; out ADetail: string): TEnsureRemote;
      override;
    function AuthUser: string; override;
    function AuthToken: string; override;
  end;

  { Generic git backend: ssh://, scp-like user@host:path, or a filesystem path. }
  TGitProvider = class(TRemoteProvider)
  private
    FBase: string;
  public
    constructor Create(const ABase: string);
    function PushUrl(const AName: string): string; override;
    function DisplayUrl(const AName: string): string; override;
    function EnsureRemote(const AName: string; out ADetail: string): TEnsureRemote;
      override;
  end;

{ Builds the provider for a config (token only needed for the github kind). }
function MakeProvider(ACfg: TGotConfig; const AToken: string): TRemoteProvider;

{ Joins a base remote and a leaf, inserting a single separator. }
function JoinRemote(const ABase, ALeaf: string): string;

{ Splits an ssh remote into the ssh host argument and the remote path.
  Handles ssh://[user@]host[:port]/path and scp-like [user@]host:path.
  Returns False for non-ssh (filesystem / file://) targets. }
function ParseSshTarget(const AUrl: string; out AHostArg, APort, APath: string): Boolean;

implementation

uses
  Process, gboxlog;

function TRemoteProvider.AuthUser: string;
begin
  Result := '';
end;

function TRemoteProvider.AuthToken: string;
begin
  Result := '';
end;

{ ---- helpers ---- }

function JoinRemote(const ABase, ALeaf: string): string;
var
  b: string;
begin
  b := ABase;
  if (b <> '') and (b[Length(b)] in ['/', ':']) then
    Result := b + ALeaf
  else
    Result := b + '/' + ALeaf;
end;

function ParseSshTarget(const AUrl: string; out AHostArg, APort, APath: string): Boolean;
var
  rest, hostpart: string;
  p: Integer;
begin
  AHostArg := '';
  APort := '';
  APath := '';
  Result := False;

  if Copy(AUrl, 1, 6) = 'ssh://' then
  begin
    rest := Copy(AUrl, 7, MaxInt);              // [user@]host[:port]/path
    p := Pos('/', rest);
    if p = 0 then Exit;                         // no path
    hostpart := Copy(rest, 1, p - 1);
    APath := Copy(rest, p, MaxInt);             // keep leading '/'
    p := Pos(':', hostpart);
    if p > 0 then
    begin
      APort := Copy(hostpart, p + 1, MaxInt);
      AHostArg := Copy(hostpart, 1, p - 1);
    end
    else
      AHostArg := hostpart;
    Result := AHostArg <> '';
    Exit;
  end;

  // scp-like: [user@]host:path  (':' present, before any '/', and not file://)
  if (Pos('://', AUrl) = 0) then
  begin
    p := Pos(':', AUrl);
    if (p > 1) and ((Pos('/', AUrl) = 0) or (Pos('/', AUrl) > p)) then
    begin
      AHostArg := Copy(AUrl, 1, p - 1);
      APath := Copy(AUrl, p + 1, MaxInt);
      // a Windows drive letter ("C:\...") is not an ssh host
      Result := (Length(AHostArg) > 1) and (APath <> '');
    end;
  end;
end;

{ Runs an arbitrary command, returning its exit code. }
function RunCmd(const AExe: string; const AArgs: array of string): Integer;
var
  proc: TProcess;
  i: Integer;
begin
  Result := -1;
  proc := TProcess.Create(nil);
  try
    proc.Executable := AExe;
    for i := 0 to High(AArgs) do
      proc.Parameters.Add(AArgs[i]);
    proc.Options := [poWaitOnExit, poNoConsole, poUsePipes];
    try
      proc.Execute;
      Result := proc.ExitStatus;
    except
      Result := -2;
    end;
  finally
    proc.Free;
  end;
end;

{ ---- TGitHubProvider ---- }

constructor TGitHubProvider.Create(const AUser, AToken: string);
begin
  inherited Create;
  FUser := AUser;
  FToken := AToken;
end;

function TGitHubProvider.PushUrl(const AName: string): string;
begin
  // user in the URL so git only ever asks for the password (the token)
  Result := Format('https://%s@github.com/%s/%s.git', [FUser, FUser, AName]);
end;

function TGitHubProvider.DisplayUrl(const AName: string): string;
begin
  Result := Format('https://github.com/%s/%s.git', [FUser, AName]);
end;

function TGitHubProvider.EnsureRemote(const AName: string;
  out ADetail: string): TEnsureRemote;
var
  api: TGitHubApi;
  cloneUrl, err: string;
begin
  ADetail := '';
  api := TGitHubApi.Create(FToken);
  try
    if api.RepoExists(FUser, AName) then Exit(erExists);
    if api.CreatePrivateRepo(AName, cloneUrl, err) then Exit(erCreated);
    ADetail := 'create failed: ' + err;
    Result := erError;
  finally
    api.Free;
  end;
end;

function TGitHubProvider.AuthUser: string;
begin
  Result := FUser;
end;

function TGitHubProvider.AuthToken: string;
begin
  Result := FToken;
end;

{ ---- TGitProvider ---- }

constructor TGitProvider.Create(const ABase: string);
begin
  inherited Create;
  FBase := ABase;
end;

function TGitProvider.PushUrl(const AName: string): string;
begin
  Result := JoinRemote(FBase, AName + '.git');
end;

function TGitProvider.DisplayUrl(const AName: string): string;
begin
  Result := PushUrl(AName);
end;

function TGitProvider.EnsureRemote(const AName: string;
  out ADetail: string): TEnsureRemote;
var
  url, hostArg, port, path, localPath: string;
  git: TGitRunner;
  rc: Integer;
begin
  ADetail := '';
  url := PushUrl(AName);

  // already there?
  git := TGitRunner.Create('');
  try
    if git.Git(['ls-remote', url]).Ok then Exit(erExists);
  finally
    git.Free;
  end;

  // create it
  if ParseSshTarget(url, hostArg, port, path) then
  begin
    if port <> '' then
      rc := RunCmd('ssh', ['-p', port, '-oBatchMode=yes',
        '-oStrictHostKeyChecking=accept-new', hostArg, 'git',
        'init', '--bare', path])
    else
      rc := RunCmd('ssh', ['-oBatchMode=yes', '-oStrictHostKeyChecking=accept-new',
        hostArg, 'git', 'init', '--bare', path]);
    if rc = 0 then Exit(erCreated);
    ADetail := Format('ssh create failed (rc=%d) for %s', [rc, url]);
    Exit(erError);
  end;

  // filesystem / file:// path -> create a local bare repo
  localPath := url;
  if Copy(localPath, 1, 7) = 'file://' then localPath := Copy(localPath, 8, MaxInt);
  git := TGitRunner.Create('');
  try
    if git.Git(['init', '--bare', localPath]).Ok then Exit(erCreated);
  finally
    git.Free;
  end;
  ADetail := 'could not create remote ' + url;
  Result := erError;
end;

{ ---- factory ---- }

function MakeProvider(ACfg: TGotConfig; const AToken: string): TRemoteProvider;
begin
  if SameText(ACfg.RemoteKind, 'git') then
    Result := TGitProvider.Create(ACfg.SshBase)
  else
    Result := TGitHubProvider.Create(ACfg.GithubUser, AToken);
end;

end.
