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

program testtags;

{ Named tags + squash-between-tags (gboxhistory), against a local bare remote.
  Builds a linear history with two tagged checkpoints and commits before/between/
  after them, then verifies: tags list + push, auto-trim disabled once tags
  exist, and that a squash collapses the inter-tag noise while preserving each
  tag's exact tree, the tag labels, and the commits after the newest tag. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, gboxgitrunner, gboxhistory;

var
  failures: Integer = 0;
  failedNames: string = '';

  procedure Check(ACond: Boolean; const AName: string);
  begin
    if ACond then WriteLn('  ok   - ', AName)
    else
    begin
      WriteLn('  FAIL - ', AName);
      Inc(failures);
      failedNames := failedNames + '    - ' + AName + LineEnding;
    end;
  end;

  procedure WriteFile(const APath, AContent: string);
  var
    f: TStringList;
  begin
    f := TStringList.Create;
    try
      f.Text := AContent;
      f.SaveToFile(APath);
    finally
      f.Free;
    end;
  end;

var
  base, bare, work, detail: string;
  git: TGitRunner;
  n1, n2: Integer;
  tV1, tV2, tHEAD: string;
  tags: TTagInfoArray;
  sqOk: Boolean;

  procedure Commit(const AName: string);
  begin
    WriteFile(IncludeTrailingPathDelimiter(work) + AName + '.txt', AName + '-data');
    git.Git(['add', '-A']);
    git.Git(['commit', '-m', AName]);
  end;

  function TreeOf(const ARef: string): string;
  begin
    Result := Trim(git.Git(['rev-parse', ARef + '^{tree}']).StdOut);
  end;

  function TagExists(const ALabel: string): Boolean;
  begin
    Result := git.GitQuiet(['rev-parse', '--verify', '--quiet',
      'refs/tags/' + ALabel]).Ok;
  end;

  function RemoteHasTag(const ALabel: string): Boolean;
  begin
    Result := Pos('refs/tags/' + ALabel,
      git.GitQuiet(['ls-remote', '--tags', 'origin']).StdOut) > 0;
  end;

begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-tags-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  bare := IncludeTrailingPathDelimiter(base) + 'remote.git';
  work := IncludeTrailingPathDelimiter(base) + 'W';
  ForceDirectories(bare);
  WriteLn('workspace: ', base);

  with TGitRunner.Create(bare) do
    try Git(['init', '--bare', '-b', 'main']); finally Free; end;
  with TGitRunner.Create('') do
    try Clone(bare, work); finally Free; end;

  git := TGitRunner.Create(work);
  try
    git.Git(['config', 'user.name', 'tagtest']);
    git.Git(['config', 'user.email', 't@t']);

    Commit('c0');
    git.Git(['push', 'origin', 'main']);   // establish origin/main
    Commit('c1');
    Commit('c2');
    Check(AddTag(git, 'v1', 'first checkpoint', detail),
      'add tag v1 (' + detail + ')');
    Commit('c3');
    Commit('c4');
    Check(AddTag(git, 'v2', 'second checkpoint', detail),
      'add tag v2 (' + detail + ')');
    Commit('c5');

    tags := ListTags(git);
    Check(Length(tags) = 2, 'ListTags returns 2 tags');
    Check(TagExists('v1') and TagExists('v2'), 'v1 and v2 exist locally');
    Check(RemoteHasTag('v1') and RemoteHasTag('v2'), 'v1 and v2 pushed to remote');

    // duplicate / invalid labels are rejected
    Check(not AddTag(git, 'v1', 'dup', detail), 'duplicate tag rejected');
    Check(not AddTag(git, 'bad name', 'x', detail), 'invalid tag name rejected');

    // auto-trim must be OFF once the repo has tags
    Check(HasUserTags(git), 'HasUserTags true');
    Check(not ShouldTrim(git, 2), 'ShouldTrim False when tags exist (auto-trim off)');

    // snapshot the trees + count before squashing
    tV1 := TreeOf('v1');
    tV2 := TreeOf('v2');
    tHEAD := TreeOf('HEAD');
    n1 := git.CountCommits;   // c0..c5 = 6

    sqOk := SquashBetweenTags(git, detail);   // capture before building the message
    Check(sqOk, 'squash between tags (' + detail + ')');

    n2 := git.CountCommits;
    Check(n2 < n1, Format('commit count reduced (%d -> %d)', [n1, n2]));
    Check(n2 = 3, 'squashed to 3 commits (v1-snapshot, v2, post-v2)');
    Check(TreeOf('v1') = tV1, 'v1 tree preserved');
    Check(TreeOf('v2') = tV2, 'v2 tree preserved');
    Check(TreeOf('HEAD') = tHEAD, 'HEAD tree preserved (content intact)');
    Check(TagExists('v1') and TagExists('v2'), 'both tags survive the squash');
    Check(Trim(git.Git(['rev-list', '--count', 'v2..HEAD']).StdOut) = '1',
      'the one commit after the newest tag is retained');
    Check(RemoteHasTag('v1') and RemoteHasTag('v2'),
      'squashed tags force-pushed to remote');
  finally
    git.Free;
  end;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
  begin
    WriteLn(failures, ' TEST(S) FAILED:');
    Write(failedNames);   // named, so a truncated CI tail still shows which
  end;
  Halt(failures);
end.
