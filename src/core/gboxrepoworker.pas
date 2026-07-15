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

unit gboxrepoworker;

{ One background thread per repo. Watches the working tree (via TFileWatcher)
  and debounces bursts of saves, then runs a bidirectional sync cycle
  (commit -> fetch -> merge/keep-both -> push) via gboxsync. Also triggers a
  periodic pull so remote changes arrive without a local edit, and runs `git gc`
  for maintenance. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, SyncObjs,
  gboxgitrunner, gboxfilewatcher, gboxstatusmodel, gboxsync, gboxhistory, gboxlfs,
  gboxrecover;

type
  { Fired (on the worker thread) after a cycle that synced files, with a ready-
    to-show notification title/body. The handler must marshal to the GUI. }
  TSyncNoticeEvent = procedure(const ATitle, ABody: string) of object;
  { Fired (on the worker thread) by the ROOT worker after a cycle that pulled
    remote changes, so the engine can re-scan .gitmodules and add/drop submodule
    workers. The handler must marshal any UI/engine work to the main thread. }
  TReposChangedEvent = procedure of object;

{ Exponential backoff (milliseconds, no jitter) for the AStreak-th consecutive
  hard error: ABaseMs, doubling each further failure, capped at AMaxMs. Pure, so
  the escalation is unit-testable. }
function BackoffDelayMs(AStreak, ABaseMs, AMaxMs: Integer): Integer;

type
  { Fired (on the worker thread) at the end of every sync cycle, with this
    repo's working-tree path, so the owner can invalidate a per-file status
    cache (used by the file-manager overlay). }
  TCycleDoneEvent = procedure(const ALocalPath: string) of object;

  TRepoWorker = class(TThread)
  private
    FName: string;
    FLocalPath: string;
    FUser: string;
    FToken: string;
    FMachine: string;
    FCommitter: string;
    FDebounceMs: Integer;
    FGcEvery: Integer;
    FPullIntervalMs: Integer;
    FHistoryCap: Integer;
    FLfsThresholdMB: Integer;
    FLfsChecked: Boolean;       // have we probed git-lfs availability yet?
    FLfsOk: Boolean;            // is git-lfs available?
    FAutoSync: Boolean;         // True = auto add/commit/trim; False = managed
    FStatus: TStatusModel;
    FIgnore: TStringList;
    FWatcher: TFileWatcher;
    FLock: TCriticalSection;
    FDirty: Boolean;
    FForce: Boolean;
    FLastChange: TDateTime;
    FLastCycle: TDateTime;
    FLastFull: TDateTime;         // last time a full sync cycle actually ran
    FBranch: string;              // this repo's branch (main/master/...), resolved live
    FSyncedRemoteSha: string;     // origin/<branch> tip as of our last in-sync cycle
    FCommitsSinceGc: Integer;
    FOfflineStreak: Integer;      // consecutive network-failure cycles (hysteresis)
    FOversize: TStringList;       // files blocked for exceeding GitHub's 100 MB limit
    FOversizeNotified: Boolean;   // fired the "file too large" notice yet?
    FErrorStreak: Integer;        // consecutive hard-error cycles (drives backoff)
    FBackoffUntil: TDateTime;     // suppress cycles for a failing repo until this time
    FStuckNotified: Boolean;      // fired the "repo is stuck" notice yet?
    FOnNotice: TSyncNoticeEvent;
    FOnReposChanged: TReposChangedEvent;
    FOnCycleDone: TCycleDoneEvent;
    procedure OnWatchChange(Sender: TObject);
    procedure BuildNotice(AFiles: TStrings; out ATitle, ABody: string);
    function RemoteAdvanced: Boolean;
    procedure DoSyncCycle;
  protected
    procedure Execute; override;
  public
    constructor Create(const AName, ALocalPath, AUser, AToken, AMachine: string;
      ADebounceMs, AGcEvery, APullIntervalSec, AHistoryCap, ALfsThresholdMB: Integer;
      AAutoSync: Boolean; AStatus: TStatusModel; AIgnore: TStrings);
    destructor Destroy; override;
    { Request an immediate sync (e.g. the user chose "Sync now"). }
    procedure RequestSync;
    { Signal the thread to finish and stop watching. }
    procedure Stop;
    property RepoName: string read FName;
    property OnNotice: TSyncNoticeEvent read FOnNotice write FOnNotice;
    property OnReposChanged: TReposChangedEvent
      read FOnReposChanged write FOnReposChanged;
    property OnCycleDone: TCycleDoneEvent read FOnCycleDone write FOnCycleDone;
  end;

implementation

uses
  gboxlog, gboxsuper;

function BackoffDelayMs(AStreak, ABaseMs, AMaxMs: Integer): Integer;
var
  mult, k: Integer;
begin
  if AStreak < 1 then Exit(0);
  mult := 1;
  for k := 1 to AStreak - 1 do
    if mult <= AMaxMs div ABaseMs then mult := mult * 2;   // stop doubling past cap
  Result := ABaseMs * mult;
  if Result > AMaxMs then Result := AMaxMs;
end;

{ Build a notification for the files synced this cycle: list up to 3 names,
  otherwise just the count. Submodule files are prefixed with the repo name. }
procedure TRepoWorker.BuildNotice(AFiles: TStrings; out ATitle, ABody: string);
var
  i: Integer;
  prefix: string;
begin
  ATitle := 'GotBox - synced';
  ABody := '';
  if AFiles.Count = 0 then Exit;
  if FName = GOTBOX_REPO then prefix := ''
  else
    prefix := FName + '/';
  if AFiles.Count <= 3 then
  begin
    for i := 0 to AFiles.Count - 1 do
    begin
      if i > 0 then ABody := ABody + LineEnding;
      ABody := ABody + prefix + AFiles[i];
    end;
  end
  else if FName = GOTBOX_REPO then
    ABody := Format('Synced %d files', [AFiles.Count])
  else
    ABody := Format('Synced %d files in %s', [AFiles.Count, FName]);
end;

constructor TRepoWorker.Create(const AName, ALocalPath, AUser, AToken, AMachine: string;
  ADebounceMs, AGcEvery, APullIntervalSec, AHistoryCap, ALfsThresholdMB: Integer;
  AAutoSync: Boolean; AStatus: TStatusModel; AIgnore: TStrings);
begin
  inherited Create(True);            // suspended; caller calls Start
  FreeOnTerminate := False;
  FName := AName;
  FLocalPath := ALocalPath;
  FUser := AUser;
  FToken := AToken;
  FMachine := AMachine;
  FAutoSync := AAutoSync;
  FCommitter := AUser;
  if FCommitter = '' then FCommitter := AMachine;
  if FCommitter = '' then FCommitter := 'gotbox';
  FDebounceMs := ADebounceMs;
  FGcEvery := AGcEvery;
  FPullIntervalMs := APullIntervalSec * 1000;
  FHistoryCap := AHistoryCap;
  FLfsThresholdMB := ALfsThresholdMB;
  FBranch := 'main';   // resolved from the actual checkout on the first cycle
  FStatus := AStatus;
  FLock := TCriticalSection.Create;
  FOversize := TStringList.Create;
  FOversize.Sorted := True;
  FOversize.Duplicates := dupIgnore;
  FIgnore := TStringList.Create;
  if Assigned(AIgnore) then FIgnore.Assign(AIgnore);
  FWatcher := CreateFileWatcher(FLocalPath, FIgnore);
  FWatcher.OnChanged := @OnWatchChange;
end;

destructor TRepoWorker.Destroy;
begin
  FWatcher.Free;
  FIgnore.Free;
  FOversize.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TRepoWorker.OnWatchChange(Sender: TObject);
begin
  // called from the watcher thread; just record the debounce timestamp
  FLock.Enter;
  try
    FDirty := True;
    FLastChange := Now;
  finally
    FLock.Leave;
  end;
end;

procedure TRepoWorker.RequestSync;
begin
  FLock.Enter;
  try
    FForce := True;
  finally
    FLock.Leave;
  end;
end;

procedure TRepoWorker.Stop;
begin
  Terminate;
end;

{ Cheap remote-tip probe for the periodic sync-down: a single `ls-remote` round
  trip (no fetch/transfer). True -> run a full cycle: the remote branch moved
  since our last in-sync cycle, we've never synced, or the probe failed
  (offline/unknown -- let the full cycle resolve it). False -> nothing changed,
  skip the full cycle. Lets short pull intervals stay cheap. }
function TRepoWorker.RemoteAdvanced: Boolean;
var
  git: TGitRunner;
  r: TGitResult;
  sha: string;
  p: Integer;
begin
  if FSyncedRemoteSha = '' then Exit(True);   // never synced -> full cycle
  git := TGitRunner.Create(FLocalPath);
  try
    git.AuthUser := FUser;
    git.AuthToken := FToken;
    git.DefaultTimeoutMs := GIT_DEFAULT_TIMEOUT_MS;
    r := git.GitQuiet(['ls-remote', 'origin', 'refs/heads/' + FBranch]);
    if not r.Ok then Exit(True);               // can't tell -> full cycle
    sha := Trim(r.StdOut);
    p := Pos(#9, sha);                          // "<sha>\trefs/heads/<branch>"
    if p > 1 then sha := Copy(sha, 1, p - 1);
    if sha = '' then Exit(True);               // no remote branch yet -> full cycle
    Result := (sha <> FSyncedRemoteSha);
  finally
    git.Free;
  end;
end;

procedure TRepoWorker.DoSyncCycle;
const
  TRAY_SYNC_MIN_MS = 450;   // keep "syncing" visible even for an instant cycle
  OFFLINE_GRACE = 2;        // show "offline" only after this many consecutive
  // network failures (ignore isolated transient blips)
  BACKOFF_BASE_MS = 15000;  // first hard-error wait; doubles each further failure
  BACKOFF_MAX_MS = 300000;  // ...capped at 5 min so a failing repo stops hammering
  STUCK_AFTER = 5;          // after this many consecutive errors, flag "stuck" + notify
var
  git: TGitRunner;
  outcome: TSyncOutcome;
  detail, td, ntitle, nbody, elc: string;
  conflicts, changed: TStringList;
  syncStart: TDateTime;
  delayMs, k: Integer;
  contention: Boolean;
begin
  // A submodule whose working folder the user deleted: stop syncing it rather
  // than spinning on a missing directory (git would just fail every cycle). The
  // root worker unlinks it from the superproject; we simply retire this worker.
  if (FName <> GOTBOX_REPO) and (not DirectoryExists(FLocalPath)) then
  begin
    if Assigned(Log) then
      Log.Info('worker', FName + ': working folder removed; stopping sync (unlinked)');
    if Assigned(FStatus) then FStatus.Remove(FName);
    Terminate;
    Exit;
  end;

  if Assigned(FStatus) then FStatus.SetState(FName, rsSyncing, '');
  syncStart := Now;
  FLastFull := Now;   // a full cycle is running now (paces the periodic safety net)
  conflicts := TStringList.Create;
  changed := TStringList.Create;
  git := TGitRunner.Create(FLocalPath);
  try
    git.AuthUser := FUser;
    git.AuthToken := FToken;
    // bound every git op so a stuck one (e.g. a Windows file-lock deadlock on a
    // shared repo) can't hang this worker thread -- and thus engine.Stop's join
    // -- indefinitely; it fails the cycle instead and retries next time.
    git.DefaultTimeoutMs := GIT_DEFAULT_TIMEOUT_MS;

    // Resolve the branch this repo actually lives on (main, master, ...), so a
    // linked existing repo that defaults to a non-main branch syncs correctly.
    // `push origin HEAD` already targets the right branch; this makes the
    // origin/<branch> comparisons match it.
    FBranch := git.CurrentBranch;
    if (FBranch = '') or (FBranch = 'HEAD') then FBranch := 'main';

    if FAutoSync then
    begin
      // ensure a committer identity so commits succeed even with no global git
      // config (e.g. submodule checkouts, fresh machines, CI runners)
      git.Git(['config', 'user.name', FCommitter]);
      git.Git(['config', 'user.email', FCommitter + '@gotbox.local']);

      // Register oversized files with Git LFS before the cycle commits them, so
      // they become LFS pointers instead of blowing GitHub's 100 MB push limit.
      if not FLfsChecked then
      begin
        FLfsChecked := True;
        FLfsOk := LfsAvailable(git);
        if (not FLfsOk) and Assigned(Log) then
          Log.Warn('worker', FName + ': git-lfs not installed; files over ' +
            '100 MB cannot be synced (install git-lfs)');
      end;
      if (FLfsThresholdMB > 0) and FLfsOk then
        TrackLargeFiles(git, Int64(FLfsThresholdMB) * 1024 * 1024);

      // Guard GitHub's hard 100 MB per-file limit: any working-tree file at/over
      // it that LFS is NOT going to absorb is excluded from the commit (so we
      // never record a doomed blob that fails every push forever) and surfaced as
      // a clear error below. When LFS will handle oversized files (installed +
      // threshold in 1..100), clear any prior block so those files sync normally.
      if FLfsOk and (FLfsThresholdMB > 0) and (FLfsThresholdMB <= 100) then
      begin
        if FOversize.Count > 0 then
        begin
          FOversize.Clear;
          WriteExcludeBlock(git, FOversize);
        end;
        FOversizeNotified := False;
      end
      else
      begin
        FindOversizeUnhandled(git, GITHUB_FILE_LIMIT, FOversize);
        WriteExcludeBlock(git, FOversize);
      end;

      outcome := RunSyncCycle(git, FMachine, detail, conflicts, changed, FBranch);
    end
    else
      // managed: transport committed state only -- never set the user's git
      // identity, touch LFS, stage, commit, or trim history (RunManagedCycle)
      outcome := RunManagedCycle(git, detail, changed, FBranch);

    // notify about files synced this cycle (added/modified, up or down)
    if (outcome in [soPushed, soPulled, soMerged, soReset]) and
      (changed.Count > 0) and Assigned(FOnNotice) then
    begin
      BuildNotice(changed, ntitle, nbody);
      if nbody <> '' then FOnNotice(ntitle, nbody);
    end;

    // Keep the "syncing" state visible for a moment on cycles that actually
    // transferred data, so a quick edit shows a real blue->green change instead
    // of appearing static (a fast local commit+push flips syncing->synced faster
    // than the tray refresh, coalescing the transient away). Idle no-op checks
    // (soUpToDate) don't hold, so periodic pulls don't flash the tray.
    if (outcome in [soPushed, soPulled, soMerged, soReset, soConflict]) and
      (MilliSecondsBetween(Now, syncStart) < TRAY_SYNC_MIN_MS) then
      Sleep(TRAY_SYNC_MIN_MS - MilliSecondsBetween(Now, syncStart));

    case outcome of
      soError:
      begin
        // A push losing a race with another machine (remote advanced between our
        // fetch and push) is transient contention, not a stuck repo: retry soon
        // and don't escalate toward "stuck". A genuine hard error (oversize file,
        // corrupt object, auth) escalates an exponential backoff so it stops
        // hammering the remote every interval, and after STUCK_AFTER failures it
        // is flagged + notified once.
        elc := LowerCase(detail);
        contention := (Pos('rejected', elc) > 0) or (Pos('fetch first', elc) > 0) or
          (Pos('non-fast-forward', elc) > 0) or (Pos('stale info', elc) > 0);
        if contention then
        begin
          FBackoffUntil := IncMilliSecond(Now, 1000 + Random(2000));
          if Assigned(FStatus) then FStatus.SetState(FName, rsSyncing,
              'remote moved during push; retrying');
        end
        else
        begin
          Inc(FErrorStreak);
          // A corrupt local object store won't heal by retrying. For an auto-sync
          // repo, rebuild it from origin in place (preserving uncommitted edits as
          // "(recovered ...)" copies); if that succeeds the repo is usable again,
          // so clear the error and let the next cycle sync normally. If recovery
          // can't run (offline / managed repo), surface a clear "re-clone" state.
          if IsCorruptionError(detail) then
          begin
            if FAutoSync and RecloneCorruptRepo(git, FBranch, FMachine, td, k) then
            begin
              if Assigned(Log) then Log.Info('worker', FName + ': ' + td);
              if Assigned(FOnNotice) then
                FOnNotice('GotBox - repaired ' + FName,
                  'Rebuilt from the remote after local corruption; ' +
                  IntToStr(k) + ' edited file(s) kept as "(recovered ...)" copies');
              FErrorStreak := 0;
              FBackoffUntil := 0;
              FStuckNotified := False;
              if Assigned(FStatus) then FStatus.SetState(FName, rsSynced, 'recovered');
              detail := '';   // handled
            end
            else
            begin
              detail := 'repository data is corrupted -- re-clone this folder to ' +
                'recover (' + detail + ')';
              if FErrorStreak < STUCK_AFTER then FErrorStreak := STUCK_AFTER;
            end;
          end;
          // detail cleared above means corruption was auto-recovered -- leave the
          // "recovered" state as set and skip the backoff/error path entirely.
          if detail <> '' then
          begin
            delayMs := BackoffDelayMs(FErrorStreak, BACKOFF_BASE_MS, BACKOFF_MAX_MS);
            delayMs := delayMs + Random(delayMs div 5 + 1);   // +0..20% jitter
            FBackoffUntil := IncMilliSecond(Now, delayMs);
            if Assigned(FStatus) then
              if FErrorStreak >= STUCK_AFTER then
                FStatus.SetState(FName, rsError,
                  Format('%s (stuck after %d tries)', [detail, FErrorStreak]))
              else
                FStatus.SetState(FName, rsError, detail);
            if Assigned(Log) then Log.Warn('worker', FName + ': ' + detail);
            if (FErrorStreak = STUCK_AFTER) and (not FStuckNotified) then
            begin
              if Assigned(FOnNotice) then
                FOnNotice('GotBox - sync problem', FName + ': ' + detail);
              FStuckNotified := True;
            end;
          end;
        end;
      end;
      soOffline:
      begin
        // Network failure. Local work is committed; we retry next cycle. Only
        // show "offline" after OFFLINE_GRACE consecutive failures, so a single
        // transient blip (a DNS hiccup, a dropped fetch on the frequent poll)
        // doesn't flicker the icon. Below the threshold, stay optimistic.
        Inc(FOfflineStreak);
        if FOfflineStreak >= OFFLINE_GRACE then
        begin
          if Assigned(FStatus) then FStatus.SetState(FName, rsOffline, detail);
          if Assigned(Log) then Log.Info('worker', FName + ': ' + detail);
        end
        else if Assigned(FStatus) then
          FStatus.SetState(FName, rsSynced, 'transient network blip; retrying');
      end;
      soConflict:
      begin
        if Assigned(FStatus) then
        begin
          FStatus.SetConflicts(FName, True);
          FStatus.SetState(FName, rsConflict,
            Format('%d conflict(s) -- kept both', [conflicts.Count]));
          FStatus.TouchSync(FName);
        end;
        if Assigned(Log) then
          Log.Warn('worker', Format('%s: kept both for %d file(s)',
            [FName, conflicts.Count]));
      end;
      else
      begin
        if Assigned(FStatus) then
        begin
          FStatus.SetState(FName, rsSynced, SyncOutcomeText(outcome));
          FStatus.TouchSync(FName);
        end;
        if (outcome in [soPushed, soPulled, soMerged]) and Assigned(Log) then
          Log.Info('worker', FName + ': ' + SyncOutcomeText(outcome));
      end;
    end;

    if outcome <> soOffline then
      FOfflineStreak := 0;   // any reachable-remote outcome clears the streak

    // a healthy cycle clears the hard-error backoff/stuck state
    if not (outcome in [soError, soOffline]) then
    begin
      FErrorStreak := 0;
      FBackoffUntil := 0;
      FStuckNotified := False;
    end;

    // A file too large for GitHub that LFS can't absorb is a persistent local
    // problem the user must fix: it was kept out of the commit, so the rest of
    // the repo still syncs, but keep the repo flagged (overriding the cycle's
    // "synced") and notify once so the user knows why that file isn't syncing.
    if (FOversize.Count > 0) and (outcome <> soOffline) then
    begin
      td := 'file too large for GitHub (>100 MB) without git-lfs: ' + FOversize[0];
      if FOversize.Count > 1 then
        td := td + Format(' (+%d more)', [FOversize.Count - 1]);
      if Assigned(FStatus) then FStatus.SetState(FName, rsError,
          td + ' -- install git-lfs to sync it');
      if (not FOversizeNotified) then
      begin
        if Assigned(FOnNotice) then
          FOnNotice('GotBox - file too large to sync', td);
        FOversizeNotified := True;
      end;
    end;

    // Remember the remote tip while we're fully in sync, so the periodic
    // ls-remote fast-check (RemoteAdvanced) can skip the full cycle when nothing
    // has changed remotely. Clear it on failure so the next check runs a full
    // cycle (retries the push/fetch).
    if outcome in [soUpToDate, soPushed, soPulled, soMerged, soReset, soConflict] then
      FSyncedRemoteSha :=
        Copy(Trim(git.GitQuiet(['rev-parse', 'origin/' + FBranch]).StdOut), 1, 64)
    else
      FSyncedRemoteSha := '';

    // a pull into the root may have added/removed submodules (.gitmodules
    // changed elsewhere) -- let the engine re-scan and reconcile its workers
    if (FName = GOTBOX_REPO) and (outcome in [soPulled, soMerged, soReset]) and
      Assigned(FOnReposChanged) then
      FOnReposChanged();

    // maintenance: gc periodically after cycles that produced commits
    if outcome in [soPushed, soMerged, soConflict] then
      Inc(FCommitsSinceGc);
    if (FGcEvery > 0) and (FCommitsSinceGc >= FGcEvery) then
    begin
      git.Gc;
      FCommitsSinceGc := 0;
    end;

    // cap history once it has grown well past the limit (squash + force-push).
    // Skip while offline -- the force-push would just fail without a network.
    // Managed repos are NEVER trimmed: rewriting the user's history is exactly
    // what managed mode exists to prevent.
    if FAutoSync and (outcome <> soError) and (outcome <> soOffline) and
      ShouldTrim(git, FHistoryCap) then
    begin
      if TrimHistory(git, FHistoryCap, td, FBranch) then
      begin
        if Assigned(FStatus) then FStatus.SetState(FName, rsSynced, 'history trimmed');
      end
      else if Assigned(Log) then
        Log.Warn('worker', FName + ' trim: ' + td);
    end;

    // let the owner refresh the file-manager overlay cache for this repo
    if Assigned(FOnCycleDone) then FOnCycleDone(FLocalPath);
  finally
    git.Free;
    conflicts.Free;
    changed.Free;
  end;
end;

procedure TRepoWorker.Execute;
const
  PERIODIC_FULL_MS = 300000;   // force a full cycle at least every 5 min anyway
var
  due, active, periodic, forced: Boolean;
begin
  FWatcher.Start;
  try
    FLastCycle := Now;
    // commit/push anything already pending, and pull remote state, on startup
    RequestSync;
    while not Terminated do
    begin
      // A repo that just hit a hard error backs off (exponentially): skip cycles
      // until FBackoffUntil so we don't hammer the remote every interval. An
      // explicit "Sync now" (FForce) always breaks through and is handled below;
      // pending local changes and the periodic timer are left untouched so they
      // fire as soon as the backoff expires.
      FLock.Enter;
      forced := FForce;
      FLock.Leave;
      if (FBackoffUntil > 0) and (Now < FBackoffUntil) and (not forced) then
      begin
        Sleep(150);
        Continue;
      end;

      active := False;     // "sync now" or a debounced local change -> full cycle
      periodic := False;   // periodic sync-down -> gated by the cheap fast-check
      FLock.Enter;
      try
        if FForce then
        begin
          FForce := False;
          FDirty := False;
          active := True;
        end
        else if FDirty and (MilliSecondsBetween(Now, FLastChange) >= FDebounceMs) then
        begin
          FDirty := False;
          active := True;
        end
        else if (FPullIntervalMs > 0) and
          (MilliSecondsBetween(Now, FLastCycle) >= FPullIntervalMs) then
          periodic := True;
      finally
        FLock.Leave;
      end;

      due := active;
      if periodic then
      begin
        FLastCycle := Now;   // consume the periodic timer even when we skip below
        // Run a full cycle at least every PERIODIC_FULL_MS (refreshes state and
        // catches a change the watcher missed); otherwise only when the remote
        // actually advanced -- a cheap ls-remote probe -- so a short pull interval
        // doesn't fetch/spawn git every tick while nothing has changed.
        if (MilliSecondsBetween(Now, FLastFull) >= PERIODIC_FULL_MS) or
          RemoteAdvanced then
          due := True;
      end;

      if due then
      begin
        try
          DoSyncCycle;
        except
          on E: Exception do
            if Assigned(Log) then Log.Error('worker', FName + ': ' + E.Message);
        end;
        FLastCycle := Now;
      end;

      Sleep(150);
    end;
  finally
    FWatcher.Stop;
  end;
end;

end.
