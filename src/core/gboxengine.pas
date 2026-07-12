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

unit gboxengine;

{ Orchestrator for the .gotbox superproject model. Spawns:
    - one "root" worker for the .gotbox working tree (syncs loose files; submodule
      directories are excluded from its watch, and ignore=all keeps submodule
      pointer changes from churning the superproject), and
    - one worker per submodule listed in .gitmodules (each a normal repo on main),
      honouring the per-submodule Paused flag from config.
  The GUI owns a single TSyncEngine. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  gboxconfigstore, gboxstatusmodel, gboxrepoworker, gboxsuper, gboxfilestatus;

type
  TSyncEngine = class
  private
    FCfg: TGotConfig;
    FToken: string;
    FStatus: TStatusModel;
    FWorkers: array of TRepoWorker;
    FRunning: Boolean;
    FTransitioning: Boolean;   // inside Stop/Start -- block reentrant reconcile
    FOnNotice: TSyncNoticeEvent;
    FStatusCache: TStatusCache;   // borrowed; feeds the file-manager overlay
    FSubNames: TStringList;    // submodule local names managed at last Start (sorted)
    function LocalPathOf(const AName: string): string;
    { Worker cycle finished -> drop that repo's overlay-status cache. }
    procedure WorkerCycleDone(const ALocalPath: string);
    procedure SpawnWorker(const AName, APath: string; AAutoSync: Boolean;
      AExtraIgnore: TStrings);
    { Root worker (thread) -> queue DoReconcile onto the main thread. }
    procedure OnRootReposChanged;
    procedure DoReconcile;
    { Re-read .gitmodules; if the submodule set changed since Start, restart the
      workers (picks up added submodules, drops removed ones + their status). }
    function ReconcileIfChanged: Boolean;
    { Check out a registered submodule whose working tree is missing (arrived via
      a pull, or added but never populated). Returns True if it is a work tree
      afterwards. }
    function EnsureSubmoduleCheckedOut(const AName: string): Boolean;
  public
    constructor Create(ACfg: TGotConfig; const AToken: string; AStatus: TStatusModel);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    procedure SyncAllNow;
    procedure SyncRepo(const AName: string);
    property Running: Boolean read FRunning;
    function WorkerCount: Integer;
    { Fired (on a worker thread) when a cycle synced files; handler must marshal
      to the GUI. Set before Start so spawned workers pick it up. }
    property OnNotice: TSyncNoticeEvent read FOnNotice write FOnNotice;
    { Optional per-file status cache (owned by the front-end) that workers
      invalidate after each cycle so file-manager overlays stay fresh. Set
      before Start so spawned workers pick it up. }
    property StatusCache: TStatusCache read FStatusCache write FStatusCache;
  end;

implementation

uses
  gboxlog, gboxgitrunner;

{ Opt-in engine trace (same GOTBOX_GIT_TRACE switch as the git-op trace) so the
  reconcile Stop/Start and per-worker WaitFor boundaries appear inline with the
  GIT> / GIT< lines -- pinpoints which WaitFor (which worker) blocks teardown. }
var
  gEngTrace: Integer = -1;

procedure EngTrace(const AMsg: string);
begin
  if gEngTrace < 0 then
    if GetEnvironmentVariable('GOTBOX_GIT_TRACE') <> '' then gEngTrace := 1
    else gEngTrace := 0;
  if gEngTrace = 1 then
  begin
    WriteLn(StdErr, 'ENG: ' + AMsg);
    Flush(StdErr);
  end;
end;

{ True if APath is a directory containing at least one entry (besides . and ..). }
function DirHasEntries(const APath: string): Boolean;
var
  sr: TSearchRec;
begin
  Result := False;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + AllFilesMask,
    faAnyFile, sr) = 0 then
  begin
    try
      repeat
        if (sr.Name <> '.') and (sr.Name <> '..') then
          Exit(True);
      until FindNext(sr) <> 0;
    finally
      SysUtils.FindClose(sr);
    end;
  end;
end;

constructor TSyncEngine.Create(ACfg: TGotConfig; const AToken: string;
  AStatus: TStatusModel);
begin
  inherited Create;
  FCfg := ACfg;
  FToken := AToken;
  FStatus := AStatus;
  FSubNames := TStringList.Create;
end;

destructor TSyncEngine.Destroy;
begin
  // drop any reconcile queued from a worker thread before we go away
  TThread.RemoveQueuedEvents(nil, @DoReconcile);
  Stop;
  FSubNames.Free;
  inherited Destroy;
end;

procedure TSyncEngine.OnRootReposChanged;
begin
  // fired on the root worker thread; do the (worker-stopping) reconcile on the
  // main thread to avoid a worker joining itself
  TThread.Queue(nil, @DoReconcile);
end;

procedure TSyncEngine.DoReconcile;
begin
  // CRITICAL: on Windows, TThread.WaitFor on the main thread pumps
  // CheckSynchronize (MsgWaitForMultipleObjects + QS_SENDMESSAGE), so a
  // DoReconcile queued by a worker can fire *inside* engine.Stop's WaitFor. If
  // it ran a nested Stop/Start it would free/replace FWorkers out from under the
  // outer Stop's loop -> WaitFor on a dead worker (hang) or a freed object
  // (crash). Skip while a Stop/Start is already in flight; the reconcile is
  // re-driven on the next worker cycle anyway.
  if FTransitioning then Exit;
  ReconcileIfChanged;
end;

function TSyncEngine.ReconcileIfChanged: Boolean;
var
  subs: TSubmoduleArray;
  cur: TStringList;
  i: Integer;
  diff: Boolean;
begin
  Result := False;
  if not FRunning then Exit;
  subs := ListSubmodules(FCfg.RootDir);
  cur := TStringList.Create;
  try
    for i := 0 to High(subs) do
      cur.Add(subs[i].LocalName);
    cur.Sort;
    diff := cur.Count <> FSubNames.Count;
    if not diff then
      for i := 0 to cur.Count - 1 do
        if not SameText(cur[i], FSubNames[i]) then
        begin
          diff := True;
          Break;
        end;
  finally
    cur.Free;
  end;
  if diff then
  begin
    if Assigned(Log) then
      Log.Info('engine', 'submodule set changed on pull; reconciling workers');
    EngTrace('reconcile: submodule set changed -> Stop');
    Stop;
    EngTrace('reconcile: Stop done -> Start');
    Start;   // re-scans .gitmodules, prunes stale status, checks out new subs
    EngTrace('reconcile: Start done');
    Result := True;
  end;
end;

function TSyncEngine.LocalPathOf(const AName: string): string;
begin
  // AName may be a relative path with '/' separators (nested submodule); convert
  // to native separators for filesystem/git working-dir use
  Result := IncludeTrailingPathDelimiter(FCfg.RootDir) + SetDirSeparators(AName);
end;

function TSyncEngine.EnsureSubmoduleCheckedOut(const AName: string): Boolean;
var
  git: TGitRunner;
  r: TGitResult;
  path, backup, backupRoot: string;
begin
  if IsGitWorkTree(LocalPathOf(AName)) then Exit(True);
  // If the module repo already exists under .git/modules but the working tree is
  // gone, the user DELETED this submodule -- do not resurrect it here. The root
  // worker will unlink it (drop the gitlink + .gitmodules entry) on its next
  // cycle. Only auto-check-out submodules that were never populated on this
  // machine (a fresh clone / a gitlink that arrived via a pull).
  if DirectoryExists(IncludeTrailingPathDelimiter(FCfg.RootDir) +
    '.git' + PathDelim + 'modules' + PathDelim + SetDirSeparators(AName)) then
    Exit(False);
  if Assigned(Log) then
    Log.Info('engine', 'checking out submodule ' + AName);
  git := TGitRunner.Create(FCfg.RootDir);
  try
    git.AuthUser := FCfg.GithubUser;
    git.AuthToken := FToken;
    git.DefaultTimeoutMs := GIT_DEFAULT_TIMEOUT_MS;   // don't hang on a stuck checkout
    // --init populates a registered-but-uninitialized submodule; the submodule
    // name/path uses forward slashes as stored in .gitmodules. protocol.file.allow
    // keeps file:// remotes (local/tests) working, matching the "add" path.
    r := git.Git(['-c', 'protocol.file.allow=always', 'submodule',
      'update', '--init', '--', AName]);

    // git refuses to clone a submodule into a non-empty directory. If the local
    // folder holds unrelated content (e.g. this path was a plain folder here
    // before it became a submodule elsewhere), move it aside -- under .git, so
    // it is never synced -- and retry. The remote (authoritative) content then
    // checks out; the backed-up files are preserved for the user to reconcile.
    if not r.Ok then
    begin
      path := LocalPathOf(AName);
      if DirectoryExists(path) and DirHasEntries(path) then
      begin
        backupRoot := IncludeTrailingPathDelimiter(FCfg.RootDir) +
          '.git' + PathDelim + 'gotbox-backups';
        ForceDirectories(backupRoot);
        backup := IncludeTrailingPathDelimiter(backupRoot) +
          StringReplace(AName, '/', '_', [rfReplaceAll]) + '-' +
          FormatDateTime('yyyymmdd-hhnnss', Now);
        if RenameFile(path, backup) then
        begin
          if Assigned(Log) then
            Log.Warn('engine', Format('%s: local folder blocked the linked ' +
              'submodule; moved to %s, checking out remote', [AName, backup]));
          r := git.Git(['-c', 'protocol.file.allow=always', 'submodule',
            'update', '--init', '--', AName]);
        end
        else if Assigned(Log) then
          Log.Error('engine', Format('%s: could not move blocking folder aside',
            [AName]));
      end;
    end;

    if (not r.Ok) and Assigned(Log) then
      Log.Warn('engine', Format('submodule %s checkout failed: %s',
        [AName, Trim(r.StdErr)]));

    // a fresh --init leaves the submodule in detached HEAD at the recorded SHA;
    // put it on main so its sync worker can commit/push (as AddSubmodule does)
    if r.Ok and IsGitWorkTree(LocalPathOf(AName)) then
      git.Git(['-C', LocalPathOf(AName), 'checkout', '-B', 'main']);
  finally
    git.Free;
  end;
  Result := IsGitWorkTree(LocalPathOf(AName));
end;

procedure TSyncEngine.WorkerCycleDone(const ALocalPath: string);
begin
  // runs on the worker thread; TStatusCache.Invalidate is thread-safe
  if Assigned(FStatusCache) then FStatusCache.Invalidate(ALocalPath);
end;

procedure TSyncEngine.SpawnWorker(const AName, APath: string; AAutoSync: Boolean;
  AExtraIgnore: TStrings);
var
  ignore: TStringList;
  w: TRepoWorker;
begin
  ignore := TStringList.Create;
  try
    ignore.Assign(FCfg.IgnoreGlobs);
    if Assigned(AExtraIgnore) then
      ignore.AddStrings(AExtraIgnore);
    w := TRepoWorker.Create(AName, APath, FCfg.GithubUser, FToken,
      FCfg.MachineName, FCfg.CommitDebounceMs, FCfg.GcEveryNCommits,
      FCfg.PullIntervalSec, FCfg.HistoryCap, FCfg.LfsThresholdMB, AAutoSync,
      FStatus, ignore);
    w.OnNotice := FOnNotice;
    w.OnCycleDone := @WorkerCycleDone;
    // only the root's .gitmodules governs the submodule set
    if AName = GOTBOX_REPO then
      w.OnReposChanged := @OnRootReposChanged;
  finally
    ignore.Free;
  end;
  SetLength(FWorkers, Length(FWorkers) + 1);
  FWorkers[High(FWorkers)] := w;
  w.Start;
end;

procedure TSyncEngine.Start;
var
  subs: TSubmoduleArray;
  subNames: TStringList;
  i: Integer;
  entry: TRepoEntry;
  paused, found, autoSync: Boolean;
begin
  if FRunning then Exit;
  SetLength(FWorkers, 0);

  if not IsGitWorkTree(FCfg.RootDir) then
  begin
    if Assigned(FStatus) then
      FStatus.SetState(GOTBOX_REPO, rsError, 'root not set up');
    FRunning := True;   // still "running" (just nothing to do) so Stop is symmetric
    Exit;
  end;

  subs := ListSubmodules(FCfg.RootDir);

  // record the submodule set (sorted) for later change-detection, and drop any
  // status entry for a repo we no longer manage -- e.g. a submodule removed on
  // another machine and just pulled in, whose stale error would otherwise stick
  FSubNames.Clear;
  for i := 0 to High(subs) do
    FSubNames.Add(subs[i].LocalName);
  FSubNames.Sort;
  if Assigned(FStatus) then
  begin
    subNames := TStringList.Create;
    try
      subNames.Add(GOTBOX_REPO);
      subNames.AddStrings(FSubNames);
      FStatus.RetainOnly(subNames);
    finally
      subNames.Free;
    end;
  end;

  // Populate any registered-but-unpopulated submodule (its gitlink arrived via a
  // pull, or it was added but never checked out) BEFORE spawning any worker. The
  // checkout writes the submodule URL into .git/config; doing it while the root
  // worker concurrently writes its committer identity into .git/config collides
  // on .git/config.lock and aborts the checkout. No worker threads exist yet
  // here, so the config writes are serialised. Skip paused submodules.
  for i := 0 to High(subs) do
    if not (FCfg.FindRepo(subs[i].LocalName, entry) and entry.Paused) then
      EnsureSubmoduleCheckedOut(subs[i].LocalName);

  // 1) root worker: sync loose files, excluding the submodule directories
  subNames := TStringList.Create;
  try
    for i := 0 to High(subs) do
      subNames.Add(subs[i].LocalName);
    // the .gotbox root always syncs automatically (loose files, Dropbox-style)
    if Assigned(FStatus) then FStatus.SetMode(GOTBOX_REPO, True);
    SpawnWorker(GOTBOX_REPO, FCfg.RootDir, True, subNames);
  finally
    subNames.Free;
  end;

  // 2) one worker per submodule (honour the per-submodule Paused flag). The
  // checkout already happened above; here we only spawn workers, treating a
  // still-missing working tree as an error (do NOT re-run the checkout, which
  // would race the now-running root worker on .git/config).
  for i := 0 to High(subs) do
  begin
    // a submodule not yet recorded in config (e.g. just pulled in from another
    // machine) defaults to managed -- never auto-commit an unfamiliar repo
    found := FCfg.FindRepo(subs[i].LocalName, entry);
    paused := found and entry.Paused;
    autoSync := found and entry.AutoSync;
    if Assigned(FStatus) then FStatus.SetMode(subs[i].LocalName, autoSync);
    if paused then
    begin
      if Assigned(FStatus) then
        FStatus.SetState(subs[i].LocalName, rsPaused, 'paused');
      Continue;
    end;
    if not IsGitWorkTree(LocalPathOf(subs[i].LocalName)) then
    begin
      if Assigned(FStatus) then
        FStatus.SetState(subs[i].LocalName, rsError, 'submodule not checked out');
      Continue;
    end;
    SpawnWorker(subs[i].LocalName, LocalPathOf(subs[i].LocalName), autoSync, nil);
  end;

  FRunning := True;
  if Assigned(Log) then
    Log.Info('engine', Format('started %d worker(s)', [Length(FWorkers)]));
end;

procedure TSyncEngine.Stop;
var
  i: Integer;
begin
  if not FRunning and (Length(FWorkers) = 0) then Exit;
  // FTransitioning is held across the whole teardown: WaitFor below pumps
  // CheckSynchronize on Windows, so a queued DoReconcile could otherwise reenter
  // Stop/Start and corrupt FWorkers mid-loop (see DoReconcile).
  FTransitioning := True;
  try
    for i := 0 to High(FWorkers) do
      FWorkers[i].Stop;
    for i := 0 to High(FWorkers) do
    begin
      EngTrace(Format('Stop: WaitFor worker %d (%s)', [i, FWorkers[i].RepoName]));
      FWorkers[i].WaitFor;
      EngTrace(Format('Stop: worker %d (%s) joined', [i, FWorkers[i].RepoName]));
      FWorkers[i].Free;
    end;
    SetLength(FWorkers, 0);
    FRunning := False;
  finally
    FTransitioning := False;
  end;
  if Assigned(Log) then Log.Info('engine', 'stopped');
end;

procedure TSyncEngine.SyncAllNow;
var
  i: Integer;
begin
  for i := 0 to High(FWorkers) do
    FWorkers[i].RequestSync;
end;

procedure TSyncEngine.SyncRepo(const AName: string);
var
  i: Integer;
begin
  for i := 0 to High(FWorkers) do
    if SameText(FWorkers[i].RepoName, AName) then
      FWorkers[i].RequestSync;
end;

function TSyncEngine.WorkerCount: Integer;
begin
  Result := Length(FWorkers);
end;

end.
