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

program testrecover;

{ Corrupt-repo auto-recovery (gboxrecover.RecloneCorruptRepo):

    bare remote <- clone A (commits data.txt, pushes)
    A: edit data.txt (uncommitted) + add added.txt (untracked)
    A: truncate every loose object -> object store corrupt
    RecloneCorruptRepo -> rebuild from origin

  Verifies: the repo is healthy again, tracked files match the clean remote, the
  uncommitted edit is preserved as a "(recovered ...)" copy, an untracked local
  addition survives, and a HEALTHY repo is left untouched. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  gboxlog,
  gboxgitrunner,
  gboxrecover,
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
  begin
    with TGitRunner.Create(ADir) do
    try
      Git(['config', 'user.name', AName]);
      Git(['config', 'user.email', AName + '@test.local']);
    finally
      Free;
    end;
  end;

  procedure WriteText(const APath, AText: string);
  var
    f: TStringList;
  begin
    f := TStringList.Create;
    try
      f.Text := AText;
      f.SaveToFile(APath);
    finally
      f.Free;
    end;
  end;

  function ReadText(const APath: string): string;
  var
    f: TStringList;
  begin
    Result := '';
    if not FileExists(APath) then Exit;
    f := TStringList.Create;
    try
      f.LoadFromFile(APath);
      Result := f.Text;
    finally
      f.Free;
    end;
  end;

  { Delete every loose object -> fsck fails (missing/corrupt object store). }
  procedure CorruptObjects(const ARepo: string);
  var
    objRoot, sub: string;
    d, f: TSearchRec;
  begin
    objRoot := IncludeTrailingPathDelimiter(ARepo) + '.git' + PathDelim + 'objects';
    if FindFirst(IncludeTrailingPathDelimiter(objRoot) + AllFilesMask,
      faDirectory, d) <> 0 then Exit;
    try
      repeat
        if (d.Name = '.') or (d.Name = '..') then Continue;
        if (d.Attr and faDirectory) = 0 then Continue;
        if (Length(d.Name) <> 2) then Continue;   // the fan-out dirs are 2 hex chars
        sub := IncludeTrailingPathDelimiter(objRoot) + d.Name;
        if FindFirst(IncludeTrailingPathDelimiter(sub) + AllFilesMask,
          faAnyFile, f) = 0 then
        begin
          try
            repeat
              if (f.Attr and faDirectory) <> 0 then Continue;
              // git makes objects read-only, but unlink only needs a writable
              // parent dir (which we own), so DeleteFile succeeds
              DeleteFile(IncludeTrailingPathDelimiter(sub) + f.Name);
            until FindNext(f) <> 0;
          finally
            FindClose(f);
          end;
        end;
      until FindNext(d) <> 0;
    finally
      FindClose(d);
    end;
  end;

  { The single "*(recovered*" copy in ADir, or ''. }
  function RecoveredCopyPath(const ADir: string): string;
  var
    sr: TSearchRec;
  begin
    Result := '';
    if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*(recovered*',
      faAnyFile, sr) = 0 then
    begin
      repeat
        if (sr.Attr and faDirectory) = 0 then
          Result := IncludeTrailingPathDelimiter(ADir) + sr.Name;
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  end;

var
  base, bare, aDir, detail: string;
  git: TGitRunner;
  conflicts: TStringList;
  recovered: Integer;
  ok: Boolean;
begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-recover-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  bare := IncludeTrailingPathDelimiter(base) + 'remote.git';
  aDir := IncludeTrailingPathDelimiter(base) + 'A';
  ForceDirectories(bare);
  WriteLn('workspace: ', base);

  with TGitRunner.Create(bare) do
  try
    Git(['init', '--bare', '-b', 'main']);
  finally
    Free;
  end;
  with TGitRunner.Create('') do
  try
    Clone(bare, aDir);
  finally
    Free;
  end;
  SetIdentity(aDir, 'alice');

  // commit + push the clean version
  WriteText(IncludeTrailingPathDelimiter(aDir) + 'data.txt', 'remote-content');
  conflicts := TStringList.Create;
  git := TGitRunner.Create(aDir);
  try
    Check(RunSyncCycle(git, 'A', detail, conflicts) = soPushed,
      'setup: pushed clean data.txt');

    // a healthy repo must be left untouched
    Check(not RecloneCorruptRepo(git, 'main', 'A', detail, recovered),
      'healthy repo is not recovered (' + detail + ')');
  finally
    git.Free;
  end;

  // now: an uncommitted edit + an untracked addition, then corrupt the objects
  WriteText(IncludeTrailingPathDelimiter(aDir) + 'data.txt', 'local-edit');
  WriteText(IncludeTrailingPathDelimiter(aDir) + 'added.txt', 'new-local-file');
  CorruptObjects(aDir);

  git := TGitRunner.Create(aDir);
  try
    // fsck should now see the damage
    Check(not git.Git(['fsck', '--no-progress']).Ok, 'objects are corrupt (fsck fails)');

    ok := RecloneCorruptRepo(git, 'main', 'A', detail, recovered);
    Check(ok, 'recovery reports success (' + detail + ')');
    Check(recovered = 1, 'exactly one edited file was preserved');

    // tracked file is back to the clean remote version
    Check(Trim(ReadText(IncludeTrailingPathDelimiter(aDir) + 'data.txt')) =
      'remote-content', 'tracked data.txt restored to remote content');
    // the uncommitted edit is kept as a (recovered ...) copy
    Check(Trim(ReadText(RecoveredCopyPath(aDir))) = 'local-edit',
      'uncommitted edit preserved in a (recovered ...) copy');
    // the untracked local addition survives
    Check(Trim(ReadText(IncludeTrailingPathDelimiter(aDir) + 'added.txt')) =
      'new-local-file', 'untracked local addition survives');
    // the repo is healthy again
    Check(git.Git(['fsck', '--no-progress']).Ok, 'repo is healthy after recovery');
    Check(git.Git(['rev-parse', 'HEAD']).Ok, 'HEAD resolves after recovery');
  finally
    git.Free;
    conflicts.Free;
  end;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
