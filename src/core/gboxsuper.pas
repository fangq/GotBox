{
  GotBox -- Dropbox-like file sync over your own private git repositories.
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
  ALocalName is the submodule's local path/name -- it may be a relative path
  (e.g. "projects/notes") to place the submodule in a sub-folder of the root.
  Commits .gotbox and pushes. }
function AddSubmodule(ACfg: TGotConfig;
  const AToken, ALocalName, AUpstreamName, AExistingUrl: string;
  ACreateUpstream: Boolean; out ADetail: string): Boolean;

{ Validate + normalize a submodule local name that may be a relative path:
  accepts either slash, rejects absolute paths and ".." (no escaping the root),
  collapses redundant separators, and returns a clean forward-slash path (the
  form git stores in .gitmodules). Returns False with AErr on invalid input. }
function NormalizeSubmodulePath(const AInput: string; out APath, AErr: string): Boolean;

{ True if the remote .gotbox repo already exists with content (so a fresh machine
  should clone it rather than wait for local content to be created). }
function GotboxRemoteReady(ACfg: TGotConfig; const AToken: string): Boolean;

{ Submodules recorded in <root>/.gitmodules. }
function ListSubmodules(const ARoot: string): TSubmoduleArray;

{ True if the root folder holds any user content worth syncing -- i.e. any entry
  other than '.', '..' and '.git'. Used to decide whether to auto-create the
  .gotbox repo when files/folders appear before any submodule is linked. }
function RootHasContent(const ARoot: string): Boolean;

