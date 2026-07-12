program testengine;

{ Phase-2 integration test of the superproject engine against local bare repos
  (git backend, no network): build a .gotbox root + one submodule, run the
  engine, change both a loose root file and a file inside the submodule, and
  verify each is committed/pushed to its OWN upstream (loose file -> .gotbox,
  submodule file -> the submodule's repo). }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Classes,
  gboxlog,
  gboxconfigstore,
  gboxgitrunner,
  gboxsuper,
  gboxsync,
  gboxengine,
  gboxstatusmodel;

var
  failures: Integer = 0;

  procedure Check(ACond: Boolean; const AName: string);
  begin
    if ACond then WriteLn('  ok   - ', AName)
    else
    begin
      WriteLn('  FAIL - ', AName);
      Inc(failures);
    end;
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
            DeleteFile(full);
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
    end;
    RemoveDir(ADir);
  end;

  { True if a clone of bare ABare contains a file whose content includes ASubstr. }
  function RemoteHasFile(const ABare, AFile, ASubstr: string): Boolean;
  var
    g: TGitRunner;
    tmp, content: string;
    f: TStringList;
  begin
    Result := False;
    tmp := IncludeTrailingPathDelimiter(GetTempDir) + 'gbchk-' +
      FormatDateTime('hhnnsszzz', Now) + IntToStr(Random(99999));
    g := TGitRunner.Create('');
    try
      if not g.Clone(ABare, tmp).Ok then Exit;
    finally
      g.Free;
    end;
    try
      if not FileExists(IncludeTrailingPathDelimiter(tmp) + AFile) then Exit;
      f := TStringList.Create;
      try
        f.LoadFromFile(IncludeTrailingPathDelimiter(tmp) + AFile);
        content := f.Text;
      finally
        f.Free;
      end;
      Result := Pos(ASubstr, content) > 0;
    finally
      // don't let repeated probe-clones pile up and starve a slow CI runner
      if DirectoryExists(tmp) then RmRf(tmp);
    end;
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

var
  base, root, detail: string;
  cfg: TGotConfig;
  status: TStatusModel;
  engine: TSyncEngine;
  deadline: TDateTime;
  gotboxBare, subBare: string;
  rootOK, subOK: Boolean;
  root2: string;
  cfg2: TGotConfig;
  status2: TStatusModel;
  engine2: TSyncEngine;
  g2, gsync: TGitRunner;
  rr: TGitResult;
begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-eng-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  root := IncludeTrailingPathDelimiter(base) + 'root';
  ForceDirectories(root);
  WriteLn('workspace: ', base);

  cfg := TGotConfig.Create;
  cfg.RootDir := root;
  cfg.MachineName := 'eng';
  cfg.RemoteKind := 'git';
  cfg.SshBase := ExcludeTrailingPathDelimiter(base);
  cfg.CommitDebounceMs := 300;
  cfg.PullIntervalSec := 2;   // periodic backstop if a watcher event is missed

  Check(EnsureGotboxRoot(cfg, '', detail), 'EnsureGotboxRoot (' + detail + ')');
  Check(AddSubmodule(cfg, '', 'proj', 'projup', '', True, detail),
    'add submodule proj (' + detail + ')');

  gotboxBare := IncludeTrailingPathDelimiter(base) + '.gotbox.git';
  subBare := IncludeTrailingPathDelimiter(base) + 'projup.git';

  status := TStatusModel.Create;
  engine := TSyncEngine.Create(cfg, '', status);
  try
    engine.Start;
    Check(engine.WorkerCount = 2, 'engine started 2 workers (root + submodule)');
    Sleep(500);   // let watchers register

    // a loose root file -> should land in .gotbox
    WriteFile(IncludeTrailingPathDelimiter(root) + 'rootnote.txt', 'loose-root-data');
    // a file inside the submodule -> should land in the submodule's upstream
    WriteFile(IncludeTrailingPathDelimiter(root) + 'proj' + PathDelim + 'subnote.txt',
      'submodule-data');

    rootOK := False;
    subOK := False;
    deadline := Now + EncodeTime(0, 0, 25, 0);
    repeat
      Sleep(700);
      if not rootOK then rootOK :=
          RemoteHasFile(gotboxBare, 'rootnote.txt', 'loose-root-data');
      if not subOK then subOK := RemoteHasFile(subBare, 'subnote.txt', 'submodule-data');
    until (rootOK and subOK) or (Now > deadline);

    engine.Stop;
  finally
    engine.Free;
    status.Free;
  end;

  Check(rootOK, 'loose root file synced to .gotbox');
  Check(subOK, 'submodule file synced to its own upstream');

  // ---- fresh machine: a plain (non-recursive) clone of the superproject brings
  // the submodule's gitlink + .gitmodules but leaves its working tree empty and
  // uninitialized -- the engine must auto-init/check it out so it can sync,
  // rather than getting stuck at "submodule not checked out".
  root2 := IncludeTrailingPathDelimiter(base) + 'root2';
  g2 := TGitRunner.Create('');
  try
    Check(g2.Clone(gotboxBare, root2).Ok, 'plain clone of .gotbox to a 2nd machine');
  finally
    g2.Free;
  end;
  Check(not IsGitWorkTree(IncludeTrailingPathDelimiter(root2) + 'proj'),
    'submodule NOT checked out after a plain clone (precondition)');

  cfg2 := TGotConfig.Create;
  cfg2.RootDir := root2;
  cfg2.MachineName := 'eng2';
  cfg2.RemoteKind := 'git';
  cfg2.SshBase := ExcludeTrailingPathDelimiter(base);
  cfg2.CommitDebounceMs := 300;
  cfg2.PullIntervalSec := 2;

  status2 := TStatusModel.Create;
  engine2 := TSyncEngine.Create(cfg2, '', status2);
  try
    engine2.Start;
    Check(IsGitWorkTree(IncludeTrailingPathDelimiter(root2) + 'proj'),
      'engine auto-checked-out the submodule on a fresh clone');
    Check(engine2.WorkerCount = 2,
      'engine started 2 workers on the fresh clone (root + submodule)');
    engine2.Stop;
  finally
    engine2.Free;
    status2.Free;
  end;
  cfg2.Free;

  // ---- deleting a checked-out submodule folder must UNLINK it (drop the gitlink
  // + .gitmodules entry) while KEEPING its repository (.git/modules/<name>), not
  // delete the actual repo. Uses the first workspace, where 'proj' is populated.
  RmRf(IncludeTrailingPathDelimiter(root) + 'proj');
  Check(not DirectoryExists(IncludeTrailingPathDelimiter(root) + 'proj'),
    'submodule folder deleted (precondition)');
  gsync := TGitRunner.Create(root);
  try
    RunSyncCycle(gsync, 'eng', detail, nil);
    rr := gsync.Git(['config', '-f', '.gitmodules', '--get-regexp', '\.path$']);
    Check((not rr.Ok) or (Pos('proj', rr.StdOut) = 0),
      'deleted submodule unlinked from .gitmodules');
    rr := gsync.Git(['ls-files', '--stage']);
    Check(Pos(#9 + 'proj', rr.StdOut) = 0, 'deleted submodule gitlink removed from index');
  finally
    gsync.Free;
  end;
  Check(DirectoryExists(IncludeTrailingPathDelimiter(root) + '.git' + PathDelim +
    'modules' + PathDelim + 'proj'),
    'submodule repository KEPT (.git/modules/proj still present)');

  cfg.Free;
  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
