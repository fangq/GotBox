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
  gboxconfigstore, gboxstatusmodel, gboxrepoworker, gboxsuper;

type
  TSyncEngine = class
  private
    FCfg: TGotConfig;
    FToken: string;
    FStatus: TStatusModel;
    FWorkers: array of TRepoWorker;
    FRunning: Boolean;
    function LocalPathOf(const AName: string): string;
    procedure SpawnWorker(const AName, APath: string; AExtraIgnore: TStrings);
  public
    constructor Create(ACfg: TGotConfig; const AToken: string; AStatus: TStatusModel);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    procedure SyncAllNow;
    procedure SyncRepo(const AName: string);
    property Running: Boolean read FRunning;
    function WorkerCount: Integer;
  end;

{ True if APath is a git working tree (a submodule's .git is a FILE, the
  superproject's is a directory -- accept either). }
function IsGitWorkTree(const APath: string): Boolean;

implementation

uses
  gboxlog;

function IsGitWorkTree(const APath: string): Boolean;
var
  dot: string;
begin
  dot := IncludeTrailingPathDelimiter(APath) + '.git';
  Result := DirectoryExists(dot) or FileExists(dot);
end;

constructor TSyncEngine.Create(ACfg: TGotConfig; const AToken: string;
  AStatus: TStatusModel);
begin
  inherited Create;
  FCfg := ACfg;
  FToken := AToken;
  FStatus := AStatus;
end;

destructor TSyncEngine.Destroy;
begin
  Stop;
  inherited Destroy;
end;

function TSyncEngine.LocalPathOf(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FCfg.RootDir) + AName;
end;

procedure TSyncEngine.SpawnWorker(const AName, APath: string; AExtraIgnore: TStrings);
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
      FCfg.PullIntervalSec, FCfg.HistoryCap, FStatus, ignore);
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
  paused: Boolean;
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

  // 1) root worker: sync loose files, excluding the submodule directories
  subNames := TStringList.Create;
  try
    for i := 0 to High(subs) do
      subNames.Add(subs[i].LocalName);
    SpawnWorker(GOTBOX_REPO, FCfg.RootDir, subNames);
  finally
    subNames.Free;
  end;

  // 2) one worker per submodule (honour the per-submodule Paused flag)
  for i := 0 to High(subs) do
  begin
    paused := FCfg.FindRepo(subs[i].LocalName, entry) and entry.Paused;
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
    SpawnWorker(subs[i].LocalName, LocalPathOf(subs[i].LocalName), nil);
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
  for i := 0 to High(FWorkers) do
    FWorkers[i].Stop;
  for i := 0 to High(FWorkers) do
  begin
    FWorkers[i].WaitFor;
    FWorkers[i].Free;
  end;
  SetLength(FWorkers, 0);
  FRunning := False;
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
