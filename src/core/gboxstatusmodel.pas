unit gboxstatusmodel;

{ Lock-protected, observable snapshot of per-repo sync state. Worker threads
  update it; the GUI reads snapshots on the main thread. The OnChanged callback
  is invoked (queued onto the main thread by the caller) so the UI can refresh. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  TRepoState = (rsIdle, rsSyncing, rsSynced, rsConflict, rsError, rsPaused);

  TRepoStatus = record
    LocalName: string;
    State: TRepoState;
    LastSync: TDateTime;
    PendingChanges: Integer;
    Detail: string;        // last action / error text
    HasConflicts: Boolean;
  end;
  TRepoStatusArray = array of TRepoStatus;

  TStatusChangedEvent = procedure of object;

  TStatusModel = class
  private
    FLock: TCriticalSection;
    FItems: TRepoStatusArray;
    FOnChanged: TStatusChangedEvent;
    function IndexOf(const ALocalName: string): Integer;
    procedure Notify;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetState(const ALocalName: string; AState: TRepoState;
      const ADetail: string = '');
    procedure SetPending(const ALocalName: string; ACount: Integer);
    procedure SetConflicts(const ALocalName: string; AHas: Boolean);
    procedure TouchSync(const ALocalName: string);
    procedure Remove(const ALocalName: string);
    function Snapshot: TRepoStatusArray;
    { Aggregate state for the tray icon: worst of all repos. }
    function AggregateState: TRepoState;
    property OnChanged: TStatusChangedEvent read FOnChanged write FOnChanged;
  end;

function RepoStateText(AState: TRepoState): string;

implementation

function RepoStateText(AState: TRepoState): string;
begin
  case AState of
    rsIdle: Result := 'Idle';
    rsSyncing: Result := 'Syncing';
    rsSynced: Result := 'Synced';
    rsConflict: Result := 'Conflict';
    rsError: Result := 'Error';
    rsPaused: Result := 'Paused';
    else
      Result := '?';
  end;
end;

constructor TStatusModel.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TStatusModel.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TStatusModel.IndexOf(const ALocalName: string): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(FItems) do
    if SameText(FItems[i].LocalName, ALocalName) then
      Exit(i);
end;

procedure TStatusModel.Notify;
begin
  if Assigned(FOnChanged) then
    FOnChanged();
end;

procedure TStatusModel.SetState(const ALocalName: string; AState: TRepoState;
  const ADetail: string);
var
  i: Integer;
begin
  FLock.Enter;
  try
    i := IndexOf(ALocalName);
    if i < 0 then
    begin
      SetLength(FItems, Length(FItems) + 1);
      i := High(FItems);
      FItems[i].LocalName := ALocalName;
      FItems[i].LastSync := 0;
      FItems[i].PendingChanges := 0;
      FItems[i].HasConflicts := False;
    end;
    FItems[i].State := AState;
    if ADetail <> '' then
      FItems[i].Detail := ADetail;
  finally
    FLock.Leave;
  end;
  Notify;
end;

procedure TStatusModel.SetPending(const ALocalName: string; ACount: Integer);
var
  i: Integer;
begin
  FLock.Enter;
  try
    i := IndexOf(ALocalName);
    if i >= 0 then FItems[i].PendingChanges := ACount;
  finally
    FLock.Leave;
  end;
  Notify;
end;

procedure TStatusModel.SetConflicts(const ALocalName: string; AHas: Boolean);
var
  i: Integer;
begin
  FLock.Enter;
  try
    i := IndexOf(ALocalName);
    if i >= 0 then FItems[i].HasConflicts := AHas;
  finally
    FLock.Leave;
  end;
  Notify;
end;

procedure TStatusModel.TouchSync(const ALocalName: string);
var
  i: Integer;
begin
  FLock.Enter;
  try
    i := IndexOf(ALocalName);
    if i >= 0 then FItems[i].LastSync := Now;
  finally
    FLock.Leave;
  end;
  Notify;
end;

procedure TStatusModel.Remove(const ALocalName: string);
var
  i, j: Integer;
begin
  FLock.Enter;
  try
    i := IndexOf(ALocalName);
    if i >= 0 then
    begin
      for j := i to High(FItems) - 1 do
        FItems[j] := FItems[j + 1];
      SetLength(FItems, Length(FItems) - 1);
    end;
  finally
    FLock.Leave;
  end;
  Notify;
end;

function TStatusModel.Snapshot: TRepoStatusArray;
var
  i: Integer;
begin
  FLock.Enter;
  try
    SetLength(Result, Length(FItems));
    for i := 0 to High(FItems) do
      Result[i] := FItems[i];
  finally
    FLock.Leave;
  end;
end;

function TStatusModel.AggregateState: TRepoState;
var
  i, total, paused: Integer;
  hasErr, hasConflict, hasSync: Boolean;
begin
  hasErr := False;
  hasConflict := False;
  hasSync := False;
  total := 0;
  paused := 0;
  FLock.Enter;
  try
    total := Length(FItems);
    for i := 0 to High(FItems) do
      case FItems[i].State of
        rsError: hasErr := True;
        rsConflict: hasConflict := True;
        rsSyncing: hasSync := True;
        rsPaused: Inc(paused);
      end;
  finally
    FLock.Leave;
  end;
  if hasErr then Result := rsError
  else if hasConflict then Result := rsConflict
  else if hasSync then Result := rsSyncing
  else if (total > 0) and (paused = total) then Result := rsPaused
  else
    Result := rsSynced;
end;

end.