{ True if APath is a git working tree (a submodule's .git is a FILE, the
  superproject's is a directory -- accept either). }
function IsGitWorkTree(const APath: string): Boolean;

implementation

uses
  gboxlog, gboxlfs;

function IsGitWorkTree(const APath: string): Boolean;
var
  dot: string;
begin
  dot := IncludeTrailingPathDelimiter(APath) + '.git';
  Result := DirectoryExists(dot) or FileExists(dot);
end;

{ Recursively clone an existing remote .gotbox into the (empty) root. }
function CloneGotboxRoot(AProv: TRemoteProvider; const ARoot, AMachine: string;
  out ADetail: string): Boolean;
var
  git: TGitRunner;
  r: TGitResult;
  who: string;
begin
  ADetail := '';
  git := TGitRunner.Create('');
  git.AuthUser := AProv.AuthUser;
  git.AuthToken := AProv.AuthToken;
  try
    // --recursive brings the submodules down too; allow file:// for local/tests
    r := git.Git(['-c', 'protocol.file.allow=always', 'clone',
      '--recursive', AProv.PushUrl(GOTBOX_REPO), ExcludeTrailingPathDelimiter(ARoot)]);
    if not r.Ok then
    begin
      ADetail := 'clone failed: ' + Trim(r.StdErr);
      Exit(False);
    end;
  finally
    git.Free;
  end;

  // committer identity on the freshly cloned tree
  git := TGitRunner.Create(ARoot);
  try
    who := AProv.AuthUser;
    if who = '' then who := AMachine;
    if who = '' then who := 'gotbox';
    git.Git(['config', 'user.name', who]);
    git.Git(['config', 'user.email', who + '@gotbox.local']);
    LfsPostClone(git);   // materialize any LFS-stored files in the fresh clone
  finally
    git.Free;
  end;
  Result := True;
  if Assigned(Log) then Log.Info('super', '.gotbox cloned to ' + ARoot);
end;

{ True if the remote repo has at least one ref (real commits), vs existing but
  empty (e.g. just created, or a half-set-up repo). }
function RemoteHasCommits(AProv: TRemoteProvider; const AName: string): Boolean;
var
  git: TGitRunner;
  r: TGitResult;
begin
  git := TGitRunner.Create('');
  git.AuthUser := AProv.AuthUser;
  git.AuthToken := AProv.AuthToken;
  try
    r := git.Git(['ls-remote', AProv.PushUrl(AName)]);
    Result := r.Ok and (Trim(r.StdOut) <> '');
  finally
    git.Free;
  end;
end;

function EnsureGotboxRoot(ACfg: TGotConfig; const AToken: string;
  out ADetail: string): Boolean;
var
  prov: TRemoteProvider;
  linker: TRepoLinker;
  ens: TEnsureRemote;
  emptyRoot, remoteEmpty: Boolean;
begin
  Result := False;
  ADetail := '';
  prov := MakeProvider(ACfg, AToken);
  try
    emptyRoot := (not IsGitWorkTree(ACfg.RootDir)) and
      (not RootHasContent(ACfg.RootDir));

    // fresh machine: remote .gotbox already has content and the root is empty
    // -- recursively clone it (brings submodules too) rather than init.
    if emptyRoot and RemoteHasCommits(prov, GOTBOX_REPO) then
    begin
      Result := CloneGotboxRoot(prov, ACfg.RootDir, ACfg.MachineName, ADetail);
      Exit;
    end;

    ens := prov.EnsureRemote(GOTBOX_REPO, ADetail);
    if ens = erError then Exit;
    // push the initial commit when we just created the remote OR it exists but
    // is still empty (no branch yet -- e.g. a half-created repo)
    remoteEmpty := not RemoteHasCommits(prov, GOTBOX_REPO);

    // reuse the repo-linker's git-side wiring (init + remote + identity +
    // initial commit + push)
    linker := TRepoLinker.Create(ACfg, AToken);
    try
      Result := linker.EnsureLocalRepo(ACfg.RootDir, prov.PushUrl(GOTBOX_REPO),
        (ens = erCreated) or remoteEmpty, ADetail);
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

function NormalizeSubmodulePath(const AInput: string; out APath, AErr: string): Boolean;
var
  raw, comp: string;
  p: Integer;
begin
  Result := False;
  APath := '';
  AErr := '';
  raw := Trim(AInput);
  raw := StringReplace(raw, '\', '/', [rfReplaceAll]);   // accept either separator
  if raw = '' then
  begin
    AErr := 'submodule name is empty';
    Exit;
  end;
  if raw[1] = '/' then
  begin
    AErr := 'use a path relative to the root (no leading "/")';
    Exit;
  end;
  if (Length(raw) >= 2) and (raw[2] = ':') then
  begin
    AErr := 'use a relative path, not an absolute path';
    Exit;
  end;
  // validate + rejoin components, collapsing '' and '.', rejecting '..'
  while raw <> '' do
  begin
    p := Pos('/', raw);
    if p > 0 then
    begin
      comp := Copy(raw, 1, p - 1);
      Delete(raw, 1, p);
    end
    else
    begin
      comp := raw;
      raw := '';
    end;
    if (comp = '') or (comp = '.') then Continue;
    if comp = '..' then
    begin
      AErr := '".." is not allowed in a submodule path';
      Exit;
    end;
    if APath <> '' then APath := APath + '/';
    APath := APath + comp;
  end;
  if APath = '' then
  begin
    AErr := 'submodule name is empty';
    Exit;
  end;
  Result := True;
end;

function AddSubmodule(ACfg: TGotConfig;
  const AToken, ALocalName, AUpstreamName, AExistingUrl: string;
  ACreateUpstream: Boolean; out ADetail: string): Boolean;
var
  prov: TRemoteProvider;
  git, subgit: TGitRunner;
  r: TGitResult;
  url, localPath: string;
begin
  Result := False;
  ADetail := '';
  if not NormalizeSubmodulePath(ALocalName, localPath, ADetail) then Exit;

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

      // add the submodule (allow the file protocol so local/test remotes work).
      // git uses the path as the submodule name; forward slashes work on all OSes
      r := git.Git(['-c', 'protocol.file.allow=always', 'submodule',
        'add', '--force', url, localPath]);
      if not r.Ok then
      begin
        ADetail := 'submodule add failed: ' + Trim(r.StdErr);
        Exit;
      end;

      // list-only pointer tracking: don't let submodule commits churn .gotbox
      git.Git(['config', '-f', '.gitmodules', 'submodule.' +
        localPath + '.ignore', 'all']);

      // ensure the submodule is on the main branch (not detached) so the
      // per-submodule sync worker can auto-commit to it later
      subgit := TGitRunner.Create(IncludeTrailingPathDelimiter(ACfg.RootDir) +
        SetDirSeparators(localPath));
      try
        subgit.AuthUser := prov.AuthUser;
        subgit.AuthToken := prov.AuthToken;
        subgit.Git(['checkout', '-B', 'main']);
      finally
        subgit.Free;
      end;

      // commit + push the superproject (.gitmodules + the new gitlink)
      git.AddAll;
      r := git.CommitAll('add submodule ' + localPath);
      if not r.Ok then
      begin
        ADetail := 'commit .gotbox failed: ' + Trim(r.StdErr);
        Exit;
      end;
      git.Push(False);
      Result := True;
      if Assigned(Log) then
        Log.Info('super', Format('added submodule %s -> %s', [localPath, url]));
    finally
      git.Free;
    end;
  finally
    prov.Free;
  end;
end;

function GotboxRemoteReady(ACfg: TGotConfig; const AToken: string): Boolean;
var
  prov: TRemoteProvider;
begin
  Result := False;
  prov := MakeProvider(ACfg, AToken);
  try
    Result := RemoteHasCommits(prov, GOTBOX_REPO);
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
