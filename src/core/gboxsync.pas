{
  GotBox -- Cross-machine file sync over your own private git repositories.
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
    soReset, soError, soOffline);

function SyncOutcomeText(AOutcome: TSyncOutcome): string;

{ True if AText (git stderr / a cycle detail) looks like local repository
  corruption -- a damaged object store that a normal cycle can't fix by itself
  (it needs re-cloning). Used to give the user an actionable state instead of
  retrying a doomed cycle forever. }
function IsCorruptionError(const AText: string): Boolean;

{ Runs one cycle on AGit's repo. Conflict copy paths (if any) are appended to
  AConflicts. ADetail carries an error/explanation string. When AChanged is
  given, the files added/modified this cycle (local commits + pulled changes)
  are appended to it (deduplicated, repo-relative). }
function RunSyncCycle(AGit: TGitRunner; const AMachine: string;
  out ADetail: string; AConflicts: TStrings;
  const ABranch: string = 'main'): TSyncOutcome; overload;
function RunSyncCycle(AGit: TGitRunner; const AMachine: string;
  out ADetail: string; AConflicts, AChanged: TStrings;
  const ABranch: string = 'main'): TSyncOutcome; overload;

{ "Managed" cycle for a submodule the user commits by hand: transport committed
  state only. NEVER stages, commits, creates a merge commit, resets, or force-
  pushes -- so it can't contaminate or truncate the repo's history. It fetches,
  fast-forwards in remote commits when the working tree is clean, and pushes the
  user's own fast-forwardable commits; a divergence or a rewritten remote is left
  for the user to resolve. Incoming pulled files (if any) are appended to
  AChanged. }
function RunManagedCycle(AGit: TGitRunner; out ADetail: string;
  AChanged: TStrings; const ABranch: string = 'main'): TSyncOutcome;

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
    soOffline: Result := 'offline';
    else
      Result := '?';
  end;
end;

function CommitMsg(const AMachine: string): string;
begin
  Result := Format('%s %s', [AMachine, FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)]);
end;

function IsCorruptionError(const AText: string): Boolean;
var
  s: string;
begin
  s := LowerCase(AText);
  Result := (Pos('corrupt', s) > 0) or               // "loose object ... is corrupt"
    (Pos('loose object', s) > 0) or (Pos('object file', s) > 0) or
    // "object file ... is empty"
    (Pos('bad object', s) > 0) or (Pos('unable to read tree', s) > 0) or
    (Pos('did not receive expected object', s) > 0) or
    (Pos('object of unexpected type', s) > 0) or (Pos('sha1 mismatch', s) > 0);
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

{ Recursively collect embedded git repos (folders with a .git) under ABase,
  as repo-relative '/'-separated paths, EXCLUDING registered submodules (ASubm).
  Does not descend into a found repo or into .git, so it stops at repo
  boundaries and finds nested strays (e.g. resubmission/draft), not just
  top-level ones. }
procedure CollectEmbeddedRepos(const ABase, ARel: string; ASubm, AOut: TStrings);
var
  sr: TSearchRec;
  full, rel: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ABase) + AllFilesMask,
    faDirectory, sr) <> 0 then
    Exit;
  try
    repeat
      if (sr.Attr and faDirectory) = 0 then Continue;
      // don't follow symlinked dirs: git never descends into them, and a symlink
      // cycle (e.g. a/b -> ../..) would otherwise recurse forever
      if (sr.Attr and faSymLink) <> 0 then Continue;
      if (sr.Name = '.') or (sr.Name = '..') or SameText(sr.Name, '.git') then
        Continue;
      full := IncludeTrailingPathDelimiter(ABase) + sr.Name;
      if ARel = '' then rel := sr.Name
      else
        rel := ARel + '/' + sr.Name;
      if HasGitDir(full) then
      begin
        // an embedded repo -- exclude it unless it's a registered submodule;
        // never descend into a repo (its .git internals aren't ours to scan)
        if ASubm.IndexOf(rel) < 0 then AOut.Add(rel);
      end
      else
        CollectEmbeddedRepos(full, rel, ASubm, AOut);   // plain folder: recurse
    until FindNext(sr) <> 0;
  finally
    SysUtils.FindClose(sr);
  end;
end;

procedure ReconcileStrayGitlinks(AGit: TGitRunner);
var
  root, root2, exclPath, p, tab, key, nm, modp: string;
  subm, subNames, tracked, embedded, excl: TStringList;
  r: TGitResult;
  i, a, b, sp: Integer;
