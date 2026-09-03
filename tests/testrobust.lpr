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

program testrobust;

{ Robustness-hardening regression tests:

  A2 - SweepStaleIndexLock removes an old .git/index.lock (so a repo left wedged
       by a killed op recovers) but leaves a fresh lock alone.
  A3 - a keep-both conflict copy of a BINARY file (embedded NUL bytes) is written
       byte-for-byte identical to the local version -- the old string-based copy
       truncated at the first NUL. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  gboxlog,
  gboxgitrunner,
  gboxlfs,
  gboxexclude,
  gboxconfigstore,
  gboxrepoworker,
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

  procedure WriteBinary(const APath: string; const ABytes: array of Byte);
  var
    fs: TFileStream;
  begin
    fs := TFileStream.Create(APath, fmCreate);
    try
      if Length(ABytes) > 0 then fs.WriteBuffer(ABytes[0], Length(ABytes));
    finally
      fs.Free;
    end;
  end;

  function ReadBytes(const APath: string): TBytes;
  var
    fs: TFileStream;
  begin
    SetLength(Result, 0);
    if not FileExists(APath) then Exit;
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Result, fs.Size);
      if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
    finally
      fs.Free;
    end;
  end;

  function BytesEqual(const A, B: TBytes): Boolean;
  var
    i: Integer;
  begin
    Result := Length(A) = Length(B);
    if not Result then Exit;
    for i := 0 to High(A) do
      if A[i] <> B[i] then Exit(False);
  end;

  { The keep-both copy in ADir (the single "*(conflict*" file), or ''. }
  function ConflictCopyPath(const ADir: string): string;
  var
    sr: TSearchRec;
  begin
    Result := '';
    if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*(conflict*',
      faAnyFile, sr) = 0 then
    begin
      repeat
        if (sr.Attr and faDirectory) = 0 then
          Result := IncludeTrailingPathDelimiter(ADir) + sr.Name;
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  end;

  { ---- A2: stale index.lock reclamation ---------------------------------- }
  procedure TestIndexLock(const ABase: string);
  var
    dir, lock: string;
    git: TGitRunner;
  begin
    dir := IncludeTrailingPathDelimiter(ABase) + 'lockrepo';
    ForceDirectories(dir);
    with TGitRunner.Create(dir) do
    try
      Git(['init', '-b', 'main']);
    finally
      Free;
    end;
    SetIdentity(dir, 'lock');
    lock := IncludeTrailingPathDelimiter(dir) + '.git' + PathDelim + 'index.lock';

    git := TGitRunner.Create(dir);
    try
      // a FRESH lock must be left alone (an op could still be starting up)
      WriteBinary(lock, [Ord('x')]);
      git.SweepStaleIndexLock;
      Check(FileExists(lock), 'A2: fresh index.lock is preserved');

      // an OLD lock (backdated 5 min) is stale -> reclaimed
      FileSetDate(lock, DateTimeToFileDate(Now - (5 / (24 * 60))));
      git.SweepStaleIndexLock;
      Check(not FileExists(lock), 'A2: stale index.lock is removed');

      // and with the lock gone a normal commit succeeds
      WriteBinary(IncludeTrailingPathDelimiter(dir) + 'f.txt', [Ord('h'), Ord('i')]);
      git.AddAll;
      Check(git.CommitAll('c1').Ok, 'A2: commit works after reclamation');
    finally
      git.Free;
    end;
  end;

  { ---- A3: binary-safe keep-both ----------------------------------------- }
  procedure TestBinaryKeepBoth(const ABase: string);
  var
    bare, aDir, bDir, rel, detail, copyPath: string;
    baseBytes, aBytes, bBytes: TBytes;
    conflicts: TStringList;
    git: TGitRunner;
    outcome: TSyncOutcome;
  begin
    rel := 'blob.bin';
    // three binary versions, each with an embedded NUL early on so a
    // string-capture copy would truncate them to a few bytes
    baseBytes := TBytes.Create(1, 0, 2, 3, 0, 4, 5, 6);
    aBytes := TBytes.Create(10, 0, 20, 30, 0, 40, 50, 60, 70, 80);
    bBytes := TBytes.Create(200, 0, 201, 0, 202, 203, 204, 205, 0, 206, 207);

    bare := IncludeTrailingPathDelimiter(ABase) + 'bin.git';
    aDir := IncludeTrailingPathDelimiter(ABase) + 'binA';
    bDir := IncludeTrailingPathDelimiter(ABase) + 'binB';
    ForceDirectories(bare);
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
    WriteBinary(IncludeTrailingPathDelimiter(aDir) + rel, baseBytes);
    conflicts := TStringList.Create;
    try
      git := TGitRunner.Create(aDir);
      try
        outcome := RunSyncCycle(git, 'A', detail, conflicts);
        Check(outcome = soPushed, 'A3: A pushes binary base (' +
          SyncOutcomeText(outcome) + ')');
      finally
        git.Free;
      end;

      with TGitRunner.Create('') do
      try
        Clone(bare, bDir);
      finally
        Free;
      end;
      SetIdentity(bDir, 'bob');

      // A changes the blob and syncs -> remote ahead of B
      WriteBinary(IncludeTrailingPathDelimiter(aDir) + rel, aBytes);
      git := TGitRunner.Create(aDir);
      try
        RunSyncCycle(git, 'A', detail, conflicts);
      finally
        git.Free;
      end;

      // B changes the same blob differently -> binary conflict -> keep both
      WriteBinary(IncludeTrailingPathDelimiter(bDir) + rel, bBytes);
      conflicts.Clear;
      git := TGitRunner.Create(bDir);
      try
        outcome := RunSyncCycle(git, 'bob', detail, conflicts);
      finally
        git.Free;
      end;
      Check(outcome = soConflict, 'A3: B detects binary conflict (' +
        SyncOutcomeText(outcome) + ')');

      // the real path now holds the remote (A) bytes, intact
      Check(BytesEqual(ReadBytes(IncludeTrailingPathDelimiter(bDir) + rel), aBytes),
        'A3: real file holds remote binary bytes intact');

      // the keep-both copy is B''s bytes, byte-for-byte (not NUL-truncated)
      copyPath := ConflictCopyPath(bDir);
      Check(copyPath <> '', 'A3: keep-both copy exists');
      Check(BytesEqual(ReadBytes(copyPath), bBytes),
        'A3: keep-both copy is byte-identical to local binary (' +
        IntToStr(Length(ReadBytes(copyPath))) + ' vs ' + IntToStr(Length(bBytes)) +
        ' bytes)');
    finally
      conflicts.Free;
    end;
  end;

  { ---- A4: a repo whose default branch is 'master', not 'main' ----------- }
  procedure TestNonMainBranch(const ABase: string);
  var
    bare, aDir, bDir, rel, detail: string;
    conflicts: TStringList;
    git: TGitRunner;
    outcome: TSyncOutcome;
    f: TStringList;
  begin
    rel := 'note.txt';
    bare := IncludeTrailingPathDelimiter(ABase) + 'master.git';
    aDir := IncludeTrailingPathDelimiter(ABase) + 'mA';
    bDir := IncludeTrailingPathDelimiter(ABase) + 'mB';
    ForceDirectories(bare);
    with TGitRunner.Create(bare) do
    try
      Git(['init', '--bare', '-b', 'master']);
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

    conflicts := TStringList.Create;
    try
      git := TGitRunner.Create(aDir);
      try
        // the checkout must actually be on 'master' (what the worker resolves)
        Check(git.CurrentBranch = 'master',
          'A4: clone of a master-default remote is on master (' +
          git.CurrentBranch + ')');
        f := TStringList.Create;
        try
          f.Add('hello');
          f.SaveToFile(IncludeTrailingPathDelimiter(aDir) + rel);
        finally
          f.Free;
        end;
        outcome := RunSyncCycle(git, 'A', detail, conflicts, 'master');
        Check(outcome = soPushed, 'A4: push on master branch (' +
          SyncOutcomeText(outcome) + ')');
      finally
        git.Free;
      end;

      // B clones, A updates + syncs, B pulls -- all on master
      with TGitRunner.Create('') do
      try
        Clone(bare, bDir);
      finally
        Free;
      end;
      SetIdentity(bDir, 'bob');
      f := TStringList.Create;
      try
        f.Add('hello');
        f.Add('from-A');
        f.SaveToFile(
          IncludeTrailingPathDelimiter(aDir) + rel);
      finally
        f.Free;
      end;
      git := TGitRunner.Create(aDir);
      try
        RunSyncCycle(git, 'A', detail, conflicts, 'master');
      finally
        git.Free;
      end;

      git := TGitRunner.Create(bDir);
      try
        outcome := RunSyncCycle(git, 'bob', detail, conflicts, 'master');
        Check(outcome = soPulled, 'A4: B pulls A''s update on master (' +
          SyncOutcomeText(outcome) + ')');
      finally
        git.Free;
      end;
      f := TStringList.Create;
      try
        f.LoadFromFile(IncludeTrailingPathDelimiter(bDir) + rel);
        Check(Pos('from-A', f.Text) > 0, 'A4: B received the update over master');
      finally
        f.Free;
      end;
    finally
      conflicts.Free;
    end;
  end;

  { ---- A1: an oversize file is excluded from the commit ------------------ }
  procedure TestOversizeGuard(const ABase: string);
  var
    dir, staged: string;
    git: TGitRunner;
    blocked: TStringList;
  begin
    dir := IncludeTrailingPathDelimiter(ABase) + 'bigrepo';
    ForceDirectories(dir);
    with TGitRunner.Create(dir) do
    try
      Git(['init', '-b', 'main']);
    finally
      Free;
    end;
    SetIdentity(dir, 'big');
    // "small" (< limit) and "big" (>= limit); use a 20-byte limit so the test
    // needn't write 100 MB -- the mechanism is identical
    WriteBinary(IncludeTrailingPathDelimiter(dir) + 'small.txt', [Ord('h'), Ord('i')]);
    WriteBinary(IncludeTrailingPathDelimiter(dir) + 'big.bin',
      [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]);

    git := TGitRunner.Create(dir);
    blocked := TStringList.Create;
    blocked.Sorted := True;
    blocked.Duplicates := dupIgnore;
    try
      Check(FindOversizeUnhandled(git, 20, blocked) = 1,
        'A1: exactly the oversize file is flagged');
      Check(blocked.IndexOf('big.bin') >= 0, 'A1: big.bin flagged');
      Check(blocked.IndexOf('small.txt') < 0, 'A1: small.txt not flagged');

      WriteExcludeBlock(git, blocked);
      git.AddAll;
      staged := git.GitQuiet(['ls-files', '--cached']).StdOut;
      Check(Pos('small.txt', staged) > 0, 'A1: small file is staged');
      Check(Pos('big.bin', staged) = 0, 'A1: oversize file is NOT staged');

      // The block must survive a re-scan. An excluded path no longer shows up in
      // `git status`, so a scan that only looked there would come back empty,
      // WriteExcludeBlock would drop the entry, and the next `git add -A` would
      // commit the doomed blob -- exactly the case that lets a >100 MB file into
      // history and makes every later push fail. Start from an empty set, as a
      // freshly restarted daemon does.
      blocked.Clear;
      Check(FindOversizeUnhandled(git, 20, blocked) = 1,
        'A1: re-scan still flags the already-excluded oversize file');
      Check(blocked.IndexOf('big.bin') >= 0, 'A1: big.bin still flagged');
      WriteExcludeBlock(git, blocked);
      git.AddAll;
      staged := git.GitQuiet(['ls-files', '--cached']).StdOut;
      Check(Pos('big.bin', staged) = 0, 'A1: oversize file still NOT staged');

      // ReadExcludeBlock reports what is blocked, across restarts
      blocked.Clear;
      Check(ReadExcludeBlock(git, blocked) = 1, 'A1: exclude block reads back');
      Check(blocked.IndexOf('big.bin') >= 0, 'A1: block lists big.bin');

      // a blocked file that shrank below the limit drops out of the set on the
      // next scan (and out of the exclude block with it)
      WriteBinary(IncludeTrailingPathDelimiter(dir) + 'big.bin', [1, 2, 3]);
      blocked.Clear;
      Check(FindOversizeUnhandled(git, 20, blocked) = 0,
        'A1: a shrunk file is no longer flagged');
      WriteExcludeBlock(git, blocked);
      git.AddAll;
      staged := git.GitQuiet(['ls-files', '--cached']).StdOut;
      Check(Pos('big.bin', staged) > 0, 'A1: the shrunk file stages again');

      // restore the oversize file for the final "block cleared" check
      git.GitQuiet(['rm', '--cached', '-q', 'big.bin']);
      WriteBinary(IncludeTrailingPathDelimiter(dir) + 'big.bin',
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]);
      blocked.Clear;
      Check(FindOversizeUnhandled(git, 20, blocked) = 1, 'A1: flagged again');
      WriteExcludeBlock(git, blocked);

      // A file git ALREADY TRACKS that grows past the limit is a different
      // problem: ignore rules never apply to a tracked path, so `add -A` stages
      // the oversize change however the exclude block is written, and committing
      // it would make every push fail. UnstageOversize is the backstop.
      WriteBinary(IncludeTrailingPathDelimiter(dir) + 'grown.txt', [Ord('s')]);
      git.AddAll;
      git.CommitAll('track grown.txt while it is small');
      WriteBinary(IncludeTrailingPathDelimiter(dir) + 'grown.txt',
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]);
      blocked.Add('grown.txt');
      WriteExcludeBlock(git, blocked);
      git.AddAll;
      Check(Pos('grown.txt', git.GitQuiet(['diff', '--cached', '--name-only']).StdOut) > 0,
        'A1: the exclude block does NOT hold back a tracked file (git ignores it)');

      blocked.Clear;
      Check(UnstageOversize(git, 20, blocked) = 1, 'A1: the grown file is unstaged');
      Check(blocked.IndexOf('grown.txt') >= 0, 'A1: and reported');
      Check(Pos('grown.txt', git.GitQuiet(['diff', '--cached', '--name-only']).StdOut) = 0, 'A1: the oversize change is no longer staged');
      // the point of unstaging rather than removing: the file is still in the
      // repo at its previous content, so it is not deleted from other machines
      Check(Trim(git.GitQuiet(['ls-files', '--', 'grown.txt']).StdOut) = 'grown.txt',
        'A1: the file is still tracked');
      Check(Trim(git.GitQuiet(['cat-file', '-s',
        Trim(git.GitQuiet(['rev-parse', 'HEAD:grown.txt']).StdOut)]).StdOut) = '1',
        'A1: at its small, last-committed version');
      Check(FileExists(IncludeTrailingPathDelimiter(dir) + 'grown.txt'),
        'A1: while the oversize version stays in the folder');
      // a small staged change is untouched by the backstop (add -A re-stages the
      // grown file every cycle, which is exactly why the backstop has to run on
      // every commit rather than once)
      WriteBinary(IncludeTrailingPathDelimiter(dir) + 'small.txt', [Ord('y')]);
      git.AddAll;
      blocked.Clear;
      UnstageOversize(git, 20, blocked);
      Check(blocked.IndexOf('small.txt') < 0, 'A1: a small staged change is left alone');
      Check(blocked.IndexOf('grown.txt') >= 0, 'A1: the grown file is caught again');
      Check(Pos('small.txt', git.GitQuiet(['diff', '--cached', '--name-only']).StdOut) > 0, 'A1: small.txt is still staged');
      git.GitQuiet(['reset', '-q', 'HEAD']);

      // once cleared (e.g. git-lfs now available), the block is removed and the
      // file stages normally again
      blocked.Clear;
      WriteExcludeBlock(git, blocked);
      git.AddAll;
      staged := git.GitQuiet(['ls-files', '--cached']).StdOut;
      Check(Pos('big.bin', staged) > 0,
        'A1: oversize file stages again after the block is cleared');
    finally
      blocked.Free;
      git.Free;
    end;
  end;

  { A5: the configured ignore globs must keep matching files out of COMMITS, not
    just out of the watcher's events -- otherwise `add -A` sweeps every editor
    backup and OS metadata file into the repo the moment anything else changes. }
  procedure TestIgnoreGlobs(const ABase: string);
  var
    dir, staged: string;
    git: TGitRunner;
    globs, oversize, excl: TStringList;

    procedure Touch(const ARel: string);
    begin
      ForceDirectories(ExtractFilePath(IncludeTrailingPathDelimiter(dir) + ARel));
      WriteBinary(IncludeTrailingPathDelimiter(dir) + ARel, [Ord('x')]);
    end;

  begin
    WriteLn('-- A5: ignore globs reach git, not just the watcher');
    dir := IncludeTrailingPathDelimiter(ABase) + 'ignore';
    ForceDirectories(dir);
    with TGitRunner.Create(dir) do
    try
      Git(['init', '-b', 'main']);
    finally
      Free;
    end;
    SetIdentity(dir, 'ig');

    Touch('notes.txt');            // real content, must sync
    Touch('notes.txt~');           // editor backup
    Touch('~$report.docx');        // MS Office lock file
    Touch('.~lock.report.odt#');   // LibreOffice lock file
    Touch('#autosave#');           // emacs auto-save ('#' also starts a comment)
    Touch('.DS_Store');            // macOS metadata
    Touch('deep/sub/Thumbs.db');   // OS metadata, at depth
    Touch('deep/sub/keep.md');     // real content, at depth
    Touch('download.part');        // half-finished download

    git := TGitRunner.Create(dir);
    globs := TStringList.Create;
    oversize := TStringList.Create;
    excl := TStringList.Create;
    try
      AddDefaultIgnoreGlobs(globs);
      Check(globs.IndexOf('~$*') >= 0, 'A5: defaults cover MS Office lock files');
      Check(globs.IndexOf('.DS_Store') >= 0, 'A5: defaults cover macOS metadata');

      // an unrelated managed block and a hand-written line must survive
      oversize.Add('handwritten.bin');
      WriteExcludeBlock(git, oversize);

      WriteIgnoreGlobs(git, globs);
      git.AddAll;
      staged := git.GitQuiet(['diff', '--cached', '--name-only']).StdOut;

      Check(Pos('notes.txt' + LineEnding, staged) > 0, 'A5: real content is staged');
      Check(Pos('deep/sub/keep.md', staged) > 0, 'A5: real content at depth is staged');
      Check(Pos('notes.txt~', staged) = 0, 'A5: editor backup is not staged');
      Check(Pos('~$report.docx', staged) = 0, 'A5: Office lock file is not staged');
      Check(Pos('.~lock.report.odt#', staged) = 0,
        'A5: LibreOffice lock file is not staged');
      Check(Pos('#autosave#', staged) = 0,
        'A5: emacs auto-save is not staged (leading # escaped, not a comment)');
      Check(Pos('.DS_Store', staged) = 0, 'A5: macOS metadata is not staged');
      Check(Pos('Thumbs.db', staged) = 0, 'A5: OS metadata at depth is not staged');
      Check(Pos('download.part', staged) = 0, 'A5: partial download is not staged');

      // writing one block must not disturb another
      oversize.Clear;
      ReadExcludeBlock(git, oversize);
      Check(oversize.IndexOf('handwritten.bin') >= 0,
        'A5: the oversize block survives an ignore-block rewrite');

      // dropping a pattern un-ignores its files again
      git.GitQuiet(['reset', '-q']);
      globs.Delete(globs.IndexOf('.DS_Store'));
      WriteIgnoreGlobs(git, globs);
      git.AddAll;
      staged := git.GitQuiet(['diff', '--cached', '--name-only']).StdOut;
      Check(Pos('.DS_Store', staged) > 0,
        'A5: a removed pattern stops ignoring its files');
      Check(Pos('notes.txt~', staged) = 0, 'A5: the other patterns still apply');

      // and clearing the list removes the block outright
      globs.Clear;
      WriteIgnoreGlobs(git, globs);
      excl.Clear;
      Check(ReadExcludeSection(git, IGNORE_BEGIN, IGNORE_END, excl) = 0,
        'A5: an empty glob list removes the block');
    finally
      excl.Free;
      oversize.Free;
      globs.Free;
      git.Free;
    end;
  end;

