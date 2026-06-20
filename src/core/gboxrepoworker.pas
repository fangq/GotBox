unit gboxrepoworker;

{ One background thread per repo. Watches the working tree (via TFileWatcher),
  debounces bursts of saves, then auto-commits and pushes. Runs periodic `git
  gc` for maintenance.

  Milestone 5 scope: local change -> commit -> push. If the push is rejected
  because the remote moved on, it is reported as an error for now; fetch/merge
  and keep-both conflict handling arrive in milestone 6. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, SyncObjs,
  gboxgitrunner, gboxfilewatcher, gboxstatusmodel;

type
  TRepoWorker = class(TThread)
  private
    FName: string;
    FLocalPath: string;
    FUser: string;
    FToken: string;
    FMachine: string;
    FDebounceMs: Integer;
    FGcEvery: Integer;
    FStatus: TStatusModel;
    FIgnore: TStringList;
    FWatcher: TFileWatcher;
    FLock: TCriticalSection;
    FDirty: Boolean;
    FForce: Boolean;
    FLastChange: TDateTime;
    FCommitsSinceGc: Integer;
    procedure OnWatchChange(Sender: TObject);
    procedure DoSyncCycle;
  protected
    procedure Execute; override;
  public
    constructor Create(const AName, ALocalPath, AUser, AToken, AMachine: string;
      ADebounceMs, AGcEvery: Integer; AStatus: TStatusModel; AIgnore: TStrings);
    destructor Destroy; override;
    { Request an immediate sync (e.g. the user chose "Sync now"). }
    procedure RequestSync;
    { Signal the thread to finish and stop watching. }
    procedure Stop;
    property RepoName: string read FName;
  end;

implementation

uses
  gboxlog;

constructor TRepoWorker.Create(const AName, ALocalPath, AUser, AToken, AMachine: string;
  ADebounceMs, AGcEvery: Integer; AStatus: TStatusModel; AIgnore: TStrings);
begin
  inherited Create(True);            // suspended; caller calls Start
  FreeOnTerminate := False;
  FName := AName;
  FLocalPath := ALocalPath;
  FUser := AUser;
  FToken := AToken;
  FMachine := AMachine;
  FDebounceMs := ADebounceMs;
  FGcEvery := AGcEvery;
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
  r: TGitResult;
  committed: Boolean;
begin
  if Assigned(FStatus) then FStatus.SetState(FName, rsSyncing, '');
  git := TGitRunner.Create(FLocalPath);
  try
    git.AuthUser := FUser;
    git.AuthToken := FToken;
    committed := False;

    if git.HasUncommittedChanges then
    begin
      git.AddAll;
      r := git.CommitAll(Format('%s %s', [FMachine,
        FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)]));
      committed := r.Ok;
      if committed then Inc(FCommitsSinceGc);
    end;

    r := git.Push(False);
    if r.Ok then
    begin
      if Assigned(FStatus) then
      begin
        FStatus.SetState(FName, rsSynced, '');
        FStatus.TouchSync(FName);
      end;
    end
    else
    begin
      // remote likely moved on -- real reconciliation comes in milestone 6
      if Assigned(FStatus) then
        FStatus.SetState(FName, rsError, 'push failed: ' + Trim(r.StdErr));
      if Assigned(Log) then
        Log.Warn('worker', FName + ' push failed: ' + Trim(r.StdErr));
    end;

    if (FGcEvery > 0) and (FCommitsSinceGc >= FGcEvery) then
    begin
      git.Gc;
      FCommitsSinceGc := 0;
    end;

    if committed and Assigned(Log) then
      Log.Info('worker', FName + ' committed + pushed');
  finally
    git.Free;
  end;
end;

procedure TRepoWorker.Execute;
var
  due: Boolean;
begin
  FWatcher.Start;
  try
    // commit/push anything already pending when we start
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
        end;
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
      end;

      Sleep(150);
    end;
  finally
    FWatcher.Stop;
  end;
end;

end.
