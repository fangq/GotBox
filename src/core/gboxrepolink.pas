unit gboxrepolink;

{ Maps the local root directory onto GitHub repos. For each immediate subfolder
  of RootDir it ensures a matching private GitHub repo exists (creating it via
  the REST API when missing), wires up the local git repo + remote, and records
  the mapping in the config. Brand-new repos get an initial commit + push;
  folders whose remote already has history are just linked, leaving the actual
  reconciliation to the sync engine (milestones 5-6).

  EnsureLocalRepo (the git-side wiring) takes an explicit remote URL so it can be
  unit-tested against a local bare repo with no network or token. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxconfigstore, gboxgithubapi, gboxgitrunner, gboxstatusmodel;

type
  TLinkAction = (laCreated, laLinked, laError);

  TLinkResult = record
    LocalName: string;
    Action: TLinkAction;
    Detail: string;
  end;
  TLinkResultArray = array of TLinkResult;

  TRepoLinker = class
  private
    FCfg: TGotConfig;
    FToken: string;
    FStatus: TStatusModel;
    function RemoteFor(const AName: string; AWithUser: Boolean): string;
  public
    constructor Create(ACfg: TGotConfig; const AToken: string;
      AStatus: TStatusModel = nil);

    { Git-side wiring only (no GitHub calls). Ensures ALocalPath is a git repo
      with origin = ARemoteUrl, makes an initial commit if there is content and
      no commit yet, and (when ACreatedRemote) pushes it. Returns False + ADetail
      on the first failing git step. }
    function EnsureLocalRepo(const ALocalPath, ARemoteUrl: string;
      ACreatedRemote: Boolean; out ADetail: string): Boolean;

    { Create/link a single subfolder (talks to GitHub). }
    function LinkFolder(const AName: string; out ARes: TLinkResult): Boolean;

    { Scan immediate subfolders of RootDir and link/create each. }
    function ScanAndLink: TLinkResultArray;
  end;

implementation

uses
  gboxlog;

constructor TRepoLinker.Create(ACfg: TGotConfig; const AToken: string;
  AStatus: TStatusModel);
begin
  inherited Create;
  FCfg := ACfg;
  FToken := AToken;
  FStatus := AStatus;
end;

function TRepoLinker.RemoteFor(const AName: string; AWithUser: Boolean): string;
begin
  if AWithUser then
    // user embedded in the URL so git only ever asks for the password (token)
    Result := Format('https://%s@github.com/%s/%s.git',
      [FCfg.GithubUser, FCfg.GithubUser, AName])
  else
    Result := Format('https://github.com/%s/%s.git', [FCfg.GithubUser, AName]);
end;

function TRepoLinker.EnsureLocalRepo(const ALocalPath, ARemoteUrl: string;
  ACreatedRemote: Boolean; out ADetail: string): Boolean;
var
  git: TGitRunner;
  r: TGitResult;
  isRepo: Boolean;
begin
  Result := False;
  ADetail := '';
  git := TGitRunner.Create(ALocalPath);
  try
    git.AuthUser := FCfg.GithubUser;
    git.AuthToken := FToken;

    isRepo := DirectoryExists(IncludeTrailingPathDelimiter(ALocalPath) + '.git');
    if not isRepo then
    begin
      r := git.InitRepo;
      if not r.Ok then
      begin
        ADetail := 'git init failed: ' + Trim(r.StdErr);
        Exit;
      end;
    end;

    r := git.SetRemote('origin', ARemoteUrl);
    if not r.Ok then
    begin
      ADetail := 'set remote failed: ' + Trim(r.StdErr);
      Exit;
    end;

    // ensure a committer identity so commits succeed without a global git config
    if FCfg.GithubUser <> '' then
    begin
      git.Git(['config', 'user.name', FCfg.GithubUser]);
      git.Git(['config', 'user.email', FCfg.GithubUser + '@users.noreply.github.com']);
    end;

    // make an initial commit if there is content but no commit yet
    if (git.CountCommits <= 0) and git.HasUncommittedChanges then
    begin
      git.AddAll;
      r := git.CommitAll('initial commit');
      if not r.Ok then
      begin
        ADetail := 'initial commit failed: ' + Trim(r.StdErr);
        Exit;
      end;
    end;

    // push only when we just created the (empty) remote and have something local
    if ACreatedRemote and (git.CountCommits > 0) then
    begin
      r := git.Push(False);
      if not r.Ok then
      begin
        ADetail := 'initial push failed: ' + Trim(r.StdErr);
        Exit;
      end;
    end;

    Result := True;
  finally
    git.Free;
  end;
end;

function TRepoLinker.LinkFolder(const AName: string; out ARes: TLinkResult): Boolean;
var
  api: TGitHubApi;
  localPath, cloneUrl, err: string;
  existed, created: Boolean;
  entry: TRepoEntry;
begin
  ARes.LocalName := AName;
  ARes.Action := laError;
  ARes.Detail := '';
  Result := False;

  localPath := IncludeTrailingPathDelimiter(FCfg.RootDir) + AName;
  if Assigned(FStatus) then FStatus.SetState(AName, rsSyncing, 'linking');

  created := False;
  api := TGitHubApi.Create(FToken);
  try
    existed := api.RepoExists(FCfg.GithubUser, AName);
    if not existed then
    begin
      if not api.CreatePrivateRepo(AName, cloneUrl, err) then
      begin
        ARes.Detail := 'create failed: ' + err;
        if Assigned(FStatus) then FStatus.SetState(AName, rsError, ARes.Detail);
        Exit;
      end;
      created := True;
    end;
  finally
    api.Free;
  end;

  if not EnsureLocalRepo(localPath, RemoteFor(AName, True), created, ARes.Detail) then
  begin
    if Assigned(FStatus) then FStatus.SetState(AName, rsError, ARes.Detail);
    Exit;
  end;

  entry.LocalName := AName;
  entry.RemoteUrl := RemoteFor(AName, False); // store clean URL (no user/secret)
  entry.Paused := False;
  FCfg.UpsertRepo(entry);

  if created then ARes.Action := laCreated
  else
    ARes.Action := laLinked;
  ARes.Detail := entry.RemoteUrl;
  if Assigned(FStatus) then FStatus.SetState(AName, rsSynced, ARes.Detail);
  if Assigned(Log) then
    Log.Info('link', Format('%s -> %s (%s)', [AName, entry.RemoteUrl,
      BoolToStr(created, 'created', 'linked')]));
  Result := True;
end;

function TRepoLinker.ScanAndLink: TLinkResultArray;
var
  sr: TSearchRec;
  names: TStringList;
  i: Integer;
  res: TLinkResult;
begin
  SetLength(Result, 0);
  if (FCfg.RootDir = '') or not DirectoryExists(FCfg.RootDir) then Exit;

  names := TStringList.Create;
  try
    // collect immediate subfolders first (don't link while iterating the FS)
    if FindFirst(IncludeTrailingPathDelimiter(FCfg.RootDir) + AllFilesMask,
      faDirectory, sr) = 0 then
    begin
      repeat
        if (sr.Attr and faDirectory) <> 0 then
          if (sr.Name <> '.') and (sr.Name <> '..') and (sr.Name[1] <> '.') then
            names.Add(sr.Name);
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    names.Sort;

    for i := 0 to names.Count - 1 do
    begin
      LinkFolder(names[i], res);
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := res;
    end;
  finally
    names.Free;
  end;
end;

end.
