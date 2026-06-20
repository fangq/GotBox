unit gboxengine;

{ Orchestrator: spawns one TRepoWorker per linked, non-paused repo that exists
  locally, and offers start/stop/sync-all. The GUI owns a single TSyncEngine. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  gboxconfigstore, gboxstatusmodel, gboxrepoworker;

type
  TSyncEngine = class
  private
    FCfg: TGotConfig;
    FToken: string;
    FStatus: TStatusModel;
    FWorkers: array of TRepoWorker;
    FRunning: Boolean;
    function LocalPathOf(const AName: string): string;
  public
    constructor Create(ACfg: TGotConfig; const AToken: string; AStatus: TStatusModel);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    procedure SyncAllNow;
    property Running: Boolean read FRunning;
    function WorkerCount: Integer;
  end;

implementation

uses
  gboxlog;

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

procedure TSyncEngine.Start;
var
  i: Integer;
  path: string;
  w: TRepoWorker;
begin
  if FRunning then Exit;
  SetLength(FWorkers, 0);
  for i := 0 to High(FCfg.Repos) do
  begin
    if FCfg.Repos[i].Paused then Continue;
    path := LocalPathOf(FCfg.Repos[i].LocalName);
    if not DirectoryExists(IncludeTrailingPathDelimiter(path) + '.git') then
    begin
      if Assigned(FStatus) then
        FStatus.SetState(FCfg.Repos[i].LocalName, rsError, 'no local clone');
      Continue;
    end;
    w := TRepoWorker.Create(FCfg.Repos[i].LocalName, path, FCfg.GithubUser,
      FToken, FCfg.MachineName, FCfg.CommitDebounceMs, FCfg.GcEveryNCommits,
      FCfg.PullIntervalSec, FStatus, FCfg.IgnoreGlobs);
    SetLength(FWorkers, Length(FWorkers) + 1);
    FWorkers[High(FWorkers)] := w;
    w.Start;
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

function TSyncEngine.WorkerCount: Integer;
begin
  Result := Length(FWorkers);
end;

end.
