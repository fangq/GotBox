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

unit gboxstatusmodel;

{ Lock-protected, observable snapshot of per-repo sync state. Worker threads
  update it; the GUI reads snapshots on the main thread. The OnChanged callback
  is invoked (queued onto the main thread by the caller) so the UI can refresh. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  TRepoState = (rsIdle, rsSyncing, rsSynced, rsConflict, rsError, rsPaused,
    rsOffline);

  TRepoStatus = record
    LocalName: string;
    State: TRepoState;
    LastSync: TDateTime;
    PendingChanges: Integer;
    Detail: string;        // last action / error text
    HasConflicts: Boolean;
    AutoSync: Boolean;     // True = automatic sync; False = managed (default)
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
    { Record the repo's sync mode (True = automatic, False = managed) for display. }
    procedure SetMode(const ALocalName: string; AAutoSync: Boolean);
    procedure TouchSync(const ALocalName: string);
    procedure Remove(const ALocalName: string);
    { Drop any repo entry whose name is not in ANames (case-insensitive). Used
      when the tracked set shrinks, e.g. a submodule removed on another machine. }
    procedure RetainOnly(ANames: TStrings);
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
    rsOffline: Result := 'Offline';
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
      FItems[i].AutoSync := False;   // managed until told otherwise
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

procedure TStatusModel.SetMode(const ALocalName: string; AAutoSync: Boolean);
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
      FItems[i].State := rsIdle;
    end;
    FItems[i].AutoSync := AAutoSync;
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

procedure TStatusModel.RetainOnly(ANames: TStrings);
var
  i, j, k: Integer;
  keep: Boolean;
begin
  FLock.Enter;
  try
    for i := High(FItems) downto 0 do
    begin
      keep := False;
      for j := 0 to ANames.Count - 1 do
        if SameText(FItems[i].LocalName, ANames[j]) then
        begin
          keep := True;
          Break;
        end;
      if not keep then
      begin
        for k := i to High(FItems) - 1 do
          FItems[k] := FItems[k + 1];
        SetLength(FItems, Length(FItems) - 1);
      end;
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
  hasErr, hasConflict, hasOffline, hasSync: Boolean;
begin
  hasErr := False;
  hasConflict := False;
  hasOffline := False;
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
        rsOffline: hasOffline := True;
        rsSyncing: hasSync := True;
        rsPaused: Inc(paused);
      end;
  finally
    FLock.Leave;
  end;
  // worst-first, but offline ranks below real errors/conflicts (it's transient)
  if hasErr then Result := rsError
  else if hasConflict then Result := rsConflict
  else if hasOffline then Result := rsOffline
  else if hasSync then Result := rsSyncing
  else if (total > 0) and (paused = total) then Result := rsPaused
  else if total = 0 then Result := rsIdle   // nothing tracked yet: not "synced"
  else
    Result := rsSynced;
end;

end.