var
  base: string;
begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-robust-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  ForceDirectories(base);
  WriteLn('workspace: ', base);

  TestIndexLock(base);
  TestBinaryKeepBoth(base);
  TestNonMainBranch(base);
  TestOversizeGuard(base);

  TestIgnoreGlobs(base);

  // B1: exponential backoff escalates then caps
  Check(BackoffDelayMs(1, 15000, 300000) = 15000, 'B1: first backoff = base');
  Check(BackoffDelayMs(2, 15000, 300000) = 30000, 'B1: second backoff doubles');
  Check(BackoffDelayMs(3, 15000, 300000) = 60000, 'B1: third backoff doubles again');
  Check(BackoffDelayMs(2, 15000, 300000) > BackoffDelayMs(1, 15000, 300000),
    'B1: backoff grows with the streak');
  Check(BackoffDelayMs(99, 15000, 300000) = 300000, 'B1: backoff caps at the max');

  // B3: corruption-signature classifier
  Check(IsCorruptionError('error: object file .git/objects/ab/cd is empty'),
    'B3: empty object file flagged');
  Check(IsCorruptionError('fatal: loose object abcd (stored in ...) is corrupt'),
    'B3: corrupt loose object flagged');
  Check(IsCorruptionError('error: bad object HEAD'), 'B3: bad object flagged');
  Check(not IsCorruptionError('push failed: could not resolve host github.com'),
    'B3: a network error is NOT flagged as corruption');
  Check(not IsCorruptionError('merge failed: conflict in file.txt'),
    'B3: a merge conflict is NOT flagged as corruption');

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
