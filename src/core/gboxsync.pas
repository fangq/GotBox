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
  Classes, SysUtils, gboxgitrunner, gboxconflict, gboxlog;

type
  TSyncOutcome = (soUpToDate, soPushed, soPulled, soMerged, soConflict,
    soReset, soError);

function SyncOutcomeText(AOutcome: TSyncOutcome): string;

{ Runs one cycle on AGit's repo. Conflict copy paths (if any) are appended to
  AConflicts. ADetail carries an error/explanation string. When AChanged is
  given, the files added/modified this cycle (local commits + pulled changes)
  are appended to it (deduplicated, repo-relative). }
function RunSyncCycle(AGit: TGitRunner; const AMachine: string;
  out ADetail: string; AConflicts: TStrings): TSyncOutcome; overload;
function RunSyncCycle(AGit: TGitRunner; const AMachine: string;
  out ADetail: string; AConflicts, AChanged: TStrings): TSyncOutcome; overload;

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

const
  STRAY_BEGIN = '# >>> gotbox: nested repos (not synced - remove .git or use Link) >>>';
  STRAY_END = '# <<< gotbox <<<';

{ A plain folder in the root is regular content; submodules are only created via
  the Link dialog. So a nested git repo that ISN'T a registered submodule must
  never be committed as a (broken) gitlink. This excludes such folders from
  staging and unstages any that slipped in, and -- once a folder is de-embedded
  (its .git removed) -- stops excluding it so its files sync as normal content. }
function HasGitDir(const APath: string): Boolean;
begin
  Result := DirectoryExists(APath + PathDelim + '.git') or
    FileExists(APath + PathDelim + '.git');
end;

procedure ReconcileStrayGitlinks(AGit: TGitRunner);
var
  root, exclPath, p, tab: string;
  subm, tracked, embedded, excl: TStringList;
  sr: TSearchRec;
  r: TGitResult;
  i, a, b, sp: Integer;
