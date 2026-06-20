unit gboxhistory;

{ Rolling history cap. To keep repos lean, everything older than the most recent
  ACap commits is collapsed into a single snapshot commit, the recent commits are
  rebased onto it, the rewritten history is force-pushed, and `git gc` reclaims
  space. Because this rewrites history, other machines pick up the change via the
  rewrite-safe reset path in gboxsync.

  ShouldTrim applies hysteresis (only trim once history grows well past the cap)
  so force-pushes happen in batches rather than on every commit. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxgitrunner;

{ True if the repo has grown enough past ACap to be worth trimming. }
function ShouldTrim(AGit: TGitRunner; ACap: Integer): Boolean;

{ Squashes history to the most recent ACap commits (+1 snapshot) and force-pushes.
  Returns True if a trim happened; ADetail explains failures. The working tree
  must be clean and on the branch being trimmed. }
function TrimHistory(AGit: TGitRunner; ACap: Integer; out ADetail: string): Boolean;

implementation

uses
  gboxlog;

function ShouldTrim(AGit: TGitRunner; ACap: Integer): Boolean;
var
  n: Integer;
begin
  Result := False;
  if ACap <= 0 then Exit;
  n := AGit.CountCommits;
  // hysteresis: let it grow to ~2x the cap before squashing back down
  Result := (n > 0) and (n > 2 * ACap);
end;

function TrimHistory(AGit: TGitRunner; ACap: Integer; out ADetail: string): Boolean;
var
  n: Integer;
  base, tree, snap, ts: string;
  r: TGitResult;
begin
  Result := False;
  ADetail := '';
  if ACap <= 0 then Exit;

  n := AGit.CountCommits;
  if n <= ACap then Exit;   // already within the cap

  // boundary commit: the one just before the window of the last ACap commits
  base := Trim(AGit.RevParse('HEAD~' + IntToStr(ACap)).StdOut);
  if base = '' then
  begin
    ADetail := 'could not resolve history boundary';
    Exit;
  end;

  tree := Trim(AGit.Git(['rev-parse', base + '^{tree}']).StdOut);
  if tree = '' then
  begin
    ADetail := 'could not resolve boundary tree';
    Exit;
  end;

  // a parentless snapshot commit holding the boundary tree
  ts := FormatDateTime('yyyy-mm-dd', Now);
  snap := Trim(AGit.Git(['commit-tree', tree, '-m', 'GotBox history snapshot ' +
    ts]).StdOut);
  if snap = '' then
  begin
    ADetail := 'snapshot (commit-tree) failed';
    Exit;
  end;

  // replay the most recent ACap commits onto the snapshot
  r := AGit.Git(['rebase', '--onto', snap, base]);
  if not r.Ok then
  begin
    AGit.Git(['rebase', '--abort']);
    ADetail := 'rebase failed: ' + Trim(r.StdErr);
    Exit;
  end;

  // publish the rewritten history
  r := AGit.Push(True);   // --force-with-lease
  if not r.Ok then
  begin
    ADetail := 'force-push failed: ' + Trim(r.StdErr);
    Exit;   // local history is trimmed; remote will catch up next cycle
  end;

  AGit.Gc;
  if Assigned(Log) then
    Log.Info('history', Format('trimmed to last %d commits (+snapshot)', [ACap]));
  Result := True;
end;

end.
