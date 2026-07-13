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
    {$IFDEF WINDOWS}
    FileSetAttr(ADir, faNormal);
    {$ENDIF}
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
  base, root, detail, nested, deep: string;
  cfg: TGotConfig;
  git: TGitRunner;
  conflicts: TStringList;
  outcome: TSyncOutcome;
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

  // the github_share case: a gitlink already committed in HEAD whose folder has
  // NO .git and contains real files -> must be unstaged and its files synced
  ForceDirectories(IncludeTrailingPathDelimiter(root) + 'pre');
  with TGitRunner.Create(IncludeTrailingPathDelimiter(root) + 'pre') do
  try
    Git(['init', '-b', 'main']);
    Git(['config', 'user.name', 'p']);
    Git(['config', 'user.email', 'p@p']);
  finally
    Free;
  end;
  WriteFile(IncludeTrailingPathDelimiter(root) + 'pre' + PathDelim +
    'keep.txt', 'keepme');
  with TGitRunner.Create(IncludeTrailingPathDelimiter(root) + 'pre') do
  try
    Git(['add', '-A']);
    Git(['commit', '-m', 'inner']);
  finally
    Free;
  end;
  git := TGitRunner.Create(root);   // commit "pre" as a gitlink in .gotbox HEAD
  try
    git.Git(['add', 'pre']);
    git.Git(['commit', '-m', 'add gitlink']);
  finally
    git.Free;
  end;
  Check(not Tracked(root, 'pre/keep.txt'), 'pre is a gitlink (files not tracked yet)');
  RmRf(IncludeTrailingPathDelimiter(root) + 'pre' + PathDelim + '.git');  // de-embed
  conflicts.Clear;
  git := TGitRunner.Create(root);
  try
    git.Git(['config', 'user.name', 'stray']);
    git.Git(['config', 'user.email', 'stray@test']);
    RunSyncCycle(git, 'stray', detail, conflicts);
  finally
    git.Free;
  end;
  Check(Tracked(root, 'pre/keep.txt'),
    'committed gitlink with no .git is unstaged and its files synced');

  // --- deep (non-top-level) stray gitlink: the case that stalled real syncs ---
  // A still-embedded repo TWO levels down, already committed as a gitlink in
  // HEAD. A top-level-only scan misses it, so add -A keeps re-adding the gitlink
  // the unstage just removed -> an empty commit that fails every cycle and blocks
  // the pull. It must be found at depth, excluded, and never stall the cycle.
  ForceDirectories(IncludeTrailingPathDelimiter(root) + 'deepA' + PathDelim + 'deepB');
  deep := IncludeTrailingPathDelimiter(root) + 'deepA' + PathDelim + 'deepB' +
    PathDelim + 'stray';
  ForceDirectories(deep);
  with TGitRunner.Create(deep) do
  try
    Git(['init', '-b', 'main']);
    Git(['config', 'user.name', 'd']);
    Git(['config', 'user.email', 'd@d']);
  finally
    Free;
  end;
  WriteFile(deep + PathDelim + 'x.txt', 'deep inner');
  with TGitRunner.Create(deep) do
  try
    Git(['add', '-A']);
    Git(['commit', '-m', 'deep inner']);
  finally
    Free;
  end;
  // a normal file beside the deep stray, to prove content still syncs
  WriteFile(IncludeTrailingPathDelimiter(root) + 'deepA' + PathDelim + 'note.txt',
    'deep note');
  git := TGitRunner.Create(root);   // commit the deep repo as a gitlink in HEAD
  try
    git.Git(['add', 'deepA/deepB/stray']);
    git.Git(['commit', '-m', 'add deep gitlink']);
  finally
    git.Free;
  end;
  Check(Tracked(root, 'deepA/deepB/stray'), 'deep repo starts as a committed gitlink');

  conflicts.Clear;
  git := TGitRunner.Create(root);
  try
    git.Git(['config', 'user.name', 'stray']);
    git.Git(['config', 'user.email', 'stray@test']);
    outcome := RunSyncCycle(git, 'stray', detail, conflicts);
  finally
    git.Free;
  end;
  Check(outcome <> soError, 'deep stray: sync cycle does not error (' + detail + ')');
  Check(not Tracked(root, 'deepA/deepB/stray'),
    'deep stray gitlink is unstaged, not left tracked');
  Check(Tracked(root, 'deepA/note.txt'),
    'normal file beside a deep stray still syncs as content');

  // second cycle must be stable: the exclude persists so add -A doesn't re-add
  // the gitlink (no flapping), and the empty cycle still doesn't error
  conflicts.Clear;
  git := TGitRunner.Create(root);
  try
    git.Git(['config', 'user.name', 'stray']);
    git.Git(['config', 'user.email', 'stray@test']);
    outcome := RunSyncCycle(git, 'stray', detail, conflicts);
  finally
    git.Free;
  end;
  Check(outcome <> soError, 'deep stray: repeat cycle stays clean (' + detail + ')');
  Check(not Tracked(root, 'deepA/deepB/stray'),
    'deep stray stays untracked on the next cycle (no flapping)');

  cfg.Free;
  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