begin
  root := AGit.WorkDir;
  if root = '' then Exit;
  root2 := IncludeTrailingPathDelimiter(root);
  // only the superproject root (a real .git directory) needs this; a submodule
  // working tree has .git as a gitlink FILE -- skip it (and it can't host a
  // .git/info/exclude path anyway).
  if not DirectoryExists(root2 + '.git') then Exit;
  subm := TStringList.Create;        // registered submodule paths (legit gitlinks)
  subNames := TStringList.Create;
  // their .gitmodules section names (parallel to subm)
  tracked := TStringList.Create;     // stray gitlinks tracked in the index -> unstage
  embedded := TStringList.Create;    // folders that still have a .git -> exclude
  excl := TStringList.Create;
  try
    // each line: "submodule.<name>.path <relpath>"; capture both name and path
    r := AGit.GitQuiet(['config', '-f', '.gitmodules', '--get-regexp', '\.path$']);
    if r.Ok then
    begin
      excl.Text := r.StdOut;
      for i := 0 to excl.Count - 1 do
      begin
        sp := Pos(' ', excl[i]);
        if sp <= 0 then Continue;
        subm.Add(Trim(Copy(excl[i], sp + 1, MaxInt)));
        key := Trim(Copy(excl[i], 1, sp - 1));   // submodule.<name>.path
        if (Length(key) > Length('submodule.') + Length('.path')) then
          subNames.Add(Copy(key, Length('submodule.') + 1, Length(key) -
            Length('submodule.') - Length('.path')))
        else
          subNames.Add('');
      end;
      excl.Clear;
    end;

    // (0) a registered submodule whose working FOLDER the user deleted: unlink it
    // -- drop the gitlink from the index and its .gitmodules entry -- but KEEP the
    // underlying repository (.git/modules/<name> and the remote) so it can be
    // re-linked later. We only treat it as "deleted" (not "not yet checked out")
    // when the module repo exists under .git/modules, i.e. it WAS checked out here.
    for i := 0 to subm.Count - 1 do
    begin
      nm := subNames[i];
      if nm = '' then nm := subm[i];
      modp := root2 + '.git' + PathDelim + 'modules' + PathDelim + SetDirSeparators(nm);
      if (not DirectoryExists(root2 + SetDirSeparators(subm[i]))) and
        DirectoryExists(modp) then
      begin
        AGit.Git(['rm', '--cached', subm[i]]);                    // drop the gitlink
        AGit.Git(['config', '-f', '.gitmodules', '--remove-section',
          'submodule.' + nm]);                                    // drop the entry
        AGit.Git(['add', '.gitmodules']);
        if Assigned(Log) then
          Log.Info('sync', Format('submodule "%s" folder was removed; unlinked it ' +
            '(its repository is kept -- delete it on the remote if you want it gone)',
            [subm[i]]));
      end;
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

    // (B) nested git repos (at ANY depth) that still have a .git and aren't
    // registered submodules -- exclude them so add -A won't re-add a gitlink and
    // fight the unstage above every cycle. (A folder with NO .git is de-embedded
    // -> not excluded -> its files sync as normal content.)
    CollectEmbeddedRepos(root, '', subm, embedded);

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
    subNames.Free;
    tracked.Free;
    embedded.Free;
    excl.Free;
  end;
end;

function RunSyncCycle(AGit: TGitRunner; const AMachine: string;
  out ADetail: string; AConflicts: TStrings; const ABranch: string): TSyncOutcome;
begin
  Result := RunSyncCycle(AGit, AMachine, ADetail, AConflicts, nil, ABranch);
end;

function RunSyncCycle(AGit: TGitRunner; const AMachine: string;
  out ADetail: string; AConflicts, AChanged: TStrings;
  const ABranch: string): TSyncOutcome;