begin
  root := AGit.WorkDir;
  if root = '' then Exit;
  // only the superproject root (a real .git directory) needs this; a submodule
  // working tree has .git as a gitlink FILE -- skip it (and it can't host a
  // .git/info/exclude path anyway).
  if not DirectoryExists(IncludeTrailingPathDelimiter(root) + '.git') then Exit;
  subm := TStringList.Create;        // registered submodule paths (legit gitlinks)
  tracked := TStringList.Create;     // stray gitlinks tracked in the index -> unstage
  embedded := TStringList.Create;    // folders that still have a .git -> exclude
  excl := TStringList.Create;
  try
    r := AGit.GitQuiet(['config', '-f', '.gitmodules', '--get-regexp', '\.path$']);
    if r.Ok then
    begin
      excl.Text := r.StdOut;
      for i := 0 to excl.Count - 1 do
      begin
        sp := Pos(' ', excl[i]);
        if sp > 0 then subm.Add(Trim(Copy(excl[i], sp + 1, MaxInt)));
      end;
      excl.Clear;
    end;

    // (A) stray gitlinks already tracked in the index (mode 160000), regardless
    // of whether the folder still has a .git -- these must be unstaged so the
    // broken submodule link disappears from .gotbox.
    r := AGit.GitQuiet(['ls-files', '--stage']);
    if r.Ok then
    begin
      excl.Text := r.StdOut;
      for i := 0 to excl.Count - 1 do
        if Copy(excl[i], 1, 6) = '160000' then
        begin
          tab := excl[i];
          sp := Pos(#9, tab);
          if sp > 0 then
          begin
            p := Copy(tab, sp + 1, MaxInt);
            if subm.IndexOf(p) < 0 then tracked.Add(p);
          end;
        end;
      excl.Clear;
    end;

    // (B) top-level folders that are nested git repos (still have a .git) and
    // aren't registered submodules -- exclude them so add -A won't re-add a
    // gitlink. (A folder with NO .git is de-embedded -> not excluded -> its
    // files sync as normal content.)
    if FindFirst(IncludeTrailingPathDelimiter(root) + AllFilesMask,
      faDirectory, sr) = 0 then
    begin
      try
        repeat
          if (sr.Attr and faDirectory) = 0 then Continue;
          if (sr.Name = '.') or (sr.Name = '..') or SameText(sr.Name, '.git') then
            Continue;
          if HasGitDir(IncludeTrailingPathDelimiter(root) + sr.Name) and
            (subm.IndexOf(sr.Name) < 0) then
            embedded.Add(sr.Name);
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
    end;

    // rewrite the managed block in .git/info/exclude (from still-embedded repos)
    exclPath := IncludeTrailingPathDelimiter(root) + '.git' + PathDelim +
      'info' + PathDelim + 'exclude';
    if FileExists(exclPath) then excl.LoadFromFile(exclPath);
    a := excl.IndexOf(STRAY_BEGIN);
    if a >= 0 then
    begin
      b := excl.IndexOf(STRAY_END);
      if b < a then b := excl.Count - 1;
      for i := b downto a do excl.Delete(i);
    end;
    if embedded.Count > 0 then
    begin
      excl.Add(STRAY_BEGIN);
      for i := 0 to embedded.Count - 1 do excl.Add('/' + embedded[i] + '/');
      excl.Add(STRAY_END);
    end;
    ForceDirectories(ExtractFilePath(exclPath));
    excl.SaveToFile(exclPath);

    // unstage the stray tracked gitlinks (removes the broken link from .gotbox);
    // a still-embedded one stays out via the exclude, a de-embedded one then has
    // its files picked up by the normal add -A.
    for i := 0 to tracked.Count - 1 do
    begin
      AGit.Git(['rm', '--cached', '-f', tracked[i]]);
      if Assigned(Log) then
        if HasGitDir(IncludeTrailingPathDelimiter(root) + tracked[i]) then
          Log.Warn('sync', Format('"%s" is a nested git repo, not a submodule; ' +
            'excluded (remove its .git to sync as files, or use Link submodule)',
            [tracked[i]]))
        else
          Log.Info('sync', Format('"%s" de-embedded; now syncing as a regular folder',
            [tracked[i]]));
    end;
  finally
    subm.Free;
    tracked.Free;
    embedded.Free;
    excl.Free;
  end;
end;

function RunSyncCycle(AGit: TGitRunner; const AMachine: string;
  out ADetail: string; AConflicts: TStrings): TSyncOutcome;
begin
  Result := RunSyncCycle(AGit, AMachine, ADetail, AConflicts, nil);
end;

function RunSyncCycle(AGit: TGitRunner; const AMachine: string;
  out ADetail: string; AConflicts, AChanged: TStrings): TSyncOutcome;
var
  r, mr: TGitResult;
  behind, ahead: Integer;
  hadStash: Boolean;

// append name-only output of a git command to AChanged (deduplicated)
  procedure Collect(const AArgs: array of string);
  var
    rr: TGitResult;
    sl: TStringList;
    k: Integer;
    ln: string;
  begin
    if AChanged = nil then Exit;
    rr := AGit.GitQuiet(AArgs);
    if not rr.Ok then Exit;
    sl := TStringList.Create;
    try
      sl.Text := rr.StdOut;
      for k := 0 to sl.Count - 1 do
      begin
        ln := Trim(sl[k]);
        if (ln <> '') and (AChanged.IndexOf(ln) < 0) then AChanged.Add(ln);
      end;
    finally
      sl.Free;
    end;
  end;

  function CommitLocal: Boolean;
  begin
    Result := True;
    if AGit.HasUncommittedChanges then
    begin
      AGit.AddAll;
      Collect(['diff', '--cached', '--name-only']);   // local edits being synced
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

  // 0. keep stray nested repos out of the commit (no accidental submodules)
  ReconcileStrayGitlinks(AGit);

  // 1. fetch
  r := AGit.Fetch;
  if not r.Ok then
  begin
    CommitLocal;   // at least keep local work safe
    if (Pos('not found', LowerCase(r.StdErr)) > 0) or
      (Pos('does not exist', LowerCase(r.StdErr)) > 0) then
      ADetail := 'remote not found (deleted or no access): ' + Trim(r.StdErr)
    else if (Pos('could not resolve', LowerCase(r.StdErr)) > 0) or
      (Pos('could not read', LowerCase(r.StdErr)) > 0) or
      (Pos('timed out', LowerCase(r.StdErr)) > 0) then
      ADetail := 'offline: ' + Trim(r.StdErr)
    else
      ADetail := 'fetch failed: ' + Trim(r.StdErr);
    Exit(soError);
  end;

  // 2. remote branch present?
  if not AGit.GitQuiet(['rev-parse', '--verify', 'origin/main']).Ok then
  begin
    if not CommitLocal then Exit(soError);
    // nothing committed yet (e.g. an empty folder) -> nothing to push
    if AGit.CountCommits <= 0 then Exit(soUpToDate);
    if PushNow then Exit(soPushed)
    else
      Exit(soError);
  end;

  // 3. rewritten remote? (no common ancestor between local and remote)
  if not AGit.GitQuiet(['merge-base', 'HEAD', 'origin/main']).Ok then
  begin
    Collect(['diff', '--name-only', 'HEAD', 'origin/main']);   // incoming changes
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

  // behind > 0: remote has changes we're about to pull in -- record them
  Collect(['diff', '--name-only', 'HEAD', 'origin/main']);

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
