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

unit gboxstatus;

{ Status window: a grid of per-repo sync state plus the recent activity log, and
  per-repo actions (pause/resume, sync now, open folder). Reads snapshots from
  the shared TStatusModel and the global logger; refreshed on a timer. The
  actions are surfaced as events the main form wires up (it owns the config and
  engine). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Grids, StdCtrls, ExtCtrls,
  gboxstatusmodel, gboxlog;

type
  TRepoActionEvent = procedure(const ARepo: string) of object;

  TStatusForm = class(TForm)
    grid: TStringGrid;
    mLog: TMemo;
    lblLog: TLabel;
    btnPause: TButton;
    btnSync: TButton;
    btnOpen: TButton;
    refreshTimer: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure refreshTimerTimer(Sender: TObject);
    procedure btnPauseClick(Sender: TObject);
    procedure btnSyncClick(Sender: TObject);
    procedure btnOpenClick(Sender: TObject);
  private
    FStatus: TStatusModel;
    FOnTogglePause: TRepoActionEvent;
    FOnSyncRepo: TRepoActionEvent;
    FOnOpenRepo: TRepoActionEvent;
    FLastGridSig: string;   // only redraw grid/log when content actually changes
    FLastLog: string;
    function SelectedRepo: string;
    procedure Refresh;
  public
    procedure Bind(AStatus: TStatusModel);
    property OnTogglePause: TRepoActionEvent read FOnTogglePause write FOnTogglePause;
    property OnSyncRepo: TRepoActionEvent read FOnSyncRepo write FOnSyncRepo;
    property OnOpenRepo: TRepoActionEvent read FOnOpenRepo write FOnOpenRepo;
  end;

var
  StatusForm: TStatusForm;

implementation

{$R *.lfm}

procedure TStatusForm.FormCreate(Sender: TObject);
begin
  grid.RowCount := 1;
  grid.Cells[0, 0] := 'Repo';
  grid.Cells[1, 0] := 'State';
  grid.Cells[2, 0] := 'Pending';
  grid.Cells[3, 0] := 'Last sync';
end;

procedure TStatusForm.Bind(AStatus: TStatusModel);
begin
  FStatus := AStatus;
  Refresh;
end;

function TStatusForm.SelectedRepo: string;
begin
  Result := '';
  if (grid.Row >= 1) and (grid.Row < grid.RowCount) then
    Result := grid.Cells[0, grid.Row];
end;

procedure TStatusForm.btnPauseClick(Sender: TObject);
var
  r: string;
begin
  r := SelectedRepo;
  if (r <> '') and Assigned(FOnTogglePause) then
  begin
    FOnTogglePause(r);
    Refresh;
  end;
end;

procedure TStatusForm.btnSyncClick(Sender: TObject);
var
  r: string;
begin
  r := SelectedRepo;
  if (r <> '') and Assigned(FOnSyncRepo) then
    FOnSyncRepo(r);
end;

procedure TStatusForm.btnOpenClick(Sender: TObject);
var
  r: string;
begin
  r := SelectedRepo;
  if (r <> '') and Assigned(FOnOpenRepo) then
    FOnOpenRepo(r);
end;

procedure TStatusForm.Refresh;
var
  snap: TRepoStatusArray;
  i: Integer;
  lines: TStringList;
  sig, lastSync, logText: string;
begin
  if Assigned(FStatus) then
  begin
    snap := FStatus.Snapshot;
    // build a signature; only rebuild the grid when it changes (avoids flicker)
    sig := '';
    for i := 0 to High(snap) do
    begin
      if snap[i].LastSync > 0 then
        lastSync := FormatDateTime('hh:nn:ss', snap[i].LastSync)
      else
        lastSync := '-';
      sig := sig + snap[i].LocalName + '|' + RepoStateText(snap[i].State) +
        '|' + IntToStr(snap[i].PendingChanges) + '|' + lastSync + #10;
    end;
    if sig <> FLastGridSig then
    begin
      FLastGridSig := sig;
      grid.BeginUpdate;
      try
        grid.RowCount := Length(snap) + 1;
        for i := 0 to High(snap) do
        begin
          grid.Cells[0, i + 1] := snap[i].LocalName;
          grid.Cells[1, i + 1] := RepoStateText(snap[i].State);
          grid.Cells[2, i + 1] := IntToStr(snap[i].PendingChanges);
          if snap[i].LastSync > 0 then
            grid.Cells[3, i + 1] := FormatDateTime('hh:nn:ss', snap[i].LastSync)
          else
            grid.Cells[3, i + 1] := '-';
        end;
      finally
        grid.EndUpdate;
      end;
    end;
  end;

  if Assigned(Log) then
  begin
    lines := Log.Snapshot;
    try
      while lines.Count > 200 do
        lines.Delete(0);   // show only the tail to keep the memo light
      logText := lines.Text;
    finally
      lines.Free;
    end;
    // only repopulate when there's new output -- reassigning every tick flashes
    // the memo and yanks the scroll position
    if logText <> FLastLog then
    begin
      FLastLog := logText;
      mLog.Lines.BeginUpdate;
      try
        mLog.Text := logText;
      finally
        mLog.Lines.EndUpdate;
      end;
      mLog.SelStart := Length(mLog.Text);   // scroll to newest only on change
    end;
  end;
end;

procedure TStatusForm.refreshTimerTimer(Sender: TObject);
begin
  if Visible then
    Refresh;
end;

end.
