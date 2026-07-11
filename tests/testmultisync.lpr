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

program testmultisync;

{ Bidirectional multi-machine sync test against local bare repos (git backend,
  no network, no GitHub). Simulates two machines running the real sync engine --
  each is its own working tree + config + TSyncEngine, both talking to the same
  local bare .gotbox and submodule upstreams.

  Flow:
    1. machine 1 creates the .gotbox root and adds a submodule ("proj")
    2. machine 2 clones the .gotbox root (a fresh machine)
    3. machine 1 creates a loose root file and a file inside the submodule
       -> machine 2 must receive BOTH (root file via .gotbox, submodule file via
          the submodule's own upstream, with the gitlink bump carried along)
    4. machine 2 deletes the root file AND the submodule file
       -> machine 1 must see BOTH deletions

  This is also the harness for deeper multi-machine scenarios (deep/nested
  submodules, history-cap trims, a deleted top folder that still holds a nested
  git repo, ...): add a new numbered block that changes state on one machine and
  asserts convergence on the other.

  Determinism: the engines run with watchers + a short poll interval, but each
  wait loop also calls SyncAllNow on both engines every tick so convergence is
  driven explicitly rather than left to timers -- then asserts the expected
  state within a generous deadline. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Classes,
  gboxlog,
  gboxconfigstore,
  gboxgitrunner,
  gboxsuper,
  gboxengine,
  gboxstatusmodel;

var
  failures: Integer = 0;
  engine1, engine2, engine3: TSyncEngine;

  procedure Check(ACond: Boolean; const AName: string);
  begin
    if ACond then WriteLn('  ok   - ', AName)
    else
    begin
      WriteLn('  FAIL - ', AName);
      Inc(failures);
    end;
    Flush(Output);   // flush so the last result survives a hard kill (timeout)
  end;

  { Flushed progress marker. On a hang the runner kills the process and prints
    the tail of the log, so the last "STEP" line pinpoints where it hung. Flush
    is essential: redirected stdout is block-buffered and would be lost on kill. }
  procedure Step(const AMsg: string);
  begin
    WriteLn('== STEP: ', AMsg);
    Flush(Output);
  end;

  { Recursively remove a directory (RTL has no DeleteDirectory). }
  procedure RmRf(const ADir: string);
  var
    sr: TSearchRec;
    full: string;
  begin
    if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, sr) = 0 then
    begin
      try
        repeat
          if (sr.Name = '.') or (sr.Name = '..') then Continue;
          full := IncludeTrailingPathDelimiter(ADir) + sr.Name;
          if (sr.Attr and faDirectory) <> 0 then RmRf(full)
          else
          begin
            {$IFDEF WINDOWS}
            FileSetAttr(full, faNormal);   // git pack/object files are read-only on Windows
            {$ENDIF}
            DeleteFile(full);
          end;
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
    end;
    RemoveDir(ADir);
  end;

  procedure WriteFile(const APath, AContent: string);
  var
    f: TStringList;
  begin
    f := TStringList.Create;
    try
      f.Add(AContent);
      f.SaveToFile(APath);
    finally
      f.Free;
    end;
  end;

  { True if AFile exists in AWorkDir and its content contains ASubstr. }
  function FileHas(const AWorkDir, AFile, ASubstr: string): Boolean;
  var
    full: string;
    f: TStringList;
  begin
    Result := False;
    full := IncludeTrailingPathDelimiter(AWorkDir) + SetDirSeparators(AFile);
    if not FileExists(full) then Exit;
    f := TStringList.Create;
    try
      f.LoadFromFile(full);
      Result := Pos(ASubstr, f.Text) > 0;
    finally
      f.Free;
    end;
  end;

  function Missing(const AWorkDir, AFile: string): Boolean;
  begin
    Result := not FileExists(IncludeTrailingPathDelimiter(AWorkDir) +
      SetDirSeparators(AFile));
  end;

  { True if AWorkDir tracks APath in its git index (a committed file/gitlink). }
  function Tracked(const AWorkDir, APath: string): Boolean;
  var
    g: TGitRunner;
  begin
    g := TGitRunner.Create(AWorkDir);
    try
      Result := g.Git(['ls-files', '--error-unmatch', APath]).Ok;
    finally
      g.Free;
    end;
  end;

  { True if ARoot's .git/info/exclude mentions ASubstr (the stray-repo block). }
  function ExcludeHas(const ARoot, ASubstr: string): Boolean;
  var
    f: TStringList;
    p: string;
  begin
    Result := False;
    p := IncludeTrailingPathDelimiter(ARoot) + '.git' + PathDelim + 'info' +
      PathDelim + 'exclude';
    if not FileExists(p) then Exit;
    f := TStringList.Create;
    try
      f.LoadFromFile(p);
      Result := Pos(ASubstr, f.Text) > 0;
    finally
      f.Free;
    end;
  end;

  { True if ARoot's .gitmodules registers a submodule at path APath. Matches the
    whole "path = <APath>" line (a substring test would let "path = proj" match
    "path = projects/notes"). }
  function SubmoduleRegistered(const ARoot, APath: string): Boolean;
  var
    f: TStringList;
    p: string;
    i: Integer;
  begin
    Result := False;
    p := IncludeTrailingPathDelimiter(ARoot) + '.gitmodules';
    if not FileExists(p) then Exit;
    f := TStringList.Create;
    try
      f.LoadFromFile(p);
      for i := 0 to f.Count - 1 do
        if Trim(f[i]) = 'path = ' + APath then Exit(True);
    finally
      f.Free;
    end;
  end;

  { Drive one convergence tick: push+pull on both engines, run any queued
    submodule reconcile (the engine marshals it to the main thread via
    TThread.Queue, exactly as the daemon does -- so the test must pump it), then
    a short sleep. }
  procedure Tick;
  begin
    if Assigned(engine1) then engine1.SyncAllNow;
    if Assigned(engine2) then engine2.SyncAllNow;
    if Assigned(engine3) then engine3.SyncAllNow;
    CheckSynchronize(0);
    Sleep(600);
  end;

  { Drive a single engine for ATicks cycles (used while the other machine is
    "offline"/stopped, so its changes commit+push without the other re-asserting). }
  procedure DriveOne(AEngine: TSyncEngine; ATicks: Integer);
  var
    i: Integer;
  begin
    for i := 1 to ATicks do
    begin
      if Assigned(AEngine) then AEngine.SyncAllNow;
      CheckSynchronize(0);
      Sleep(400);
    end;
  end;

var
  base, root1, root2, root3, detail: string;
  cfg1, cfg2, cfg3: TGotConfig;
  status1, status2, status3: TStatusModel;
  gotboxBare: string;
  g: TGitRunner;
  deadline: TDateTime;
  ready: Boolean;
  tickN: Integer;   // heartbeat counter for the phase-8 catch-up wait

  { Fill a fresh config for the git (local) backend. }
  procedure InitCfg(ACfg: TGotConfig; const ARoot, AMachine: string);
  begin
    ACfg.RootDir := ARoot;
    ACfg.MachineName := AMachine;
    ACfg.RemoteKind := 'git';
    ACfg.SshBase := ExcludeTrailingPathDelimiter(base);
    ACfg.CommitDebounceMs := 300;
    ACfg.PullIntervalSec := 2;
  end;

begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-multi-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  root1 := IncludeTrailingPathDelimiter(base) + 'm1';
  root2 := IncludeTrailingPathDelimiter(base) + 'm2';
  root3 := IncludeTrailingPathDelimiter(base) + 'm3';
  ForceDirectories(root1);
  WriteLn('workspace: ', base);

  cfg1 := TGotConfig.Create;
  cfg2 := TGotConfig.Create;
  cfg3 := TGotConfig.Create;
  status1 := TStatusModel.Create;
  status2 := TStatusModel.Create;
  status3 := TStatusModel.Create;
  engine1 := nil;
  engine2 := nil;
  engine3 := nil;
  try
    // ---- machine 1: create the .gotbox root + a submodule "proj" ------------
    InitCfg(cfg1, root1, 'm1');
    Step('setup: m1 EnsureGotboxRoot');
    Check(EnsureGotboxRoot(cfg1, '', detail), 'm1: EnsureGotboxRoot (' + detail + ')');
    Step('setup: m1 AddSubmodule proj');
    Check(AddSubmodule(cfg1, '', 'proj', 'projup', '', True, detail),
      'm1: add submodule proj (' + detail + ')');
    gotboxBare := IncludeTrailingPathDelimiter(base) + '.gotbox.git';

    // ---- machine 2: a fresh clone of the .gotbox root -----------------------
    Step('setup: m2 clone .gotbox');
    g := TGitRunner.Create('');
    try
      Check(g.Clone(gotboxBare, root2).Ok, 'm2: clone .gotbox root');
    finally
      g.Free;
    end;
    InitCfg(cfg2, root2, 'm2');

    Step('setup: start engine1 + engine2');
    engine1 := TSyncEngine.Create(cfg1, '', status1);
    engine2 := TSyncEngine.Create(cfg2, '', status2);
    engine1.Start;
    engine2.Start;

    // machine 2 must auto-check-out the submodule the clone brought as a bare
    // gitlink, and spawn a worker for it
    Step('phase 0: wait m2 auto-checkout submodule');
    deadline := Now + EncodeTime(0, 0, 15, 0);
    repeat Tick until IsGitWorkTree(IncludeTrailingPathDelimiter(root2) + 'proj')
      or (Now > deadline);
    Check(IsGitWorkTree(IncludeTrailingPathDelimiter(root2) + 'proj'),
      'm2: submodule auto-checked-out on the fresh clone');

    // ---- (1) machine 1 creates content -> machine 2 must receive it ---------
    Step('phase 1: m1 creates content -> m2 receives');
    WriteFile(IncludeTrailingPathDelimiter(root1) + 'rootnote.txt', 'from-m1-root');
    WriteFile(IncludeTrailingPathDelimiter(root1) + 'proj' + PathDelim +
      'subnote.txt', 'from-m1-sub');

    DriveOne(engine1, 6);   // push from m1 alone first (avoid 2-writer contention)
    deadline := Now + EncodeTime(0, 0, 15, 0);
    repeat
      Tick;
      ready := FileHas(root2, 'rootnote.txt', 'from-m1-root') and
        FileHas(root2, 'proj/subnote.txt', 'from-m1-sub');
    until ready or (Now > deadline);
    Check(FileHas(root2, 'rootnote.txt', 'from-m1-root'),
      'm2: received loose root file created on m1');
    Check(FileHas(root2, 'proj/subnote.txt', 'from-m1-sub'),
      'm2: received submodule file created on m1 (gitlink carried across)');

    // ---- (2) machine 2 deletes both files -> machine 1 must see deletions ---
    Step('phase 2: m2 deletes files -> m1 sees deletions');
    DeleteFile(IncludeTrailingPathDelimiter(root2) + 'rootnote.txt');
    DeleteFile(IncludeTrailingPathDelimiter(root2) + 'proj' + PathDelim +
      'subnote.txt');

    DriveOne(engine2, 6);   // push the deletions from m2 alone first
    deadline := Now + EncodeTime(0, 0, 15, 0);
    repeat
      Tick;
      ready := Missing(root1, 'rootnote.txt') and Missing(root1, 'proj/subnote.txt');
    until ready or (Now > deadline);
    Check(Missing(root1, 'rootnote.txt'),
      'm1: saw loose root file deletion from m2');
    Check(Missing(root1, 'proj/subnote.txt'),
      'm1: saw submodule file deletion from m2');

    // ---- (3) watcher-only variant: NO SyncAllNow nudging at all -------------
    // A create on m1 must still reach m2 purely via m1's file-watcher (which
    // commits+pushes after the debounce) and the periodic pull timer on both
    // sides (PullIntervalSec). This is slower and more timing-sensitive than the
    // driven path above, but it proves those two triggers work end to end -- for
    // the submodule too (proj's watcher pushes its content; the root's periodic
    // timer then carries the gitlink bump). The loop below only sleeps.
    Step('phase 3: watcher-only propagation (no SyncAllNow)');
    WriteFile(IncludeTrailingPathDelimiter(root1) + 'watch.txt', 'watcher-m1-root');
    WriteFile(IncludeTrailingPathDelimiter(root1) + 'proj' + PathDelim +
      'watch_sub.txt', 'watcher-m1-sub');

    deadline := Now + EncodeTime(0, 0, 20, 0);
    repeat
      CheckSynchronize(0);   // runtime plumbing only (as the daemon does)
      Sleep(400);            // NB: no engine.SyncAllNow -- watcher + pull timer only
      ready := FileHas(root2, 'watch.txt', 'watcher-m1-root') and
        FileHas(root2, 'proj/watch_sub.txt', 'watcher-m1-sub');
    until ready or (Now > deadline);
    Check(FileHas(root2, 'watch.txt', 'watcher-m1-root'),
      'm2: received root file with no explicit sync (watcher + pull timer)');
    Check(FileHas(root2, 'proj/watch_sub.txt', 'watcher-m1-sub'),
      'm2: received submodule file with no explicit sync (watcher + pull timer)');

    // ---- (4) add + remove a plain top-level folder --------------------------
    Step('phase 4: add + remove a plain top-level folder');
    ForceDirectories(IncludeTrailingPathDelimiter(root1) + 'docs');
    WriteFile(IncludeTrailingPathDelimiter(root1) + 'docs' + PathDelim + 'a.txt',
      'docs-data');
    DriveOne(engine1, 6);
    deadline := Now + EncodeTime(0, 0, 15, 0);
    repeat Tick until FileHas(root2, 'docs/a.txt', 'docs-data') or (Now > deadline);
    Check(FileHas(root2, 'docs/a.txt', 'docs-data'),
      'm2: received a new top-level folder created on m1');

    RmRf(IncludeTrailingPathDelimiter(root1) + 'docs');
    DriveOne(engine1, 6);
    deadline := Now + EncodeTime(0, 0, 15, 0);
    repeat Tick until Missing(root2, 'docs/a.txt') or (Now > deadline);
    Check(Missing(root2, 'docs/a.txt'),
      'm2: saw the top-level folder deletion from m1');

    // ---- (5) add a DEEP (relative-path) submodule on m1 -> m2 checks it out -
    // structural change: stop m1's engine so AddSubmodule doesn't race a live
    // worker on the index, then restart. m2 picks it up via its own reconcile
    // (which stops/starts and checks the new submodule out) once the new
    // .gitmodules/gitlink is pulled.
    Step('phase 5: add deep submodule projects/notes (stop engine1)');
    engine1.Stop;
    Step('phase 5: engine1 stopped; AddSubmodule projects/notes');
    Check(AddSubmodule(cfg1, '', 'projects/notes', 'notesup', '', True, detail),
      'm1: add deep submodule projects/notes (' + detail + ')');
    WriteFile(IncludeTrailingPathDelimiter(root1) + 'projects' + PathDelim +
      'notes' + PathDelim + 'note.md', 'deep-sub-data');
    Step('phase 5: restart engine1');
    engine1.Start;

    deadline := Now + EncodeTime(0, 0, 20, 0);
    repeat
      Tick;
      ready := IsGitWorkTree(IncludeTrailingPathDelimiter(root2) + 'projects' +
        PathDelim + 'notes') and FileHas(root2, 'projects/notes/note.md', 'deep-sub-data');
    until ready or (Now > deadline);
    Check(IsGitWorkTree(IncludeTrailingPathDelimiter(root2) + 'projects' + PathDelim +
      'notes'), 'm2: checked out the deep submodule added on m1');
    Check(FileHas(root2, 'projects/notes/note.md', 'deep-sub-data'),
      'm2: received the deep submodule''s content');

    // ---- (6) remove a submodule on m1 -> m2 loses it ------------------------
    // Deleting the working folder unlinks the submodule (drop gitlink +
    // .gitmodules entry, keep .git/modules). Assert convergence in two steps:
    // quiesce m2 first, because otherwise both engines race on .gotbox -- m2
    // keeps re-committing the proj gitlink it still has while m1 is removing it,
    // and they only settle once m2 reconciles. So: stop m2, let m1 remove +
    // push, then start m2 to pull the settled removal and reconcile its workers.
    Step('phase 6: remove submodule proj (stop engine2 + engine1)');
    engine2.Stop;
    engine1.Stop;
    Step('phase 6: engines stopped; RmRf proj + restart engine1');
    RmRf(IncludeTrailingPathDelimiter(root1) + 'proj');
    engine1.Start;
    deadline := Now + EncodeTime(0, 0, 20, 0);
    repeat
      engine1.SyncAllNow;
      CheckSynchronize(0);
      Sleep(400);
    until (not SubmoduleRegistered(root1, 'proj')) or (Now > deadline);
    Check(not SubmoduleRegistered(root1, 'proj'),
      'm1: removed submodule unlinked from its own .gitmodules');

    Step('phase 6: restart engine2 to pull removal + reconcile');
    engine2.Start;   // m2 now pulls the settled removal and reconciles
    deadline := Now + EncodeTime(0, 0, 20, 0);
    repeat
      Tick;
      ready := (not SubmoduleRegistered(root2, 'proj')) and (not Tracked(root2, 'proj'));
    until ready or (Now > deadline);
    Check(not SubmoduleRegistered(root2, 'proj'),
      'm2: saw the submodule removal (gone from .gitmodules)');
    Check(not Tracked(root2, 'proj'),
      'm2: removed submodule gitlink no longer tracked');

    // ---- (7) a stray nested git repo inside a folder ------------------------
    // A folder holding BOTH a normal file (must sync) and a nested git repo
    // (must be excluded, never committed as a gitlink, never propagated).
    Step('phase 7: stray nested git repo inside a folder');
    ForceDirectories(IncludeTrailingPathDelimiter(root1) + 'mixed');
    WriteFile(IncludeTrailingPathDelimiter(root1) + 'mixed' + PathDelim + 'keep.txt',
      'mixed-keep');
    ForceDirectories(IncludeTrailingPathDelimiter(root1) + 'mixed' + PathDelim + 'stray');
    with TGitRunner.Create(IncludeTrailingPathDelimiter(root1) + 'mixed' +
      PathDelim + 'stray') do
    try
      Git(['init', '-b', 'main']);
      Git(['config', 'user.name', 's']);
      Git(['config', 'user.email', 's@s']);
    finally
      Free;
    end;
    WriteFile(IncludeTrailingPathDelimiter(root1) + 'mixed' + PathDelim + 'stray' +
      PathDelim + 'inner.txt', 'stray-inner');
    with TGitRunner.Create(IncludeTrailingPathDelimiter(root1) + 'mixed' +
      PathDelim + 'stray') do
    try
      Git(['add', '-A']);
      Git(['commit', '-m', 'stray inner']);
    finally
      Free;
    end;

    DriveOne(engine1, 6);
    deadline := Now + EncodeTime(0, 0, 15, 0);
    repeat Tick until FileHas(root2, 'mixed/keep.txt', 'mixed-keep') or (Now > deadline);
    Check(FileHas(root2, 'mixed/keep.txt', 'mixed-keep'),
      'm2: received the normal sibling of a stray nested repo');
    Check(ExcludeHas(root1, 'mixed/stray'),
      'm1: nested repo added to .git/info/exclude (not committed as a gitlink)');
    Check(not Tracked(root1, 'mixed/stray'),
      'm1: stray nested repo is NOT tracked as a gitlink');
    Check(Missing(root2, 'mixed/stray/inner.txt'),
      'm2: stray nested repo content did NOT propagate');

    // ---- (7b) delete a top folder that still holds a nested git repo --------
    // (the real-world case): removing the folder drops the tracked sibling on
    // both machines; nothing crashes on the excluded repo left behind locally.
    Step('phase 7b: delete top folder holding a nested repo');
    RmRf(IncludeTrailingPathDelimiter(root1) + 'mixed');
    DriveOne(engine1, 6);
    deadline := Now + EncodeTime(0, 0, 15, 0);
    repeat Tick until Missing(root2, 'mixed/keep.txt') or (Now > deadline);
    Check(Missing(root2, 'mixed/keep.txt'),
      'm2: saw deletion of a top folder that had held a nested repo');

    // ---- (8) m2 offline while m1 keeps working; m2 catches up on restart ----
    // The "not continuously synced" case (a laptop that was powered off): m2's
    // engine is stopped while m1 accumulates a batch of changes -- add a file,
    // delete a file, and add a whole new submodule -- then m2 comes back and must
    // reconcile the entire batch at once (not just the latest change).
    Step('phase 8: m2 offline; m1 batches changes (stop engine2)');
    engine2.Stop;   // m2 goes offline

    WriteFile(IncludeTrailingPathDelimiter(root1) + 'offline_add.txt',
      'added-while-m2-offline');
    DeleteFile(IncludeTrailingPathDelimiter(root1) + 'watch.txt');  // (synced in phase 3)
    DriveOne(engine1, 6);   // m1 commits+pushes these while m2 is offline

    Step('phase 8: AddSubmodule offsub while m2 offline (stop engine1)');
    engine1.Stop;           // structural: add a submodule while m2 is offline
    Check(AddSubmodule(cfg1, '', 'offsub', 'offsubup', '', True, detail),
      'm1: add submodule offsub while m2 offline (' + detail + ')');
    WriteFile(IncludeTrailingPathDelimiter(root1) + 'offsub' + PathDelim + 'o.txt',
      'offline-sub-data');
    engine1.Start;
    DriveOne(engine1, 6);   // m1 pushes the new submodule's content

    // ...and delete a TOP FOLDER that itself contains a submodule (projects/
    // holds the deep submodule projects/notes) -- m1 unlinks the submodule.
    Step('phase 8: delete projects/ (submodule-containing top folder)');
    engine1.Stop;
    RmRf(IncludeTrailingPathDelimiter(root1) + 'projects');
    engine1.Start;
    deadline := Now + EncodeTime(0, 0, 20, 0);
    repeat
      engine1.SyncAllNow;
      CheckSynchronize(0);
      Sleep(400);
    until (not SubmoduleRegistered(root1, 'projects/notes')) or (Now > deadline);
    Check(not SubmoduleRegistered(root1, 'projects/notes'),
      'm1: deleting a submodule-containing top folder unlinked the submodule');

    Step('phase 8: restart engine2 -- catch up on the whole batch');
    engine2.Start;          // m2 back online -- catch up on the whole batch at once
    Step('phase 8: engine2.Start returned; entering catch-up wait');
    deadline := Now + EncodeTime(0, 0, 20, 0);
    tickN := 0;
    repeat
      Inc(tickN);
      Step('phase 8: catch-up tick ' + IntToStr(tickN));   // last line if a Tick hangs
      Tick;
      ready := FileHas(root2, 'offline_add.txt', 'added-while-m2-offline') and
        Missing(root2, 'watch.txt') and
        IsGitWorkTree(IncludeTrailingPathDelimiter(root2) + 'offsub') and
        FileHas(root2, 'offsub/o.txt', 'offline-sub-data') and
        (not SubmoduleRegistered(root2, 'projects/notes')) and
        (not Tracked(root2, 'projects/notes'));
    until ready or (Now > deadline);
    Check(FileHas(root2, 'offline_add.txt', 'added-while-m2-offline'),
      'm2 (was offline) caught up: file added while it was offline');
    Check(Missing(root2, 'watch.txt'),
      'm2 (was offline) caught up: applied a deletion made while offline');
    Check(IsGitWorkTree(IncludeTrailingPathDelimiter(root2) + 'offsub') and
      FileHas(root2, 'offsub/o.txt', 'offline-sub-data'),
      'm2 (was offline) caught up: checked out a submodule added while offline');
    Check(not SubmoduleRegistered(root2, 'projects/notes'),
      'm2 (was offline) caught up: submodule in a deleted top folder unlinked');
    Check(not Tracked(root2, 'projects/notes'),
      'm2 (was offline) caught up: that submodule''s gitlink no longer tracked');

    // ---- (9) a THIRD machine: 3-way sync verification -----------------------
    // m3 joins late (fresh clone), catches up to the accumulated state, then a
    // change must fan out to ALL other machines both ways: m1 -> {m2, m3} and
    // m3 -> {m1, m2} -- including submodule content, not just loose files.
    Step('phase 9: third machine m3 joins (clone + start)');
    Tick;
    Tick;   // flush m1/m2 pushes so the bare is current before m3 clones it
    g := TGitRunner.Create('');
    try
      Check(g.Clone(gotboxBare, root3).Ok, 'm3: clone .gotbox root');
    finally
      g.Free;
    end;
    InitCfg(cfg3, root3, 'm3');
    engine3 := TSyncEngine.Create(cfg3, '', status3);
    engine3.Start;

    deadline := Now + EncodeTime(0, 0, 20, 0);
    repeat
      Tick;
      ready := FileHas(root3, 'offline_add.txt', 'added-while-m2-offline') and
        IsGitWorkTree(IncludeTrailingPathDelimiter(root3) + 'offsub') and
        FileHas(root3, 'offsub/o.txt', 'offline-sub-data');
    until ready or (Now > deadline);
    Check(FileHas(root3, 'offline_add.txt', 'added-while-m2-offline'),
      'm3: caught up to the accumulated loose-file state');
    Check(IsGitWorkTree(IncludeTrailingPathDelimiter(root3) + 'offsub') and
      FileHas(root3, 'offsub/o.txt', 'offline-sub-data'),
      'm3: checked out the accumulated submodule');

    // m1 -> all: a root file AND a submodule file reach BOTH m2 and m3. Push
    // from m1 alone first (three engines all pushing .gotbox at once just race
    // and thrash), then let m2/m3 fast-forward it in.
    Step('phase 9: m1 -> {m2,m3} fan-out (root + submodule)');
    WriteFile(IncludeTrailingPathDelimiter(root1) + 'tw_root.txt', 'tw-from-m1');
    WriteFile(IncludeTrailingPathDelimiter(root1) + 'offsub' + PathDelim +
      'tw_sub.txt', 'tw-sub-from-m1');
    DriveOne(engine1, 8);
    deadline := Now + EncodeTime(0, 0, 20, 0);
    repeat
      Tick;
      ready := FileHas(root2, 'tw_root.txt', 'tw-from-m1') and
        FileHas(root3, 'tw_root.txt', 'tw-from-m1') and
        FileHas(root2, 'offsub/tw_sub.txt', 'tw-sub-from-m1') and
        FileHas(root3, 'offsub/tw_sub.txt', 'tw-sub-from-m1');
    until ready or (Now > deadline);
    Check(FileHas(root2, 'tw_root.txt', 'tw-from-m1') and
      FileHas(root3, 'tw_root.txt', 'tw-from-m1'),
      'm1 root change reached BOTH m2 and m3 (3-way)');
    Check(FileHas(root2, 'offsub/tw_sub.txt', 'tw-sub-from-m1') and
      FileHas(root3, 'offsub/tw_sub.txt', 'tw-sub-from-m1'),
      'm1 submodule change reached BOTH m2 and m3 (3-way)');

    // m3 -> all: a change originating on m3 reaches m1 and m2 (push m3 alone
    // first, same reason).
    Step('phase 9: m3 -> {m1,m2} fan-out');
    WriteFile(IncludeTrailingPathDelimiter(root3) + 'tw_from3.txt', 'tw-from-m3');
    DriveOne(engine3, 8);
    deadline := Now + EncodeTime(0, 0, 20, 0);
    repeat
      Tick;
      ready := FileHas(root1, 'tw_from3.txt', 'tw-from-m3') and
        FileHas(root2, 'tw_from3.txt', 'tw-from-m3');
    until ready or (Now > deadline);
    Check(FileHas(root1, 'tw_from3.txt', 'tw-from-m3'),
      'm3 change reached m1 (3-way)');
    Check(FileHas(root2, 'tw_from3.txt', 'tw-from-m3'),
      'm3 change reached m2 (3-way)');

    engine1.Stop;
    engine2.Stop;
    engine3.Stop;
  finally
    engine1.Free;
    engine2.Free;
    engine3.Free;
    status1.Free;
    status2.Free;
    status3.Free;
    cfg1.Free;
    cfg2.Free;
    cfg3.Free;
  end;

  // leave the workspace on failure for inspection; clean it up on success
  if failures = 0 then RmRf(base);

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
