unit gboxsync;

{ One bidirectional sync cycle for a single repo, factored out of the worker so
  it can be unit-tested synchronously. Order of operations:

    1. fetch origin
    2. if the remote branch is missing      -> commit local + push
    3. if HEAD and origin/main share NO base -> the remote history was rewritten
       (milestone 7 squash + force-push). Adopt the remote as source of truth:
       stash any uncommitted edits, reset --hard origin/main, replay the stash
       (keep-both on a replay conflict), then push the replayed edits.
    4. otherwise: commit local changes, then push / fast-forward / merge, with
       keep-both on an unmergeable merge.

  Local edits are committed only AFTER the rewrite check so a remote rewrite can
  never strand a just-made local commit. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxgitrunner, gboxconflict;

type
  TSyncOutcome = (soUpToDate, soPushed, soPulled, soMerged, soConflict,
    soReset, soError);

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
    soReset: Result := 'reset to rewritten remote';
    soError: Result := 'error';
    else
      Result := '?';
  end;
end;

function CommitMsg(const AMachine: string): string;
begin
  Result := Format('%s %s', [AMachine, FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)]);
end;

function RunSyncCycle(AGit: TGitRunner; const AMachine: string;
  out ADetail: string; AConflicts: TStrings): TSyncOutcome;
var
  r, mr: TGitResult;
  behind, ahead: Integer;
  hadStash: Boolean;

  function CommitLocal: Boolean;
  begin
    Result := True;
    if AGit.HasUncommittedChanges then
    begin
      AGit.AddAll;
      r := AGit.CommitAll(CommitMsg(AMachine));
      Result := r.Ok;
      if not Result then ADetail := 'commit failed: ' + Trim(r.StdErr);
    end;
  end;

  function PushNow: Boolean;
  begin
    r := AGit.Push(False);
    Result := r.Ok;
    if not Result then ADetail := 'push failed: ' + Trim(r.StdErr);
  end;

begin
  ADetail := '';

  // 1. fetch
  r := AGit.Fetch;
  if not r.Ok then
  begin
    CommitLocal;   // at least keep local work safe
    ADetail := 'fetch failed (offline?): ' + Trim(r.StdErr);
    Exit(soError);
  end;

  // 2. remote branch present?
  if not AGit.RevParse('origin/main').Ok then
  begin
    if not CommitLocal then Exit(soError);
    // nothing committed yet (e.g. an empty folder) -> nothing to push
    if AGit.CountCommits <= 0 then Exit(soUpToDate);
    if PushNow then Exit(soPushed)
    else
      Exit(soError);
  end;

  // 3. rewritten remote? (no common ancestor between local and remote)
  if not AGit.Git(['merge-base', 'HEAD', 'origin/main']).Ok then
  begin
    hadStash := AGit.HasUncommittedChanges;
    if hadStash then AGit.Stash;
    AGit.ResetHard('origin/main');
    if hadStash then
    begin
      if not AGit.StashPop.Ok then
      begin
        // replayed edits clash with the rewritten tree -> keep both
        ResolveKeepBoth(AGit, AMachine, AConflicts);
        if not CommitLocal then Exit(soError);
        if PushNow then Exit(soConflict)
        else
          Exit(soError);
      end;
      // replayed cleanly -> commit + push the local edits onto the new base
      if not CommitLocal then Exit(soError);
      if AGit.CountRange('origin/main..HEAD') > 0 then
        if not PushNow then Exit(soError);
    end;
    Exit(soReset);
  end;

  // 4. normal path: commit local changes, then reconcile
  if not CommitLocal then Exit(soError);

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
    r := AGit.Merge('origin/main');   // fast-forward
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

  // unmergeable -> keep both
  if ResolveKeepBoth(AGit, AMachine, AConflicts) > 0 then
  begin
    AGit.Git(['commit', '--no-edit']);
    if PushNow then Exit(soConflict)
    else
      Exit(soError);
  end;

  AGit.Git(['merge', '--abort']);
  ADetail := 'merge failed: ' + Trim(mr.StdErr);
  Result := soError;
end;

end.