var
  r, mr: TGitResult;
  behind, ahead: Integer;
  hadStash: Boolean;
  fetchErr, remoteRef: string;

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
  var
    outAll: string;
  begin
    Result := True;
    if AGit.HasUncommittedChanges then
    begin
      AGit.AddAll;
      Collect(['diff', '--cached', '--name-only']);   // local edits being synced
      r := AGit.CommitAll(CommitMsg(AMachine));
      Result := r.Ok;
      if not Result then
      begin
        // "nothing to commit" (git exits 1, message on stdout) is NOT a failure:
        // the working-tree changes were all ignored/excluded (e.g. a stray
        // gitlink that add -A re-added), so there is simply nothing to record.
        // Treat it as a no-op so the cycle can still fetch/merge -- otherwise the
        // repo gets stuck unable to pull remote changes.
        outAll := LowerCase(r.StdOut + ' ' + r.StdErr);
        if (Pos('nothing to commit', outAll) > 0) or
          (Pos('no changes added to commit', outAll) > 0) or
          (Pos('working tree clean', outAll) > 0) then
          Result := True
        else
          ADetail := 'commit failed: ' + Trim(r.StdErr);
      end;
    end;
  end;

  function PushNow: Boolean;
  var
    e: string;
  begin
    r := AGit.Push(False);
    Result := r.Ok;
    if not Result then
    begin
      // give GitHub's 100 MB rejection an actionable message instead of raw gunk
      // (GH001 / "this exceeds GitHub's file size limit of 100.00 MB")
      e := LowerCase(r.StdErr);
      if (Pos('gh001', e) > 0) or (Pos('file size limit', e) > 0) or
        (Pos('exceeds github', e) > 0) then
        ADetail := 'a file exceeds GitHub''s 100 MB limit; install git-lfs or ' +
          'remove the file (' + Trim(r.StdErr) + ')'
      else
        ADetail := 'push failed: ' + Trim(r.StdErr);
    end;
  end;

begin
  ADetail := '';
  remoteRef := 'origin/' + ABranch;

  // 0. clear a stale index.lock left by a previously-killed op (else every
  //    add/commit here would fail), then keep stray nested repos out of the commit
  AGit.SweepStaleIndexLock;
  ReconcileStrayGitlinks(AGit);

  // 1. fetch
  r := AGit.Fetch;
  if not r.Ok then
  begin
    // capture the fetch error NOW: CommitLocal reassigns the shared r
    fetchErr := Trim(r.StdErr);
    CommitLocal;   // at least keep local work safe
    if (Pos('not found', LowerCase(fetchErr)) > 0) or
      (Pos('does not exist', LowerCase(fetchErr)) > 0) then
    begin
      ADetail := 'remote not found (deleted or no access): ' + fetchErr;
      Exit(soError);
    end
    else if (Pos('could not resolve', LowerCase(fetchErr)) > 0) or
      (Pos('could not read', LowerCase(fetchErr)) > 0) or
      (Pos('connection', LowerCase(fetchErr)) > 0) or
      (Pos('network', LowerCase(fetchErr)) > 0) or
      (Pos('timed out', LowerCase(fetchErr)) > 0) then
    begin
      // transient: no network. Keep local commits; retry next cycle.
      ADetail := 'offline: ' + fetchErr;
      Exit(soOffline);
    end
    else
    begin
      ADetail := 'fetch failed: ' + fetchErr;
      Exit(soError);
    end;
  end;

  // 2. remote branch present?
  if not AGit.GitQuiet(['rev-parse', '--verify', remoteRef]).Ok then
  begin
    if not CommitLocal then Exit(soError);
    // nothing committed yet (e.g. an empty folder) -> nothing to push
    if AGit.CountCommits <= 0 then Exit(soUpToDate);
    if PushNow then Exit(soPushed)
    else
      Exit(soError);
  end;

  // 3. rewritten remote? (no common ancestor between local and remote)
  if not AGit.GitQuiet(['merge-base', 'HEAD', remoteRef]).Ok then
  begin
    Collect(['diff', '--name-only', 'HEAD', remoteRef]);   // incoming changes
    hadStash := AGit.HasUncommittedChanges;
    if hadStash then AGit.Stash;
    AGit.ResetHard(remoteRef);
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
      if AGit.CountRange(remoteRef + '..HEAD') > 0 then
        if not PushNow then Exit(soError);
    end;
    Exit(soReset);
  end;

  // 4. normal path: commit local changes, then reconcile
  if not CommitLocal then Exit(soError);

  behind := AGit.CountRange('HEAD..' + remoteRef);   // commits only on remote
  ahead := AGit.CountRange(remoteRef + '..HEAD');     // commits only on local
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
  Collect(['diff', '--name-only', 'HEAD', remoteRef]);

  // behind > 0
  if ahead = 0 then
  begin
    r := AGit.Merge(remoteRef);   // fast-forward
    if r.Ok then Exit(soPulled);
    ADetail := 'fast-forward failed: ' + Trim(r.StdErr);
    Exit(soError);
  end;

  // diverged: try to merge
  mr := AGit.Merge(remoteRef);
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

