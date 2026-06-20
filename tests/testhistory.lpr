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

var
  base, bareRepo, aDir, bDir, detail: string;
  git: TGitRunner;
  conflicts: TStringList;
  outcome: TSyncOutcome;
  i: Integer;
  f: TStringList;
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
  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
