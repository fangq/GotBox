unit gboxsync;

{ One bidirectional sync cycle for a single repo, factored out of the worker so
  it can be unit-tested synchronously. Sequence:

    1. commit any local changes
    2. fetch origin
    3. compare HEAD vs origin/main:
         - remote empty                -> push
         - remote not ahead            -> push (fast-forward / up to date)
         - local not ahead (behind)    -> fast-forward merge (pull down)
         - diverged                    -> merge; on conflict, keep-both, commit
       then push when local has commits the remote lacks.

  Pushes use plain push; history rewrites (milestone 7) are separate. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxgitrunner, gboxconflict;

type
  TSyncOutcome = (soUpToDate, soPushed, soPulled, soMerged, soConflict, soError);

function SyncOutcomeText(AOutcome: TSyncOutcome): string;

{ Runs one cycle on AGit's repo. Conflict copy paths (if any) are appended to
  AConflicts. ADetail carries an error/explanation string. }
function RunSyncCycle(AGit: TGitRunner; const AMachine: string;
  out ADetail: string; AConflicts: TStrings): TSyncOutcome;

implementation

function SyncOutcomeText(AOutcome: TSyncOutcome): string;
begin
  case AOutcome of
    soUpToDate: Result := 'up to date';
    soPushed: Result := 'pushed';
    soPulled: Result := 'pulled';
    soMerged: Result := 'merged';
    soConflict: Result := 'conflict (kept both)';
    soError: Result := 'error';
    else
      Result := '?';
  end;
end;

function RunSyncCycle(AGit: TGitRunner; const AMachine: string;
  out ADetail: string; AConflicts: TStrings): TSyncOutcome;
var
  r, mr: TGitResult;
  behind, ahead: Integer;

  function PushNow: Boolean;
  begin
    r := AGit.Push(False);
    Result := r.Ok;
    if not Result then ADetail := 'push failed: ' + Trim(r.StdErr);
  end;

begin
  ADetail := '';

  // 1. commit local changes
  if AGit.HasUncommittedChanges then
  begin
    AGit.AddAll;
    r := AGit.CommitAll(Format('%s %s',
      [AMachine, FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)]));
    if not r.Ok then
    begin
      ADetail := 'commit failed: ' + Trim(r.StdErr);
      Exit(soError);
    end;
  end;

  // 2. fetch
  r := AGit.Fetch;
  if not r.Ok then
  begin
    ADetail := 'fetch failed (offline?): ' + Trim(r.StdErr);
    Exit(soError);
  end;

  // 3. remote branch present?
  if not AGit.RevParse('origin/main').Ok then
  begin
    if PushNow then Exit(soPushed)
    else
      Exit(soError);
  end;

  behind := AGit.CountRange('HEAD..origin/main');   // commits only on remote
  ahead := AGit.CountRange('origin/main..HEAD');     // commits only on local
  if (behind < 0) or (ahead < 0) then
  begin
    ADetail := 'could not compare with remote';
    Exit(soError);
  end;

  if behind = 0 then
  begin
    if ahead = 0 then Exit(soUpToDate);
    if PushNow then Exit(soPushed)
    else
      Exit(soError);
  end;

  // behind > 0
  if ahead = 0 then
  begin
    // fast-forward: just take the remote
    r := AGit.Merge('origin/main');
    if r.Ok then Exit(soPulled);
    ADetail := 'fast-forward failed: ' + Trim(r.StdErr);
    Exit(soError);
  end;

  // diverged: try to merge
  mr := AGit.Merge('origin/main');
  if mr.Ok then
  begin
    if PushNow then Exit(soMerged)
    else
      Exit(soError);
  end;

  // merge failed -- keep-both if there are unmerged paths, else give up
  if ResolveKeepBoth(AGit, AMachine, AConflicts) > 0 then
  begin
    AGit.Git(['commit', '--no-edit']);   // finalize the merge commit
    if PushNow then Exit(soConflict)
    else
      Exit(soError);
  end;

  AGit.Git(['merge', '--abort']);
  ADetail := 'merge failed: ' + Trim(mr.StdErr);
  Result := soError;
end;

end.
