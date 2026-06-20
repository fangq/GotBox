program teststray;

{ Verifies that a nested git repo dropped into the root (not a registered
  submodule) is never committed as a broken gitlink, and that de-embedding it
  (removing its .git) lets its files sync as regular content. Local git backend,
  no network. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  gboxlog,
  gboxconfigstore,
  gboxgitrunner,
  gboxsuper,
  gboxsync;

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

  function Tracked(const ARoot, APath: string): Boolean;
  var
    g: TGitRunner;
  begin
    g := TGitRunner.Create(ARoot);
    try
      Result := g.Git(['ls-files', '--error-unmatch', APath]).Ok;
    finally
      g.Free;
    end;
  end;

var
  base, root, detail, nested: string;
  cfg: TGotConfig;
  git: TGitRunner;
  conflicts: TStringList;
begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-stray-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  root := IncludeTrailingPathDelimiter(base) + 'root';
  ForceDirectories(root);
  WriteLn('workspace: ', base);

  cfg := TGotConfig.Create;
  cfg.RootDir := root;
  cfg.MachineName := 'stray';
  cfg.RemoteKind := 'git';
  cfg.SshBase := ExcludeTrailingPathDelimiter(base);

  // a loose file + the .gotbox root
  WriteFile(IncludeTrailingPathDelimiter(root) + 'readme.txt', 'hello');
  Check(EnsureGotboxRoot(cfg, '', detail), 'EnsureGotboxRoot (' + detail + ')');

  // drop a NESTED git repo in the root (simulates an accidental embedded repo)
  nested := IncludeTrailingPathDelimiter(root) + 'embedded';
  ForceDirectories(nested);
  with TGitRunner.Create(nested) do
  try
    Git(['init', '-b', 'main']);
    Git(['config', 'user.name', 'x']);
    Git(['config', 'user.email', 'x@x']);
  finally
    Free;
  end;
  WriteFile(nested + PathDelim + 'inner.txt', 'inner content');
  with TGitRunner.Create(nested) do
  try
    Git(['add', '-A']);
    Git(['commit', '-m', 'inner']);
  finally
    Free;
  end;

  conflicts := TStringList.Create;
  git := TGitRunner.Create(root);
  try
    git.Git(['config', 'user.name', 'stray']);
    git.Git(['config', 'user.email', 'stray@test']);
    RunSyncCycle(git, 'stray', detail, conflicts);
  finally
    git.Free;
  end;

  Check(not Tracked(root, 'embedded'), 'nested repo NOT committed as a gitlink');
  Check(Tracked(root, 'readme.txt'), 'normal loose file IS tracked');

  // de-embed: remove the nested .git -> its files should now sync as content
  RmRf(nested + PathDelim + '.git');
  conflicts.Clear;
  git := TGitRunner.Create(root);
  try
    git.Git(['config', 'user.name', 'stray']);
    git.Git(['config', 'user.email', 'stray@test']);
    RunSyncCycle(git, 'stray', detail, conflicts);
  finally
    git.Free;
  end;
  Check(Tracked(root, 'embedded/inner.txt'),
    'de-embedded folder files now tracked as regular content');

  cfg.Free;
  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
