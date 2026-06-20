program testworker;

{ End-to-end test of TRepoWorker against a local bare remote (no network/token):
  set up a linked repo, start the worker, modify a file, and verify the change
  is auto-committed and pushed to the remote. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Classes,
  gboxlog,
  gboxconfigstore,
  gboxgitrunner,
  gboxrepolink,
  gboxrepoworker;

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

  function RemoteCommitCount(const ABareRepo: string): Integer;
  var
    git: TGitRunner;
    r: TGitResult;
  begin
    git := TGitRunner.Create(ABareRepo);
    try
      r := git.Git(['rev-list', '--count', 'main']);
      if r.Ok then Result := StrToIntDef(Trim(r.StdOut), -1)
      else
        Result := -1;
    finally
      git.Free;
    end;
  end;

var
  base, root, projDir, bareRepo, detail: string;
  cfg: TGotConfig;
  linker: TRepoLinker;
  worker: TRepoWorker;
  before, after: Integer;
  deadline: TDateTime;
  f: TStringList;
begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-worker-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  root := IncludeTrailingPathDelimiter(base) + 'root';
  projDir := IncludeTrailingPathDelimiter(root) + 'proj';
  bareRepo := IncludeTrailingPathDelimiter(base) + 'remote.git';
  ForceDirectories(projDir);
  ForceDirectories(bareRepo);
  WriteLn('workspace: ', base);

  with TGitRunner.Create(bareRepo) do
  try
    Git(['init', '--bare', '-b', 'main']);
  finally
    Free;
  end;

  f := TStringList.Create;
  try
    f.Add('v1');
    f.SaveToFile(IncludeTrailingPathDelimiter(projDir) + 'notes.txt');
  finally
    f.Free;
  end;

  cfg := TGotConfig.Create;
  cfg.RootDir := root;
  cfg.GithubUser := 'tester';

  linker := TRepoLinker.Create(cfg, '');
  try
    Check(linker.EnsureLocalRepo(projDir, bareRepo, True, detail),
      'initial link/commit/push: ' + detail);
  finally
    linker.Free;
  end;

  before := RemoteCommitCount(bareRepo);
  Check(before >= 1, 'remote has initial commit (' + IntToStr(before) + ')');

  // small debounce so the test is quick; gc disabled
  worker := TRepoWorker.Create('proj', projDir, 'tester', '', 'testbox',
    300, 0, 0, 0, nil, cfg.IgnoreGlobs);
  try
    worker.Start;
    Sleep(500);                        // let the watcher register its inotify watches

    f := TStringList.Create;           // make an on-disk change
    try
      f.Add('v1');
      f.Add('v2 added by test');
      f.SaveToFile(IncludeTrailingPathDelimiter(projDir) + 'notes.txt');
    finally
      f.Free;
    end;

    // wait for the event to propagate, not a fixed duration: poll the remote
    // until it advances, with a hard deadline so a broken watcher fails fast
    deadline := Now + EncodeTime(0, 0, 10, 0);   // 10s cap
    repeat
      Sleep(150);
      after := RemoteCommitCount(bareRepo);
    until (after > before) or (Now > deadline);

    worker.Stop;
    worker.WaitFor;
  finally
    worker.Free;
  end;

  after := RemoteCommitCount(bareRepo);
  WriteLn('  remote commits: before=', before, ' after=', after);
  Check(after > before, 'worker auto-committed + pushed the change');

  cfg.Free;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
