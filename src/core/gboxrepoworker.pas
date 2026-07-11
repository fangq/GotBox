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
  gboxgitrunner, gboxfilewatcher, gboxstatusmodel, gboxsync, gboxhistory, gboxlfs;

type
  { Fired (on the worker thread) after a cycle that synced files, with a ready-
    to-show notification title/body. The handler must marshal to the GUI. }
  TSyncNoticeEvent = procedure(const ATitle, ABody: string) of object;
  { Fired (on the worker thread) by the ROOT worker after a cycle that pulled
    remote changes, so the engine can re-scan .gitmodules and add/drop submodule
    workers. The handler must marshal any UI/engine work to the main thread. }
  TReposChangedEvent = procedure of object;

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
    FStatus: TStatusModel;
    FIgnore: TStringList;
    FWatcher: TFileWatcher;
    FLock: TCriticalSection;
    FDirty: Boolean;
    FForce: Boolean;
    FLastChange: TDateTime;
    FLastCycle: TDateTime;
    FCommitsSinceGc: Integer;
    FOnNotice: TSyncNoticeEvent;
    FOnReposChanged: TReposChangedEvent;
    procedure OnWatchChange(Sender: TObject);
    procedure BuildNotice(AFiles: TStrings; out ATitle, ABody: string);
    procedure DoSyncCycle;
  protected
    procedure Execute; override;
  public
    constructor Create(const AName, ALocalPath, AUser, AToken, AMachine: string;
      ADebounceMs, AGcEvery, APullIntervalSec, AHistoryCap, ALfsThresholdMB: Integer;
      AStatus: TStatusModel; AIgnore: TStrings);
    destructor Destroy; override;
    { Request an immediate sync (e.g. the user chose "Sync now"). }
    procedure RequestSync;
    { Signal the thread to finish and stop watching. }
    procedure Stop;
    property RepoName: string read FName;
    property OnNotice: TSyncNoticeEvent read FOnNotice write FOnNotice;
    property OnReposChanged: TReposChangedEvent
      read FOnReposChanged write FOnReposChanged;
  end;

implementation

uses
  gboxlog, gboxsuper;

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
  AStatus: TStatusModel; AIgnore: TStrings);
begin
  inherited Create(True);            // suspended; caller calls Start
  FreeOnTerminate := False;
  FName := AName;
  FLocalPath := ALocalPath;
  FUser := AUser;
  FToken := AToken;
  FMachine := AMachine;
  FCommitter := AUser;
  if FCommitter = '' then FCommitter := AMachine;
  if FCommitter = '' then FCommitter := 'gotbox';
  FDebounceMs := ADebounceMs;
  FGcEvery := AGcEvery;
  FPullIntervalMs := APullIntervalSec * 1000;
  FHistoryCap := AHistoryCap;
  FLfsThresholdMB := ALfsThresholdMB;
  FStatus := AStatus;
  FLock := TCriticalSection.Create;
  FIgnore := TStringList.Create;
  if Assigned(AIgnore) then FIgnore.Assign(AIgnore);
  FWatcher := CreateFileWatcher(FLocalPath, FIgnore);
  FWatcher.OnChanged := @OnWatchChange;
end;

destructor TRepoWorker.Destroy;
begin
  FWatcher.Free;
  FIgnore.Free;
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

procedure TRepoWorker.DoSyncCycle;
var
  git: TGitRunner;
  outcome: TSyncOutcome;
  detail, td, ntitle, nbody: string;
  conflicts, changed: TStringList;
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
  conflicts := TStringList.Create;
  changed := TStringList.Create;
  git := TGitRunner.Create(FLocalPath);
  try
    git.AuthUser := FUser;
    git.AuthToken := FToken;

    // ensure a committer identity so commits succeed even with no global git
    // config (e.g. submodule checkouts, fresh machines, CI runners)
    git.Git(['config', 'user.name', FCommitter]);
    git.Git(['config', 'user.email', FCommitter + '@gotbox.local']);

    // Register oversized files with Git LFS before the cycle commits them, so
    // they become LFS pointers instead of blowing GitHub's 100 MB push limit.
    if FLfsThresholdMB > 0 then
    begin
      if not FLfsChecked then
      begin
        FLfsChecked := True;
        FLfsOk := LfsAvailable(git);
        if (not FLfsOk) and Assigned(Log) then
          Log.Warn('worker', FName + ': git-lfs not installed; files over ' +
            IntToStr(FLfsThresholdMB) + ' MB may be rejected on push');
      end;
      if FLfsOk then
        TrackLargeFiles(git, Int64(FLfsThresholdMB) * 1024 * 1024);
    end;

    outcome := RunSyncCycle(git, FMachine, detail, conflicts, changed);

    // notify about files synced this cycle (added/modified, up or down)
    if (outcome in [soPushed, soPulled, soMerged, soReset]) and
      (changed.Count > 0) and Assigned(FOnNotice) then
    begin
      BuildNotice(changed, ntitle, nbody);
      if nbody <> '' then FOnNotice(ntitle, nbody);
    end;

    case outcome of
      soError:
      begin
        if Assigned(FStatus) then FStatus.SetState(FName, rsError, detail);
        if Assigned(Log) then Log.Warn('worker', FName + ': ' + detail);
      end;
      soOffline:
      begin
        // transient no-network: local work is committed; we retry next cycle.
        // Not an error -- show a distinct "offline" state, log quietly.
        if Assigned(FStatus) then FStatus.SetState(FName, rsOffline, detail);
        if Assigned(Log) then Log.Info('worker', FName + ': ' + detail);
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
    if (outcome <> soError) and (outcome <> soOffline) and
      ShouldTrim(git, FHistoryCap) then
    begin
      if TrimHistory(git, FHistoryCap, td) then
      begin
        if Assigned(FStatus) then FStatus.SetState(FName, rsSynced, 'history trimmed');
      end
      else if Assigned(Log) then
        Log.Warn('worker', FName + ' trim: ' + td);
    end;
  finally
    git.Free;
    conflicts.Free;
    changed.Free;
  end;
end;

procedure TRepoWorker.Execute;
var
  due: Boolean;
begin
  FWatcher.Start;
  try
    FLastCycle := Now;
    // commit/push anything already pending, and pull remote state, on startup
    RequestSync;
    while not Terminated do
    begin
      due := False;
      FLock.Enter;
      try
        if FForce then
        begin
          FForce := False;
          FDirty := False;
          due := True;
        end
        else if FDirty and (MilliSecondsBetween(Now, FLastChange) >= FDebounceMs) then
        begin
          FDirty := False;
          due := True;
        end
        else if (FPullIntervalMs > 0) and
          (MilliSecondsBetween(Now, FLastCycle) >= FPullIntervalMs) then
          due := True;   // periodic sync-down
      finally
        FLock.Leave;
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
