unit gboxsuper;

{ The ".gotbox" superproject model. The local root folder is the working tree of
  a single private repo named ".gotbox". Each linked repo is a git submodule
  under the root, with a customizable local name (independent of the upstream
  repo name). Pointer tracking is "list only": submodules are recorded in
  .gitmodules with ignore=all, so the superproject is not churned by submodule
  commits -- each submodule syncs independently. Loose files in the root sync to
  .gotbox itself. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxconfigstore, gboxgitrunner, gboxremote, gboxrepolink;

const
  GOTBOX_REPO = '.gotbox';

type
  TSubmoduleInfo = record
    LocalName: string;   // path under the root (the submodule's local name)
    Url: string;         // upstream URL (display form)
  end;
  TSubmoduleArray = array of TSubmoduleInfo;

{ Ensures the root folder is the working tree of the private .gotbox repo,
  creating the repo via the backend provider if it does not exist. }
function EnsureGotboxRoot(ACfg: TGotConfig; const AToken: string;
  out ADetail: string): Boolean;

{ Adds a submodule under the root. When ACreateUpstream, a new private repo named
  AUpstreamName is created via the provider; otherwise AExistingUrl is used.
  ALocalName is the submodule's local path/name. Commits .gotbox and pushes. }
function AddSubmodule(ACfg: TGotConfig;
  const AToken, ALocalName, AUpstreamName, AExistingUrl: string;
  ACreateUpstream: Boolean; out ADetail: string): Boolean;

{ Submodules recorded in <root>/.gitmodules. }
function ListSubmodules(const ARoot: string): TSubmoduleArray;

{ True if the root folder holds any user content worth syncing -- i.e. any entry
  other than '.', '..' and '.git'. Used to decide whether to auto-create the
  .gotbox repo when files/folders appear before any submodule is linked. }
function RootHasContent(const ARoot: string): Boolean;

implementation

uses
  gboxlog;

function EnsureGotboxRoot(ACfg: TGotConfig; const AToken: string;
  out ADetail: string): Boolean;
var
  prov: TRemoteProvider;
  linker: TRepoLinker;
  ens: TEnsureRemote;
begin
  Result := False;
  ADetail := '';
  prov := MakeProvider(ACfg, AToken);
  try
    ens := prov.EnsureRemote(GOTBOX_REPO, ADetail);
    if ens = erError then Exit;
    // reuse the repo-linker's git-side wiring (init + remote + identity +
    // initial commit + push when newly created)
    linker := TRepoLinker.Create(ACfg, AToken);
    try
      Result := linker.EnsureLocalRepo(ACfg.RootDir, prov.PushUrl(GOTBOX_REPO),
        ens = erCreated, ADetail);
    finally
      linker.Free;
    end;
    if Result and Assigned(Log) then
      Log.Info('super', '.gotbox root ready at ' + ACfg.RootDir);
  finally
    prov.Free;
  end;
end;

{ Give a freshly-created (empty) upstream an initial commit on main, so it can be
  cloned as a submodule (git submodule add cannot check out an unborn branch). }
function SeedUpstream(AProv: TRemoteProvider; const AUrl, AMachine: string): Boolean;
var
  tmp, who: string;
  g: TGitRunner;
begin
  tmp := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-seed-' +
    FormatDateTime('hhnnsszzz', Now) + IntToStr(Random(99999));
  ForceDirectories(tmp);
  g := TGitRunner.Create(tmp);
  try
    g.AuthUser := AProv.AuthUser;
    g.AuthToken := AProv.AuthToken;
    g.InitRepo;
    who := AProv.AuthUser;
    if who = '' then who := AMachine;
    if who = '' then who := 'gotbox';
    g.Git(['config', 'user.name', who]);
    g.Git(['config', 'user.email', who + '@gotbox.local']);
    g.Git(['commit', '--allow-empty', '-m', 'initial commit']);
    g.SetRemote('origin', AUrl);
    Result := g.Push(False).Ok;
  finally
    g.Free;
  end;
end;

function AddSubmodule(ACfg: TGotConfig;
  const AToken, ALocalName, AUpstreamName, AExistingUrl: string;
  ACreateUpstream: Boolean; out ADetail: string): Boolean;
var
  prov: TRemoteProvider;
  git, subgit: TGitRunner;
  r: TGitResult;
  url: string;
begin
  Result := False;
  ADetail := '';
  if Trim(ALocalName) = '' then
  begin
    ADetail := 'submodule name is empty';
    Exit;
  end;

  prov := MakeProvider(ACfg, AToken);
  try
    if ACreateUpstream then
    begin
      if prov.EnsureRemote(AUpstreamName, ADetail) = erError then Exit;
      url := prov.PushUrl(AUpstreamName);
      // a brand-new repo is empty; seed it so it can be cloned as a submodule
      if not SeedUpstream(prov, url, ACfg.MachineName) then
      begin
        ADetail := 'could not seed new upstream ' + AUpstreamName;
        Exit;
      end;
    end
    else
      url := AExistingUrl;
    if url = '' then
    begin
      ADetail := 'no upstream URL';
      Exit;
    end;

    git := TGitRunner.Create(ACfg.RootDir);
    try
      git.AuthUser := prov.AuthUser;
      git.AuthToken := prov.AuthToken;

      // add the submodule (allow the file protocol so local/test remotes work)
      r := git.Git(['-c', 'protocol.file.allow=always', 'submodule',
        'add', '--force', url, ALocalName]);
      if not r.Ok then
      begin
        ADetail := 'submodule add failed: ' + Trim(r.StdErr);
        Exit;
      end;

      // list-only pointer tracking: don't let submodule commits churn .gotbox
      git.Git(['config', '-f', '.gitmodules', 'submodule.' +
        ALocalName + '.ignore', 'all']);

      // ensure the submodule is on the main branch (not detached) so the
      // per-submodule sync worker can auto-commit to it later
      subgit := TGitRunner.Create(IncludeTrailingPathDelimiter(ACfg.RootDir) +
        ALocalName);
      try
        subgit.AuthUser := prov.AuthUser;
        subgit.AuthToken := prov.AuthToken;
        subgit.Git(['checkout', '-B', 'main']);
      finally
        subgit.Free;
      end;

      // commit + push the superproject (.gitmodules + the new gitlink)
      git.AddAll;
      r := git.CommitAll('add submodule ' + ALocalName);
      if not r.Ok then
      begin
        ADetail := 'commit .gotbox failed: ' + Trim(r.StdErr);
        Exit;
      end;
      git.Push(False);
      Result := True;
      if Assigned(Log) then
        Log.Info('super', Format('added submodule %s -> %s', [ALocalName, url]));
    finally
      git.Free;
    end;
  finally
    prov.Free;
  end;
end;

function RootHasContent(const ARoot: string): Boolean;
var
  sr: TSearchRec;
begin
  Result := False;
  if not DirectoryExists(ARoot) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(ARoot) + AllFilesMask,
    faAnyFile, sr) = 0 then
  begin
    try
      repeat
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        if SameText(sr.Name, '.git') then Continue;
        Exit(True);   // any other entry counts as content
      until FindNext(sr) <> 0;
    finally
      SysUtils.FindClose(sr);
    end;
  end;
end;

function ListSubmodules(const ARoot: string): TSubmoduleArray;
var
  git: TGitRunner;
  r: TGitResult;
  lines: TStringList;
  i, sp: Integer;
  key, val, name: string;

  procedure SetField(const AName, AUrl: string; AIsUrl: Boolean);
  var
    k: Integer;
  begin
    for k := 0 to High(Result) do
      if Result[k].LocalName = AName then
      begin
        if AIsUrl then Result[k].Url := AUrl;
        Exit;
      end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].LocalName := AName;
    if AIsUrl then Result[High(Result)].Url := AUrl;
  end;