function RunManagedCycle(AGit: TGitRunner; out ADetail: string;
  AChanged: TStrings; const ABranch: string = 'main'): TSyncOutcome;
var
  r: TGitResult;
  fetchErr, remoteRef: string;
  behind, ahead: Integer;
  dirty: Boolean;

  procedure CollectIncoming;
  var
    rr: TGitResult;
    sl: TStringList;
    k: Integer;
    ln: string;
  begin
    if AChanged = nil then Exit;
    rr := AGit.GitQuiet(['diff', '--name-only', 'HEAD', remoteRef]);
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

begin
  ADetail := '';
  remoteRef := 'origin/' + ABranch;

  AGit.SweepStaleIndexLock;   // clear a lock left by a killed op before merging

  // 1. fetch (same offline / not-found classification as RunSyncCycle, but we
  // never commit local work here -- managed repos are the user's to commit)
  r := AGit.Fetch;
  if not r.Ok then
  begin
    fetchErr := Trim(r.StdErr);
    if (Pos('not found', LowerCase(fetchErr)) > 0) or
      (Pos('does not exist', LowerCase(fetchErr)) > 0) then
    begin
      ADetail := 'remote not found (deleted or no access): ' + fetchErr;
      Exit(soError);
    end
    else if (Pos('could not resolve', LowerCase(fetchErr)) > 0) or
      (Pos('could not read', LowerCase(fetchErr)) > 0) or
      (Pos('connection', LowerCase(fetchErr)) > 0) or
      (Pos('network', LowerCase(fetchErr)) > 0) or
      (Pos('timed out', LowerCase(fetchErr)) > 0) then
    begin
      ADetail := 'offline: ' + fetchErr;
      Exit(soOffline);
    end
    else
    begin
      ADetail := 'fetch failed: ' + fetchErr;
      Exit(soError);
    end;
  end;

  dirty := AGit.HasUncommittedChanges;

  // 2. remote branch missing: push our committed history if we have any (only
  // when clean so we don't imply the working tree is in sync); never commit
  if not AGit.GitQuiet(['rev-parse', '--verify', remoteRef]).Ok then
  begin
    if (not dirty) and (AGit.CountCommits > 0) then
    begin
      r := AGit.Push(False);
      if r.Ok then Exit(soPushed);
      ADetail := 'push failed: ' + Trim(r.StdErr);
      Exit(soError);
    end;
    Exit(soUpToDate);
  end;

  // 3. rewritten remote (no common ancestor): adopting it would need a hard
  // reset -- destructive to the user's history, so we refuse and surface it
  if not AGit.GitQuiet(['merge-base', 'HEAD', remoteRef]).Ok then
  begin
    ADetail := 'remote history was rewritten; resolve this submodule manually';
    Exit(soConflict);
  end;

  behind := AGit.CountRange('HEAD..' + remoteRef);    // commits only on remote
  ahead := AGit.CountRange(remoteRef + '..HEAD');      // commits only on local
  if (behind < 0) or (ahead < 0) then
  begin
    ADetail := 'could not compare with remote';
    Exit(soError);
  end;

  if dirty then
  begin
    // never touch a dirty working tree; pushing is safe (index/tree untouched)
    if (behind = 0) and (ahead > 0) then
    begin
      r := AGit.Push(False);
      if r.Ok then Exit(soPushed);
      ADetail := 'push failed: ' + Trim(r.StdErr);
      Exit(soError);
    end;
    if behind > 0 then
      ADetail := 'uncommitted changes; not merging (commit manually to sync)';
    Exit(soUpToDate);
  end;

  // clean working tree
  if behind = 0 then
  begin
    if ahead = 0 then Exit(soUpToDate);
    r := AGit.Push(False);                             // ahead>0: publish commits
    if r.Ok then Exit(soPushed);
    ADetail := 'push failed: ' + Trim(r.StdErr);
    Exit(soError);
  end;

  // behind>0
  if ahead = 0 then
  begin
    CollectIncoming;
    r := AGit.Merge(remoteRef);                    // fast-forward only
    if r.Ok then Exit(soPulled);
    ADetail := 'fast-forward failed: ' + Trim(r.StdErr);
    Exit(soError);
  end;

  // diverged: a merge would author a commit -- not in managed mode
  ADetail := 'diverged from remote; commit/merge manually to sync';
  Result := soConflict;
end;

end.
