unit gboxstatus;

{ Status window: a grid of per-repo sync state plus the recent activity log.
  Reads snapshots from the shared TStatusModel and the global logger; refreshed
  on a timer (cheap and avoids cross-thread UI updates). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Grids, StdCtrls, ExtCtrls,
  gboxstatusmodel, gboxlog;

type
  TStatusForm = class(TForm)
    grid: TStringGrid;
    mLog: TMemo;
    lblLog: TLabel;
    refreshTimer: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure refreshTimerTimer(Sender: TObject);
  private
    FStatus: TStatusModel;
    procedure Refresh;
  public
    procedure Bind(AStatus: TStatusModel);
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

procedure TStatusForm.Refresh;
var
  snap: TRepoStatusArray;
  i: Integer;
  lines: TStringList;
begin
  if Assigned(FStatus) then
  begin
    snap := FStatus.Snapshot;
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
  end;

  if Assigned(Log) then
  begin
    lines := Log.Snapshot;
    try
      // show only the tail to keep the memo light
      while lines.Count > 200 do
        lines.Delete(0);
      mLog.Lines.Assign(lines);
      mLog.SelStart := Length(mLog.Text);
    finally
      lines.Free;
    end;
  end;
end;

procedure TStatusForm.refreshTimerTimer(Sender: TObject);
begin
  if Visible then
    Refresh;
end;

end.