begin
  SetLength(Result, 0);
  if not FileExists(IncludeTrailingPathDelimiter(ARoot) + '.gitmodules') then Exit;
  git := TGitRunner.Create(ARoot);
  lines := TStringList.Create;
  try
    // each line: "submodule.<name>.path <relpath>"  /  ".url <url>"
    r := git.Git(['config', '-f', '.gitmodules', '--get-regexp',
      '^submodule\..*\.(path|url)$']);
    if not r.Ok then Exit;
    lines.Text := r.StdOut;
    for i := 0 to lines.Count - 1 do
    begin
      sp := Pos(' ', lines[i]);
      if sp <= 0 then Continue;
      key := Copy(lines[i], 1, sp - 1);
      val := Copy(lines[i], sp + 1, MaxInt);
      // key = submodule.<name>.path|url ; <name> may contain dots, so split on the last '.'
      name := Copy(key, Length('submodule.') + 1, MaxInt);
      if (Length(name) > 5) and (Copy(name, Length(name) - 4, 5) = '.path') then
        SetField(Copy(name, 1, Length(name) - 5), val, False)  // path == local name
      else if (Length(name) > 4) and (Copy(name, Length(name) - 3, 4) = '.url') then
        SetField(Copy(name, 1, Length(name) - 4), val, True);
    end;
  finally
    lines.Free;
    git.Free;
  end;
end;

end.
