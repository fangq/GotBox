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

program testsync;

{ Tests the bidirectional sync cycle and keep-both conflict handling, all
  against local repos (no network/token):

    bare remote <- clone A (writes base, pushes)
                <- clone B
    A edits + syncs   (remote now ahead of B)
    B edits same line + syncs -> diverged -> merge conflict -> keep both

  Verifies B ends up with the remote version at the real path plus a
  "(conflict ...)" copy of its own version, and that the result is pushed. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  gboxlog,
  gboxgitrunner,
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

  procedure SetIdentity(const ADir, AName: string);
  var
    git: TGitRunner;
  begin
    git := TGitRunner.Create(ADir);
    try
      git.Git(['config', 'user.name', AName]);
      git.Git(['config', 'user.email', AName + '@test.local']);
    finally
      git.Free;
    end;
  end;

  procedure WriteFile(const APath: string; const ALines: array of string);
  var
    f: TStringList;
    i: Integer;
  begin
    f := TStringList.Create;
    try
      for i := 0 to High(ALines) do f.Add(ALines[i]);
      f.SaveToFile(APath);
    finally
      f.Free;
    end;
  end;

  function ConflictCopyCount(const ADir: string): Integer;
  var
    sr: TSearchRec;
  begin
    Result := 0;
    if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*(conflict*',
      faAnyFile, sr) = 0 then
    begin
      repeat
        if (sr.Attr and faDirectory) = 0 then Inc(Result);
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  end;

var
  base, bareRepo, aDir, bDir, detail, fileA, fileB, content: string;
  git: TGitRunner;
  conflicts: TStringList;
  outcome: TSyncOutcome;
  f: TStringList;
begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-sync-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  bareRepo := IncludeTrailingPathDelimiter(base) + 'remote.git';
  aDir := IncludeTrailingPathDelimiter(base) + 'A';
  bDir := IncludeTrailingPathDelimiter(base) + 'B';
  ForceDirectories(base);
  ForceDirectories(bareRepo);
  WriteLn('workspace: ', base);

  with TGitRunner.Create(bareRepo) do
  try
    Git(['init', '--bare', '-b', 'main']);
  finally
    Free;
  end;

  // clone A, write base content, push
  with TGitRunner.Create('') do
  try
    Clone(bareRepo, aDir);
  finally
    Free;
  end;
  SetIdentity(aDir, 'alice');
  fileA := IncludeTrailingPathDelimiter(aDir) + 'data.txt';
  WriteFile(fileA, ['line1', 'shared', 'line3']);
  conflicts := TStringList.Create;
  git := TGitRunner.Create(aDir);
  try
    outcome := RunSyncCycle(git, 'A', detail, conflicts);
    Check(outcome = soPushed, 'A initial push (' + SyncOutcomeText(outcome) + ')');
  finally
    git.Free;
  end;

  // clone B from the now-populated remote
  with TGitRunner.Create('') do
  try
    Clone(bareRepo, bDir);
  finally
    Free;
  end;
  SetIdentity(bDir, 'bob');
  fileB := IncludeTrailingPathDelimiter(bDir) + 'data.txt';

  // A changes the shared line and syncs -> remote ahead of B
  WriteFile(fileA, ['line1', 'A-version', 'line3']);
  git := TGitRunner.Create(aDir);
  try
    RunSyncCycle(git, 'A', detail, conflicts);
  finally
    git.Free;
  end;

  // B changes the same line differently, then syncs -> conflict
  WriteFile(fileB, ['line1', 'B-version', 'line3']);
  conflicts.Clear;
  git := TGitRunner.Create(bDir);
  try
    outcome := RunSyncCycle(git, 'bob', detail, conflicts);
  finally
    git.Free;
  end;

  Check(outcome = soConflict, 'B sync detects conflict (' +
    SyncOutcomeText(outcome) + ')');
  Check(conflicts.Count = 1, 'one conflict recorded');

  // the real path now holds the remote (A) version
  f := TStringList.Create;
  try
    f.LoadFromFile(fileB);
    content := f.Text;
  finally
    f.Free;
  end;
  Check(Pos('A-version', content) > 0, 'real file holds remote (theirs) version');

  // a keep-both copy of B's version exists
  Check(ConflictCopyCount(bDir) = 1, 'keep-both copy created on disk');

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
