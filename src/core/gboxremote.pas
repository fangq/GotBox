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

unit gboxremote;

{ Abstracts where repos live, so a synced folder can be backed by any of:
    github -- HTTPS + token, repos auto-created via the REST API
    gitlab -- the same, on gitlab.com or a self-managed instance
    git    -- a self-maintained server over ssh:// (or a filesystem / file://
              path); a missing repo is created with `git init --bare`, over ssh
              for ssh targets and locally for path targets
    s3     -- a bucket, via the third-party git-remote-s3 helper

  Besides the providers, this unit answers the two questions every caller has
  about the configured backend -- "can I use it, and with what token?"
  (ResolveRemoteAuth) and "what do I call it?" (BackendSummary) -- so the GUI
  and the headless daemon cannot drift apart. Per-backend *policy* that the
  sync engine needs (push limits, LFS, poll floors, credential keys) lives in
  gboxbackend, which has no HTTP dependency. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxgitrunner, gboxgithubapi, gboxgitlabapi, gboxbackend,
  gboxcredstore, gboxconfigstore;

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
    { Non-creating existence check. }
    function RemoteExists(const AName: string): Boolean; virtual; abstract;
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
    function RemoteExists(const AName: string): Boolean; override;
    function AuthUser: string; override;
    function AuthToken: string; override;
  end;

  { GitLab, on gitlab.com or a self-managed instance. HTTPS + PAT, projects
    auto-created via the REST v4 API. }
  TGitLabProvider = class(TRemoteProvider)
  private
    FHost, FNamespace, FUser, FToken: string;
    FTokenKind: TGitLabTokenKind;
    function Owner: string;
  public
    constructor Create(const AHost, ANamespace, AUser, AToken: string;
      ATokenKind: TGitLabTokenKind = tkPat);
    function PushUrl(const AName: string): string; override;
    function DisplayUrl(const AName: string): string; override;
    function EnsureRemote(const AName: string; out ADetail: string): TEnsureRemote;
      override;
    function RemoteExists(const AName: string): Boolean; override;
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
    function RemoteExists(const AName: string): Boolean; override;
  end;

  { An S3 bucket, reached through the third-party git-remote-s3 helper: git
    itself has no S3 transport, so `s3://bucket/prefix/name` only resolves when
    that helper is on the git child's PATH. The bucket must already exist --
    GotBox has no S3 API client and cannot create one. Credentials come from
    the ambient AWS chain (profile / environment / SSO), never from GotBox. }
  TS3Provider = class(TRemoteProvider)
  private
    FBase, FProfile, FRegion: string;
  public
    constructor Create(const ABase, AProfile, ARegion: string);
    function PushUrl(const AName: string): string; override;
    function DisplayUrl(const AName: string): string; override;
    function EnsureRemote(const AName: string; out ADetail: string): TEnsureRemote;
      override;
    function RemoteExists(const AName: string): Boolean; override;
    { 'NAME=VALUE' entries a git child needs to reach the helper and the bucket.
      Nothing secret: a profile name, a region, and a PATH that includes the
      helper's directory. }
    procedure GetRunnerEnv(AOut: TStrings);
  end;

{ Builds the provider for a config (token only needed for the hosted kinds). }
function MakeProvider(ACfg: TGotConfig; const AToken: string): TRemoteProvider;

{ Absolute path to the git-remote-s3 helper, or '' when it is not installed.
  Looks beyond PATH because `pip install --user` drops it in ~/.local/bin, which
  a desktop-launched GUI often does not inherit -- and git resolves remote
  helpers from PATH only, so we have to put it there ourselves.
  GOTBOX_S3_HELPER overrides the search (tests point it at a stub). }
function S3HelperPath: string;

{ The credential-store account key for this config ('' when the backend keeps
  no token). }
function CredAccount(ACfg: TGotConfig): string;
{ The username a TGitRunner should authenticate as ('' for keyless backends). }
function RemoteAuthUser(ACfg: TGotConfig): string;
{ One line describing the configured backend, for Settings and the log. }
function BackendSummary(ACfg: TGotConfig): string;

{ Fills AOut with the 'NAME=VALUE' entries a git child needs for this config's
  backend (empty for everything but S3). }
procedure CollectRemoteEnv(ACfg: TGotConfig; AOut: TStrings);

{ What the Account window should let the user do.

  The window used to present all four backends as equals every time it opened,
  even when a token from the keyring was already signing the user in. Two things
  were wrong with that. It said "signed out" when the user was signed in, and it
  let a GitLab PAT be typed while GitHub was live -- which only rewrites
  RemoteKind, so the next reconcile re-points the root at the new backend while
  every linked submodule keeps its old URL. A folder split across two backends
  is not a state GotBox can sync out of.

  So the window has three states, and the backend can only be chosen in the
  first of them:

    asFresh            no account configured yet -- pick any backend.
    asPinnedSignedOut  this folder belongs to a backend, but the token is gone
                       (expired, revoked, keyring cleared). Re-authenticate THAT
                       backend; the others stay visible but disabled.
    asSignedIn         a usable credential is loaded. Nothing to fill in, and
                       the only action is signing out.

  AHasToken is passed in rather than read here so this stays a pure decision the
  tests can drive; the caller has already asked the credential store (see
  ResolveRemoteAuth). It is ignored for the keyless backends, which are "signed
  in" exactly when they are configured. }
type
  TAccountState = (asFresh, asPinnedSignedOut, asSignedIn);

function AccountStateOf(ACfg: TGotConfig; AHasToken: Boolean): TAccountState;

{ Checks that the configured backend is usable and returns its auth token
  (empty for the keyless backends). The single place every backend's
  preconditions live: the GUI (PrepareRemote) and the headless daemon
  (ResolveRemote) both defer to it. }
function ResolveRemoteAuth(ACfg: TGotConfig; out AToken, AErr: string): Boolean;

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

function TGitHubProvider.RemoteExists(const AName: string): Boolean;
var
  api: TGitHubApi;
begin
  api := TGitHubApi.Create(FToken);
  try
    Result := api.RepoExists(FUser, AName);
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

  if RemoteExists(AName) then Exit(erExists);

  // create it
  if ParseSshTarget(url, hostArg, port, path) then
  begin
    // default branch main so the repo is usable as a submodule upstream
    if port <> '' then
      rc := RunCmd('ssh', ['-p', port, '-oBatchMode=yes',
        '-oStrictHostKeyChecking=accept-new', hostArg, 'git',
        'init', '--bare', '-b', 'main', path])
    else
      rc := RunCmd('ssh', ['-oBatchMode=yes', '-oStrictHostKeyChecking=accept-new',
        hostArg, 'git', 'init', '--bare', '-b', 'main', path]);
    if rc = 0 then Exit(erCreated);
    ADetail := Format('ssh create failed (rc=%d) for %s', [rc, url]);
    Exit(erError);
  end;

  // filesystem / file:// path -> create a local bare repo
  localPath := url;
  if Copy(localPath, 1, 7) = 'file://' then localPath := Copy(localPath, 8, MaxInt);
  git := TGitRunner.Create('');
  try
    if git.Git(['init', '--bare', '-b', 'main', localPath]).Ok then Exit(erCreated);
  finally
    git.Free;
  end;
  ADetail := 'could not create remote ' + url;
  Result := erError;
end;

function TGitProvider.RemoteExists(const AName: string): Boolean;
var
  git: TGitRunner;
begin
  git := TGitRunner.Create('');
  try
    Result := git.Git(['ls-remote', PushUrl(AName)]).Ok;
  finally
    git.Free;
  end;
end;

{ ---- TGitLabProvider ---- }

constructor TGitLabProvider.Create(const AHost, ANamespace, AUser, AToken: string;
  ATokenKind: TGitLabTokenKind);
begin
  inherited Create;
  FHost := AHost;
  if FHost = '' then FHost := GITLAB_DEFAULT_HOST;
  FNamespace := ANamespace;
  FUser := AUser;
  FToken := AToken;
  FTokenKind := ATokenKind;
end;

{ The project's namespace: an explicit group, else the signed-in user. }
function TGitLabProvider.Owner: string;
begin
  if FNamespace <> '' then Result := FNamespace
  else
    Result := FUser;
end;

function TGitLabProvider.PushUrl(const AName: string): string;
begin
  // Username in the URL, token supplied by GIT_ASKPASS -- same trick as GitHub,
  // so no secret is ever written into a remote URL. GitLab accepts any username
  // with a PAT as the password; an OAuth token wants the literal 'oauth2'.
  Result := InsertUrlUser(DisplayUrl(AName), AuthUser);
end;

function TGitLabProvider.DisplayUrl(const AName: string): string;
var
  host: string;
begin
  host := FHost;
  while (host <> '') and (host[Length(host)] = '/') do
    SetLength(host, Length(host) - 1);
  Result := JoinRemote(host, Owner + '/' + AName + '.git');
end;

function TGitLabProvider.EnsureRemote(const AName: string;
  out ADetail: string): TEnsureRemote;
var
  api: TGitLabApi;
  httpUrl, err: string;
  existed: Boolean;
begin
  ADetail := '';
  api := TGitLabApi.Create(FToken, FHost, FTokenKind);
  try
    if api.RepoExists(Owner, AName) then Exit(erExists);
    if api.CreatePrivateRepo(Owner, AName, httpUrl, err, existed) then
    begin
      // "already taken" means another machine got there first; it may already
      // hold commits, so it must not be treated as a fresh repo to seed
      if existed then Exit(erExists);
      Exit(erCreated);
    end;
    ADetail := 'create failed: ' + err;
    Result := erError;
  finally
    api.Free;
  end;
end;

function TGitLabProvider.RemoteExists(const AName: string): Boolean;
var
  api: TGitLabApi;
begin
  api := TGitLabApi.Create(FToken, FHost, FTokenKind);
  try
    Result := api.RepoExists(Owner, AName);
  finally
    api.Free;
  end;
end;

function TGitLabProvider.AuthUser: string;
begin
  if FTokenKind = tkOAuth then Result := 'oauth2'
  else
    Result := FUser;
end;

function TGitLabProvider.AuthToken: string;
begin
  Result := FToken;
end;

{ ---- TS3Provider ---- }

function S3HelperPath: string;
  {$IFDEF WINDOWS}
const
  EXE = S3_HELPER_EXE + '.exe';
  {$ELSE}
const
  EXE = S3_HELPER_EXE;
  {$ENDIF}
var
  home, cand: string;
  dirs: array of string;
  i: Integer;
begin
  Result := GetEnvironmentVariable('GOTBOX_S3_HELPER');
  if Result <> '' then
  begin
    if not FileExists(Result) then Result := '';
    Exit;
  end;
  Result := FileSearch(EXE, GetEnvironmentVariable('PATH'));
  if Result <> '' then Exit;
  // pip/pipx install locations a GUI session's PATH commonly misses
  home := GetEnvironmentVariable(
    {$IFDEF WINDOWS}
'USERPROFILE'
    {$ELSE}
    'HOME'
    {$ENDIF}
    );
  dirs := [];
  {$IFDEF WINDOWS}
  if GetEnvironmentVariable('APPDATA') <> '' then
    dirs := [GetEnvironmentVariable('APPDATA') + '\Python\Scripts'];
  {$ELSE}
  if home <> '' then
    dirs := [home + '/.local/bin', home + '/.local/pipx/venvs/git-remote-s3/bin'];
  dirs := Concat(dirs, ['/usr/local/bin', '/opt/homebrew/bin']);
  {$ENDIF}
  for i := 0 to High(dirs) do
  begin
    cand := IncludeTrailingPathDelimiter(dirs[i]) + EXE;
    if FileExists(cand) then Exit(cand);
  end;
  Result := '';
end;

constructor TS3Provider.Create(const ABase, AProfile, ARegion: string);
begin
  inherited Create;
  FBase := ABase;
  while (FBase <> '') and (FBase[Length(FBase)] = '/') do
    SetLength(FBase, Length(FBase) - 1);
  FProfile := AProfile;
  FRegion := ARegion;
end;

function TS3Provider.PushUrl(const AName: string): string;
begin
  // no '.git' suffix: the tail is an S3 key prefix, not a directory
  Result := JoinRemote(FBase, AName);
end;

function TS3Provider.DisplayUrl(const AName: string): string;
begin
  Result := PushUrl(AName);   // carries no credentials
end;

procedure TS3Provider.GetRunnerEnv(AOut: TStrings);
var
  helper, dir, path: string;
begin
  if AOut = nil then Exit;
  if FProfile <> '' then AOut.Add('AWS_PROFILE=' + FProfile);
  if FRegion <> '' then
  begin
    AOut.Add('AWS_REGION=' + FRegion);
    AOut.Add('AWS_DEFAULT_REGION=' + FRegion);
  end;
  helper := S3HelperPath;
  if helper = '' then Exit;
  dir := ExcludeTrailingPathDelimiter(ExtractFilePath(helper));
  path := GetEnvironmentVariable('PATH');
  // git looks for remote helpers on PATH only, so a helper installed in
  // ~/.local/bin is invisible to a GUI launched from a desktop menu
  if Pos(dir + PathSeparator, path + PathSeparator) = 0 then
    AOut.Add('PATH=' + dir + PathSeparator + path);
end;

{ Runs `git ls-remote` with the helper's environment in place. }
function TS3Provider.RemoteExists(const AName: string): Boolean;
var
  git: TGitRunner;
  env: TStringList;
begin
  Result := False;
  if S3HelperPath = '' then Exit;
  git := TGitRunner.Create('');
  env := TStringList.Create;
  try
    GetRunnerEnv(env);
    git.SetExtraEnv(env);
    Result := git.Git(['ls-remote', PushUrl(AName)]).Ok;
  finally
    env.Free;
    git.Free;
  end;
end;

function TS3Provider.EnsureRemote(const AName: string;
  out ADetail: string): TEnsureRemote;
var
  git: TGitRunner;
  env: TStringList;
  r: TGitResult;
begin
  ADetail := '';
  if S3HelperPath = '' then
  begin
    ADetail := S3_HELPER_MISSING_MSG;
    Exit(erError);
  end;
  if (FBase = '') or (Copy(LowerCase(FBase), 1, 5) <> 's3://') then
  begin
    ADetail := 'The S3 base must look like s3://bucket/prefix (got "' +
      FBase + '").';
    Exit(erError);
  end;

  git := TGitRunner.Create('');
  env := TStringList.Create;
  try
    GetRunnerEnv(env);
    git.SetExtraEnv(env);
    r := git.Git(['ls-remote', PushUrl(AName)]);
  finally
    env.Free;
    git.Free;
  end;

  if not r.Ok then
  begin
    // a missing bucket or a credential problem must NOT read as "not created
    // yet" -- that would send us into a push that cannot work
    ADetail := 'Cannot reach ' + PushUrl(AName) + ': ' + Trim(r.StdErr) +
      LineEnding + 'The bucket must already exist and your AWS credentials ' +
      'must allow access to it.';
    Exit(erError);
  end;
  // the helper writes the key space lazily on the first push
  if Trim(r.StdOut) = '' then Exit(erCreated);
  Result := erExists;
end;

{ ---- factory + per-backend policy ---- }

function MakeProvider(ACfg: TGotConfig; const AToken: string): TRemoteProvider;
begin
  case ParseBackendKind(ACfg.RemoteKind) of
    bkGitLab: Result := TGitLabProvider.Create(ACfg.GitLabHost,
        ACfg.GitLabNamespace, ACfg.RemoteUser, AToken);
    bkGit: Result := TGitProvider.Create(ACfg.SshBase);
    bkS3: Result := TS3Provider.Create(ACfg.S3Base, ACfg.AwsProfile, ACfg.AwsRegion);
    else
      Result := TGitHubProvider.Create(ACfg.RemoteUser, AToken);
  end;
end;

procedure CollectRemoteEnv(ACfg: TGotConfig; AOut: TStrings);
var
  prov: TRemoteProvider;
begin
  if AOut = nil then Exit;
  AOut.Clear;
  if ParseBackendKind(ACfg.RemoteKind) <> bkS3 then Exit;
  prov := MakeProvider(ACfg, '');
  try
    TS3Provider(prov).GetRunnerEnv(AOut);
  finally
    prov.Free;
  end;
end;

function CredAccount(ACfg: TGotConfig): string;
begin
  Result := CredKey(ParseBackendKind(ACfg.RemoteKind), ACfg.GitLabHost,
    ACfg.RemoteUser);
end;

function RemoteAuthUser(ACfg: TGotConfig): string;
begin
  if BackendNeedsToken(ParseBackendKind(ACfg.RemoteKind)) then
    Result := ACfg.RemoteUser
  else
    Result := '';
end;

function BackendSummary(ACfg: TGotConfig): string;
var
  kind: TBackendKind;
begin
  kind := ParseBackendKind(ACfg.RemoteKind);
  case kind of
    bkGitHub, bkGitLab:
    begin
      Result := BackendLabel(kind);
      if kind = bkGitLab then Result :=
          Result + ' (' + HostPortOf(ACfg.GitLabHost) + ')';
      if ACfg.RemoteUser <> '' then
        Result := Result + ' - signed in as ' + ACfg.RemoteUser
      else
        Result := Result + ' - not signed in';
    end;
    bkGit:
      if ACfg.SshBase <> '' then Result := BackendLabel(kind) + ' - ' + ACfg.SshBase
      else
        Result := BackendLabel(kind) + ' - no base URL set';
    bkS3:
    begin
      if ACfg.S3Base <> '' then Result := 'S3 - ' + ACfg.S3Base
      else
        Result := 'S3 - no bucket set';
      if ACfg.AwsProfile <> '' then
        Result := Result + ' (profile: ' + ACfg.AwsProfile + ')'
      else
        Result := Result + ' (default AWS profile)';
    end;
  end;
end;

function AccountStateOf(ACfg: TGotConfig; AHasToken: Boolean): TAccountState;
var
  kind: TBackendKind;
  configured: Boolean;
begin
  kind := ParseBackendKind(ACfg.RemoteKind);
  case kind of
    // keyless: the base IS the account, so configured means signed in
    bkGit: configured := ACfg.SshBase <> '';
    bkS3: configured := ACfg.S3Base <> '';
    else
      configured := ACfg.RemoteUser <> '';
  end;
  if not configured then Exit(asFresh);
  if BackendNeedsToken(kind) and (not AHasToken) then Exit(asPinnedSignedOut);
  Result := asSignedIn;
end;

function ResolveRemoteAuth(ACfg: TGotConfig; out AToken, AErr: string): Boolean;
var
  cred: TCredStore;
  kind: TBackendKind;
begin
  AToken := '';
  AErr := '';
  Result := False;
  kind := ParseBackendKind(ACfg.RemoteKind);
  case kind of
    bkGit:
    begin
      if ACfg.SshBase = '' then
      begin
        AErr := 'Set the self-hosted git base URL in the Account window first.';
        Exit;
      end;
      Exit(True);            // ssh key auth -- no token needed
    end;
    bkS3:
    begin
      if ACfg.S3Base = '' then
      begin
        AErr := 'Set the S3 bucket in the Account window first.';
        Exit;
      end;
      if S3HelperPath = '' then
      begin
        AErr := S3_HELPER_MISSING_MSG;
        Exit;
      end;
      Exit(True);            // the AWS credential chain does the rest
    end;
  end;

  // github / gitlab: a stored token keyed by account
  if ACfg.RemoteUser = '' then
  begin
    AErr := 'Sign in to ' + BackendLabel(kind) + ' with the Account window first.';
    Exit;
  end;
  cred := TCredStore.Create;
  try
    if not cred.LoadToken(CredAccount(ACfg), AToken) then
    begin
      AErr := 'No stored ' + BackendLabel(kind) +
        ' token found. Use Account to sign in again.';
      Exit;
    end;
  finally
    cred.Free;
  end;
  Result := True;
end;

end.
