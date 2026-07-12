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

program teste2e;

{ Binary end-to-end test: launches TWO real `gotboxd` processes (the headless,
  LCL-free daemon -- no GUI, no X server) against a shared local bare .gotbox,
  and asserts sync purely by observing the filesystem. This is a black-box test
  of the shipped binary, unlike the in-process API tests (testmultisync et al.).

  Each daemon is isolated via its own XDG_CONFIG_HOME / XDG_DATA_HOME (so it
  reads its own config.json and keeps its own single-instance pid file). DISPLAY
  is stripped from the child environment to prove the daemon needs no display.

  Requires the `gotboxd` binary. It is found via $GOTBOXD, else ../gotboxd(.exe)
  next to the repo root; if absent the test SKIPS (exit 0) rather than failing,
  so environments that didn't build it aren't broken. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  SysUtils, Classes, Process,
  gboxconfigstore, gboxgitrunner, gboxsuper, gboxrootlock;

var
  failures: Integer = 0;
  base, gotboxd, emptyGitCfg: string;
  proc1, proc2, proc3: TProcess;

  procedure Check(ACond: Boolean; const AName: string);
  begin
    if ACond then WriteLn('  ok   - ', AName)
    else
    begin
      WriteLn('  FAIL - ', AName);
      Inc(failures);
    end;
  end;

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
            FileSetAttr(full, faNormal);
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

  procedure WriteTextFile(const APath, AContent: string);
  var
    f: TStringList;
  begin
    ForceDirectories(ExtractFileDir(APath));
    f := TStringList.Create;
    try
      f.Add(AContent);
      f.SaveToFile(APath);
    finally
      f.Free;
    end;
  end;

  function FileHas(const AWorkDir, ARel, ASubstr: string): Boolean;
  var
    full: string;
    f: TStringList;
  begin
    Result := False;
    full := IncludeTrailingPathDelimiter(AWorkDir) + SetDirSeparators(ARel);
    if not FileExists(full) then Exit;
    f := TStringList.Create;
    try
      f.LoadFromFile(full);
      Result := Pos(ASubstr, f.Text) > 0;
    finally
      f.Free;
    end;
  end;

  function Missing(const AWorkDir, ARel: string): Boolean;
  begin
    Result := not FileExists(IncludeTrailingPathDelimiter(AWorkDir) +
      SetDirSeparators(ARel));
  end;

  { Build a child environment: inherit ours, but strip DISPLAY (prove headless)
    and force this machine's own config/data dirs + a hermetic git config. }
  procedure BuildEnv(ADst: TStrings; const ACfgHome, ADataHome: string);
  var
    i: Integer;
    n: string;
  begin
    ADst.Clear;
    for i := 1 to GetEnvironmentVariableCount do
    begin
      n := GetEnvironmentString(i);
      if (Pos('DISPLAY=', n) = 1) or (Pos('XDG_CONFIG_HOME=', n) = 1) or
        (Pos('XDG_DATA_HOME=', n) = 1) or (Pos('GIT_CONFIG_GLOBAL=', n) = 1) or
        (Pos('GIT_CONFIG_SYSTEM=', n) = 1) then
        Continue;
      ADst.Add(n);
    end;
    ADst.Add('XDG_CONFIG_HOME=' + ACfgHome);
    ADst.Add('XDG_DATA_HOME=' + ADataHome);
    ADst.Add('GIT_CONFIG_GLOBAL=' + emptyGitCfg);
    ADst.Add('GIT_CONFIG_SYSTEM=' + emptyGitCfg);
  end;

  { Launch a real gotboxd (foreground, so TProcess keeps a handle to it). }
  function StartDaemon(const ACfgHome, ADataHome: string;
    ATakeover: Boolean = False): TProcess;
  begin
    Result := TProcess.Create(nil);
    Result.Executable := gotboxd;
    BuildEnv(Result.Environment, ACfgHome, ADataHome);
    if ATakeover then Result.Parameters.Add('--takeover');
    Result.Options := [];   // asynchronous: do not wait for exit
    Result.Execute;
  end;

  { SIGTERM the daemon and let it flush (its handler stops the engine cleanly). }
  procedure StopDaemon(var AProc: TProcess);
  var
    i: Integer;
  begin
    if AProc = nil then Exit;
    try
      if AProc.Running then
        {$IFDEF UNIX}
        // explicit SIGTERM so the daemon runs its clean-shutdown path and
        // RELEASES its root lock (TProcess.Terminate doesn't deliver a clean
        // SIGTERM here, leaving a fresh lock that a rapid restart would refuse)
        FpKill(AProc.ProcessID, SIGTERM);
        {$ELSE}
        AProc.Terminate(0);
        {$ENDIF}
    except
    end;
    for i := 1 to 50 do
    begin
      if not AProc.Running then Break;
      Sleep(100);
    end;
    AProc.Free;
    AProc := nil;
  end;

  { Write <base>/<cfgSub>/gotbox/config.json for the git (local) backend. }
  procedure SaveConfig(ACfg: TGotConfig; const ACfgSub: string);
  var
    store: TConfigStore;
  begin
    store := TConfigStore.Create(IncludeTrailingPathDelimiter(base) + ACfgSub +
      PathDelim + 'gotbox' + PathDelim + 'config.json');
    try
      store.Save(ACfg);
    finally
      store.Free;
    end;
  end;

  { Mark a submodule automatic in ACfg (link-dialog default is now managed; this
    test writes submodule content on m1 and needs it auto-committed/pushed). }
  procedure MarkAuto(ACfg: TGotConfig; const AName: string);
  var
    e: TRepoEntry;
  begin
    e := Default(TRepoEntry);
    e.LocalName := AName;
    e.AutoSync := True;
    ACfg.UpsertRepo(e);
  end;

var
  root1, root2, detail: string;
  cfg: TGotConfig;
  g: TGitRunner;
  i: Integer;
  ready: Boolean;

  { True once ACond holds, polling up to ASeconds. }
  function WaitUntilFile(const AWorkDir, ARel, ASubstr: string; ASeconds: Integer): Boolean;
  var
    s: Integer;
  begin
    for s := 1 to ASeconds * 2 do
    begin
      if FileHas(AWorkDir, ARel, ASubstr) then Exit(True);
      Sleep(500);
    end;
    Result := FileHas(AWorkDir, ARel, ASubstr);
  end;

  function WaitUntilGone(const AWorkDir, ARel: string; ASeconds: Integer): Boolean;
  var
    s: Integer;
  begin
    for s := 1 to ASeconds * 2 do
    begin
      if Missing(AWorkDir, ARel) then Exit(True);
      Sleep(500);
    end;
    Result := Missing(AWorkDir, ARel);
  end;

begin
  {$IFNDEF LINUX}
  // Two coexisting gotboxd processes with isolated config only works on Linux:
  // there, XDG_CONFIG_HOME isolates each daemon's config + its per-config pidfile
  // guard. Windows uses a process-GLOBAL single-instance mutex (a second gotboxd
  // just exits), and macOS keys the config dir off HOME rather than XDG -- so
  // this binary E2E test is Linux-only; skip cleanly elsewhere.
  WriteLn('  SKIP - binary end-to-end test runs on Linux only');
  WriteLn('ALL TESTS PASSED');
  Halt(0);
  {$ENDIF}

  // ---- locate the gotboxd binary; skip cleanly if it wasn't built ----------
  gotboxd := GetEnvironmentVariable('GOTBOXD');
  if (gotboxd = '') or (not FileExists(gotboxd)) then
  begin
    gotboxd := '';
    if FileExists('../gotboxd') then gotboxd := ExpandFileName('../gotboxd')
    else if FileExists('../gotboxd.exe') then gotboxd := ExpandFileName('../gotboxd.exe');
  end;
  if (gotboxd = '') or (not FileExists(gotboxd)) then
  begin
    WriteLn('  SKIP - gotboxd binary not found (build it: make gotboxd)');
    WriteLn('ALL TESTS PASSED');
    Halt(0);
  end;
  WriteLn('gotboxd: ', gotboxd);

  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-e2e-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  root1 := IncludeTrailingPathDelimiter(base) + 'm1';
  root2 := IncludeTrailingPathDelimiter(base) + 'm2';
  ForceDirectories(root1);
  emptyGitCfg := IncludeTrailingPathDelimiter(base) + 'empty.gitconfig';
  WriteTextFile(emptyGitCfg, '');
  WriteLn('workspace: ', base);

  proc1 := nil;
  proc2 := nil;
  proc3 := nil;
  cfg := TGotConfig.Create;
  try
    // ---- set up m1's .gotbox + both machines' config.json (in-process API) --
    cfg.RootDir := root1;
    cfg.MachineName := 'm1';
    cfg.RemoteKind := 'git';
    cfg.SshBase := ExcludeTrailingPathDelimiter(base);
    cfg.CommitDebounceMs := 300;
    cfg.PullIntervalSec := 2;
    Check(EnsureGotboxRoot(cfg, '', detail), 'setup: EnsureGotboxRoot (' + detail + ')');
    SaveConfig(cfg, 'cfg1');

    g := TGitRunner.Create('');
    try
      Check(g.Clone(ExcludeTrailingPathDelimiter(base) + PathDelim + '.gotbox.git',
        root2).Ok, 'setup: clone .gotbox for m2');
    finally
      g.Free;
    end;
    cfg.RootDir := root2;
    cfg.MachineName := 'm2';
    SaveConfig(cfg, 'cfg2');

    // ---- launch two real gotboxd processes (headless, no DISPLAY) -----------
    proc1 := StartDaemon(IncludeTrailingPathDelimiter(base) + 'cfg1',
      IncludeTrailingPathDelimiter(base) + 'data1');
    proc2 := StartDaemon(IncludeTrailingPathDelimiter(base) + 'cfg2',
      IncludeTrailingPathDelimiter(base) + 'data2');
    Sleep(1500);
    Check(proc1.Running and proc2.Running, 'both gotboxd processes started');

    // ---- (1) m1 creates a file -> m2 receives it ----------------------------
    WriteTextFile(IncludeTrailingPathDelimiter(root1) + 'note.txt', 'hello-from-m1');
    Check(WaitUntilFile(root2, 'note.txt', 'hello-from-m1', 30),
      'm2 received a file created on m1 (binary, headless)');

    // ---- (2) m2 deletes it -> m1 sees the deletion --------------------------
    DeleteFile(IncludeTrailingPathDelimiter(root2) + 'note.txt');
    Check(WaitUntilGone(root1, 'note.txt', 30),
      'm1 saw the deletion made on m2');

    // ---- (3) live submodule reconcile via the CheckSynchronize pump ---------
    // Add a submodule on m1 while m2 keeps running: m2's daemon must react to
    // the pulled .gitmodules change WITHOUT a restart (that reconcile is queued
    // to the daemon's main thread, which now pumps CheckSynchronize).
    StopDaemon(proc1);   // quiesce m1 so AddSubmodule doesn't race its worker
    cfg.RootDir := root1;
    cfg.MachineName := 'm1';
    Check(AddSubmodule(cfg, '', 'proj', 'projup', '', True, detail),
      'm1: add submodule proj (' + detail + ')');
    MarkAuto(cfg, 'proj');            // m1 must auto-commit/push the submodule file
    SaveConfig(cfg, 'cfg1');          // persist the mode for m1's daemon to read
    WriteTextFile(IncludeTrailingPathDelimiter(root1) + 'proj' + PathDelim +
      'sfile.txt', 'sub-from-m1');
    proc1 := StartDaemon(IncludeTrailingPathDelimiter(base) + 'cfg1',
      IncludeTrailingPathDelimiter(base) + 'data1');

    ready := False;
    for i := 1 to 80 do
    begin
      if IsGitWorkTree(IncludeTrailingPathDelimiter(root2) + 'proj') and
        FileHas(root2, 'proj/sfile.txt', 'sub-from-m1') then
      begin
        ready := True;
        Break;
      end;
      Sleep(500);
    end;
    Check(IsGitWorkTree(IncludeTrailingPathDelimiter(root2) + 'proj'),
      'm2 (running) checked out a submodule added on m1 -- live reconcile');
    Check(FileHas(root2, 'proj/sfile.txt', 'sub-from-m1'),
      'm2 (running) received the submodule''s content');

    // ---- (4) cross-machine root lock (the shared-folder guard) --------------
    // Simulate a SECOND machine (its own config dir) pointing at the SAME root
    // that m1's daemon already manages -- e.g. an NFS-shared folder. It must
    // refuse to run; then with --takeover it takes over and m1 self-stops, so
    // the two never drive one working tree at once.
    StopDaemon(proc2);   // done with the m1<->m2 sync tests; reduce noise
    cfg.RootDir := root1;
    cfg.MachineName := 'mC';
    SaveConfig(cfg, 'cfgC');

    proc3 := StartDaemon(IncludeTrailingPathDelimiter(base) + 'cfgC',
      IncludeTrailingPathDelimiter(base) + 'dataC');   // no --takeover
    for i := 1 to 24 do begin if not proc3.Running then Break; Sleep(250); end;
    Check(not proc3.Running,
      'a 2nd daemon on a root another instance manages refuses and exits');
    Check(ReadRootOwner(root1).Machine = 'm1',
      'the incumbent (m1) still owns the shared root after the refusal');
    Check(proc1.Running, 'the incumbent daemon keeps running');
    StopDaemon(proc3);

    proc3 := StartDaemon(IncludeTrailingPathDelimiter(base) + 'cfgC',
      IncludeTrailingPathDelimiter(base) + 'dataC', True);   // --takeover
    ready := False;
    for i := 1 to 24 do
    begin
      if ReadRootOwner(root1).Machine = 'mC' then begin ready := True; Break; end;
      Sleep(250);
    end;
    Check(ready, 'a --takeover daemon takes ownership of the shared root');
    ready := False;
    for i := 1 to 160 do   // up to ~40s: the incumbent notices at its next heartbeat
    begin
      if not proc1.Running then begin ready := True; Break; end;
      Sleep(250);
    end;
    Check(ready, 'the taken-over incumbent daemon (m1) self-stops');

    StopDaemon(proc1);
    StopDaemon(proc3);
  finally
    StopDaemon(proc1);
    StopDaemon(proc2);
    StopDaemon(proc3);
    cfg.Free;
  end;

  if failures = 0 then RmRf(base);   // keep the workspace on failure

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
