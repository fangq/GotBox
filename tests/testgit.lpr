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

program testgit;

{ Console smoke test for gboxgitrunner: detect git, init a scratch repo, make a
  commit, and verify commit counting. Run: fpc -Fu../src/core testgit.lpr }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  gboxlog,
  gboxgitrunner;

var
  failures: Integer = 0;

  procedure Check(ACond: Boolean; const AName: string);
  begin
    if ACond then
      WriteLn('  ok   - ', AName)
    else
    begin
      WriteLn('  FAIL - ', AName);
      Inc(failures);
    end;
  end;

var
  git: TGitRunner;
  dir, exe: string;
  r: TGitResult;
begin
  exe := TGitRunner.DetectGit;
  WriteLn('git detected at: ', exe);
  Check(exe <> '', 'git is available');
  if exe = '' then Halt(1);

  Randomize;
  dir := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-test-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  ForceDirectories(dir);
  WriteLn('scratch repo: ', dir);

  git := TGitRunner.Create(dir);
  try
    r := git.Version;
    Check(r.Ok, 'git --version succeeds');

    r := git.InitRepo;
    Check(r.Ok, 'git init -b main');

    git.Git(['config', 'user.email', 'test@gotbox.local']);
    git.Git(['config', 'user.name', 'gotbox test']);

    // create a file and commit it
    with TStringList.Create do
    try
      Add('hello gotbox');
      SaveToFile(IncludeTrailingPathDelimiter(dir) + 'a.txt');
    finally
      Free;
    end;

    Check(git.HasUncommittedChanges, 'detects uncommitted change');
    r := git.AddAll;
    Check(r.Ok, 'git add -A');
    r := git.CommitAll('first commit');
    Check(r.Ok, 'git commit');
    Check(not git.HasUncommittedChanges, 'clean tree after commit');
    Check(git.CountCommits = 1, 'commit count = 1');
    Check(git.CurrentBranch = 'main', 'branch is main');
  finally
    git.Free;
  end;

  // scratch repo left in the temp dir for inspection; OS cleans /tmp

  WriteLn;
  if failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
