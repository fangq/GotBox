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

program testhistory;

{ Tests milestone 7 against local repos (no network/token):
    - TrimHistory squashes A's history to the last ACap commits (+snapshot) and
      force-pushes; local and remote commit counts shrink, latest content kept.
    - A clone B that still has the old history detects the rewrite on its next
      sync and resets to the rewritten remote (no data loss of remote state). }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  gboxlog,
  gboxgitrunner,
  gboxsync,
  gboxhistory;

const
  CAP = 5;
  NCOMMITS = 14;

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

  function CommitCount(const ADir, ARef: string): Integer;
  var
    git: TGitRunner;
    r: TGitResult;
  begin
    git := TGitRunner.Create(ADir);
    try
      r := git.Git(['rev-list', '--count', ARef]);
      if r.Ok then Result := StrToIntDef(Trim(r.StdOut), -1)
      else
        Result := -1;
    finally
      git.Free;
    end;
  end;

  function HeadContent(const ADir: string): string;
  var
    f: TStringList;
  begin
    f := TStringList.Create;
    try
      f.LoadFromFile(IncludeTrailingPathDelimiter(ADir) + 'data.txt');
      Result := f.Text;
    finally
      f.Free;
    end;
  end;

  procedure WriteData(const ADir, AText: string);
  var
    f: TStringList;
  begin
    f := TStringList.Create;
    try
      f.Text := AText;
      f.SaveToFile(IncludeTrailingPathDelimiter(ADir) + 'data.txt');
    finally
      f.Free;
    end;
  end;

var
  base, bareRepo, aDir, bDir, detail: string;
  git: TGitRunner;
  conflicts: TStringList;
  outcome: TSyncOutcome;
  i: Integer;
  f: TStringList;
  mBare, mDir: string;
begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-hist-' +
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
  with TGitRunner.Create('') do
  try
    Clone(bareRepo, aDir);
  finally
    Free;
  end;
  SetIdentity(aDir, 'alice');

  // create NCOMMITS commits in A
  git := TGitRunner.Create(aDir);
  try
    for i := 1 to NCOMMITS do
    begin
      f := TStringList.Create;
      try
        f.Add('version ' + IntToStr(i));
        f.SaveToFile(IncludeTrailingPathDelimiter(aDir) + 'data.txt');
      finally
        f.Free;
      end;
      git.AddAll;
      git.CommitAll('commit ' + IntToStr(i));
    end;
  finally
    git.Free;
  end;

  // push everything
  conflicts := TStringList.Create;
  git := TGitRunner.Create(aDir);
  try
    outcome := RunSyncCycle(git, 'alice', detail, conflicts);
    Check(outcome = soPushed, 'A pushed full history (' +
      SyncOutcomeText(outcome) + ')');
  finally
    git.Free;
  end;
  Check(CommitCount(aDir, 'HEAD') = NCOMMITS, 'A has ' + IntToStr(NCOMMITS) +
    ' commits');

  // clone B with the full history BEFORE trimming
  with TGitRunner.Create('') do
  try
    Clone(bareRepo, bDir);
  finally
    Free;
  end;
  SetIdentity(bDir, 'bob');
  Check(CommitCount(bDir, 'HEAD') = NCOMMITS, 'B cloned full history');

  // trim A down to the last CAP commits (+ snapshot) and force-push
  git := TGitRunner.Create(aDir);
  try
    Check(TrimHistory(git, CAP, detail), 'TrimHistory ran (' + detail + ')');
  finally
    git.Free;
  end;
  Check(CommitCount(aDir, 'HEAD') = CAP + 1, 'A trimmed to CAP+1 commits');
  Check(CommitCount(bareRepo, 'main') = CAP + 1, 'remote trimmed to CAP+1 commits');
  Check(Pos('version ' + IntToStr(NCOMMITS), HeadContent(aDir)) > 0,
    'A still has latest content after trim');

  // B syncs: must detect the rewritten remote and reset to it
  conflicts.Clear;
  git := TGitRunner.Create(bDir);
  try
    outcome := RunSyncCycle(git, 'bob', detail, conflicts);
  finally
    git.Free;
  end;
  Check(outcome = soReset, 'B reset to rewritten remote (' +
    SyncOutcomeText(outcome) + ')');
  Check(CommitCount(bDir, 'HEAD') = CAP + 1, 'B history matches trimmed remote');
  Check(Pos('version ' + IntToStr(NCOMMITS), HeadContent(bDir)) > 0,
    'B still has latest content after reset');

  conflicts.Free;

  // --- regression: a MERGE commit inside the trim window ---------------------
  // GotBox creates merge commits during conflict handling. The old rebase-based
  // trim flattened them and hit unresolvable conflicts (looping forever); the
  // tree-copy rebuild must sail through and keep the exact merged content.
  mBare := IncludeTrailingPathDelimiter(base) + 'mremote.git';
  mDir := IncludeTrailingPathDelimiter(base) + 'M';
  ForceDirectories(mBare);
  with TGitRunner.Create(mBare) do
    try Git(['init', '--bare', '-b', 'main']); finally Free; end;
  with TGitRunner.Create('') do
    try Clone(mBare, mDir); finally Free; end;
  SetIdentity(mDir, 'mia');

  git := TGitRunner.Create(mDir);
  try
    WriteData(mDir, 'c1');
    git.AddAll; git.CommitAll('c1');
    git.Git(['push', 'origin', 'main']);           // establish origin/main
    WriteData(mDir, 'base-content');
    git.AddAll; git.CommitAll('c2');
    // diverge: feature edits data.txt, main edits it differently -> merge conflict
    git.Git(['checkout', '-b', 'feature']);
    WriteData(mDir, 'feature-side');
    git.AddAll; git.CommitAll('feature edit');
    git.Git(['checkout', 'main']);
    WriteData(mDir, 'main-side');
    git.AddAll; git.CommitAll('main edit');
    git.Git(['merge', 'feature']);                  // conflicts (expected)
    WriteData(mDir, 'merged-result');               // resolve
    git.AddAll;
    git.Git(['commit', '--no-edit']);               // the merge commit
    WriteData(mDir, 'after-merge-1');
    git.AddAll; git.CommitAll('c5');
    WriteData(mDir, 'after-merge-2');
    git.AddAll; git.CommitAll('c6');
    git.Git(['push', 'origin', 'main']);            // remote level with HEAD

    // the trim window (last CAP=5) now spans the merge commit
    Check(TrimHistory(git, CAP, detail), 'TrimHistory over a merge commit (' +
      detail + ')');
    Check(CommitCount(mDir, 'HEAD') = CAP + 1,
      'merged history trimmed to CAP+1 commits');
    Check(Pos('after-merge-2', HeadContent(mDir)) > 0,
      'latest content preserved across merge-window trim');
  finally
    git.Free;
  end;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
