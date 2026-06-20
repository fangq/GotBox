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

  cfg.Free;
  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
