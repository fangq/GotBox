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

unit gboxrecover;

{ Automated recovery from a corrupt local repository. When a repo's object store
  is damaged (a normal cycle keeps failing with corruption errors), the remote is
  the source of truth, so we rebuild the local repo from it -- without losing the
  user's uncommitted work:

    1. Confirm the corruption (git fsck) -- never touch a healthy repo.
    2. Clone origin fresh into a sibling temp dir (proves the remote is reachable
       and gives an intact object store). Abort if the clone fails (offline).
    3. Preserve local edits: any tracked file whose on-disk bytes differ from the
       freshly-cloned version is copied aside as "<name> (recovered <machine>
       <ts>)<.ext>" before we overwrite it. Locally-added (untracked) files are
       left in place -- they survive the reset and re-sync normally.
    4. Replace the corrupt .git with the fresh one IN PLACE (move the old aside,
       move the new in), then `reset --hard origin/<branch>` so tracked files
       match the remote again. Working-tree files and submodule subdirectories
       are otherwise untouched (reset does not recurse into submodules), so a
       healthy submodule checkout is preserved.
    5. Re-materialize any Git LFS content, then clean up.

  A second, unrelated recovery lives here because it is the same kind of job --
  an automated repair of a repo state a normal cycle can never work its way out
  of. When a file over GitHub's 100 MB limit has already been recorded in a local
  commit, every push of that commit is rejected by the pre-receive hook, forever;
  the size guard in gboxlfs only keeps *new* oversize files out of a commit and
  cannot undo one that is already in history. DropOversizeFromUnpushed rewrites
  the not-yet-pushed commits without the offending blobs (see its comment).

  Both are only meaningful for auto-synced repos; a "managed" repo (the user
  commits by hand) is left for manual recovery so we never discard or rewrite
  their unpushed commits. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxgitrunner, gboxlfs;

{ Rebuild AGit's (corrupt) working copy from origin, preserving uncommitted local
  edits as "(recovered ...)" copies. Returns True on a completed recovery, with
  the number of preserved files in ARecovered; False (with ADetail) if the repo
  was actually healthy, had no origin, or the remote was unreachable (retry
  later). AGit must carry the repo WorkDir and its auth (user/token). }
function RecloneCorruptRepo(AGit: TGitRunner; const ABranch, AMachine: string;
  out ADetail: string; out ARecovered: Integer): Boolean;

{ True if AText is a push rejected because a file exceeds GitHub's size limit
  (the GH001 pre-receive rejection), as opposed to any other push failure. }
function IsOversizeRejection(const AText: string): Boolean;

{ Rewrite AGit's not-yet-pushed commits so they no longer contain any blob at or
  over GITHUB_FILE_LIMIT, making the branch pushable again. The offending paths
  are appended to ADropped and added to the exclude block, so the next cycle
  neither re-commits them nor forgets them.

  Nothing is thrown away, and nothing is deleted from the user's other machines.
  A path the remote already has (a tracked file that grew past the limit) keeps
  its last-pushed version in the repo, so the rewrite publishes no deletion. A
  purely local addition is dropped from the index and excluded, and if it is no
  longer in the working tree -- committed and then deleted, so the object store
  held its only copy -- its bytes are written back into the folder as an
  untracked file for the user to move somewhere else or delete.

  Returns False, with ADetail, when it must not or cannot act -- a detached HEAD,
  a branch that has diverged from the remote, or no oversize blob actually found
  in the unpushed range -- leaving the caller's normal error handling to run.
  Only for auto-synced repos: it collapses the unpushed commits into one, which
  would discard a user's hand-written commit messages in a managed repo.

  AHardLimitBytes is the size that makes a blob unpushable; it only ever differs
  from GitHub's limit in tests. }
function DropOversizeFromUnpushed(AGit: TGitRunner; const ABranch, AMachine: string;
  ADropped: TStrings; out ADetail: string;
  AHardLimitBytes: Int64 = GITHUB_FILE_LIMIT): Boolean;

implementation

uses
  gboxlog, gboxsync;

{ Recursively delete a directory tree; best-effort (ignores files it can't
  remove, e.g. a locked/read-only pack on Windows -- a leftover dir is harmless). }
procedure DeleteTree(const APath: string);
var
  sr: TSearchRec;
  full: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(APath) + AllFilesMask,
    faAnyFile, sr) = 0 then
  begin
    try
      repeat
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        full := IncludeTrailingPathDelimiter(APath) + sr.Name;
        if ((sr.Attr and faDirectory) <> 0) and ((sr.Attr and faSymLink) = 0) then
          DeleteTree(full)
        else
        begin
          // git objects are read-only; Windows DeleteFile refuses those, which
          // would strand a .git.corrupt-* backup in the tree (and an auto-synced
          // repo would then commit it). Clear the attribute first (no-op on Unix).
          FileSetAttr(full, FileGetAttr(full) and not faReadOnly);
          DeleteFile(full);
        end;
      until FindNext(sr) <> 0;
    finally
      SysUtils.FindClose(sr);
    end;
  end;
  RemoveDir(APath);
end;

{ True if the two files exist and have identical bytes. }
function SameBytes(const A, B: string): Boolean;
var
  fa, fb: TFileStream;
  ba, bb: array[0..8191] of Byte;
  ra, rb: LongInt;
begin
  Result := False;
  if not (FileExists(A) and FileExists(B)) then Exit;
  fa := TFileStream.Create(A, fmOpenRead or fmShareDenyNone);
  try
    fb := TFileStream.Create(B, fmOpenRead or fmShareDenyNone);
    try
      if fa.Size <> fb.Size then Exit;
      repeat
        ra := fa.Read(ba, SizeOf(ba));
        rb := fb.Read(bb, SizeOf(bb));
        if ra <> rb then Exit;
        if (ra > 0) and not CompareMem(@ba, @bb, ra) then Exit;
      until ra <= 0;
      Result := True;
    finally
      fb.Free;
    end;
  finally
    fa.Free;
  end;
end;

procedure CopyFileRaw(const ASrc, ADst: string);
var
  fs, fd: TFileStream;
begin
  ForceDirectories(ExtractFilePath(ADst));
  fs := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    fd := TFileStream.Create(ADst, fmCreate);
    try
      fd.CopyFrom(fs, 0);
    finally
      fd.Free;
    end;
  finally
    fs.Free;
  end;
end;

{ "<dir>/<base> (recovered <machine> <ts>)<.ext>" for a repo-relative path. }
function RecoveredCopyName(const ARel, AMachine, ATs: string): string;
var
  dir, name, ext, base: string;
begin
  dir := ExtractFilePath(ARel);
  name := ExtractFileName(ARel);
  ext := ExtractFileExt(name);
  base := Copy(name, 1, Length(name) - Length(ext));
  Result := dir + base + ' (recovered ' + AMachine + ' ' + ATs + ')' + ext;
end;

{ Walk AOldRoot/ARel; for each file that also exists in the fresh clone but
  differs, copy the old (edited) version aside as a recovered copy so the coming
  reset --hard can't discard the user's uncommitted edit. Skips .git and the
  recovered copies themselves. }
procedure PreserveEdits(const AOldRoot, ACloneRoot, ARel, AMachine, ATs: string;
  var ACount: Integer);
var
  sr: TSearchRec;
  rel, oldF, cloneF, dst: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(AOldRoot + ARel) +
    AllFilesMask, faAnyFile, sr) <> 0 then Exit;
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      if SameText(sr.Name, '.git') then Continue;
      if Pos('(recovered ', sr.Name) > 0 then Continue;   // don't recurse our own
      if ARel = '' then rel := sr.Name
      else
        rel := ARel + sr.Name;
      if (sr.Attr and faDirectory) <> 0 then
      begin
        if (sr.Attr and faSymLink) = 0 then
          PreserveEdits(AOldRoot, ACloneRoot, IncludeTrailingPathDelimiter(rel),
            AMachine, ATs, ACount);
        Continue;
      end;
      oldF := AOldRoot + rel;
      cloneF := ACloneRoot + rel;
      // only a tracked file present in BOTH but differing is a local edit the
      // reset would clobber; a purely-local file (absent from the clone) is left
      // untouched and re-syncs on its own.
      if FileExists(cloneF) and not SameBytes(oldF, cloneF) then
      begin
        dst := AOldRoot + RecoveredCopyName(rel, AMachine, ATs);
        try
          CopyFileRaw(oldF, dst);
          Inc(ACount);
        except
          // a single un-copyable file must not abort the whole recovery
        end;
      end;
    until FindNext(sr) <> 0;
  finally
    SysUtils.FindClose(sr);
  end;
end;

function RecloneCorruptRepo(AGit: TGitRunner; const ABranch, AMachine: string;
  out ADetail: string; out ARecovered: Integer): Boolean;
var
  root, url, tmp, ts, combined, oldGit, bakGit, newGit: string;
  fr, cl: TGitResult;
  cloner: TGitRunner;
begin
  Result := False;
  ADetail := '';
  ARecovered := 0;
  root := ExcludeTrailingPathDelimiter(AGit.WorkDir);
  if (root = '') or not DirectoryExists(root) then
  begin
    ADetail := 'no working directory';
    Exit;
  end;

  // 1. confirm real corruption -- never rebuild a healthy repo. A timeout is
  //    inconclusive, so defer rather than destroy.
  fr := AGit.Git(['fsck', '--no-progress']);
  combined := LowerCase(fr.StdOut + ' ' + fr.StdErr);
  if Pos('timed out', combined) > 0 then
  begin
    ADetail := 'fsck timed out; deferring recovery';
    Exit;
  end;
  if fr.Ok and not IsCorruptionError(combined) then
  begin
    ADetail := 'repository is healthy; no recovery needed';
    Exit;
  end;

  // 2. need an origin to rebuild from (a pure config read -- more robust on a
  //    damaged repo than `remote get-url`, which can trip on the broken HEAD)
  url := Trim(AGit.GitQuiet(['config', '--get', 'remote.origin.url']).StdOut);
  if url = '' then
    url := Trim(AGit.GitQuiet(['remote', 'get-url', 'origin']).StdOut);
  if url = '' then
  begin
    ADetail := 'no origin remote; cannot auto-recover (re-clone manually)';
    Exit;
  end;

  // 3. clone origin fresh into a sibling temp dir (same filesystem, so the .git
  //    swap below is a cheap rename); abort on failure (likely offline)
  Randomize;
  tmp := IncludeTrailingPathDelimiter(ExtractFileDir(root)) +
    '.gotbox-reclone-' + IntToHex(Random($7FFFFFFF), 8);
  cloner := TGitRunner.Create('');
  try
    cloner.AuthUser := AGit.AuthUser;
    cloner.AuthToken := AGit.AuthToken;
    cl := cloner.Clone(url, tmp);
  finally
    cloner.Free;
  end;
  if not cl.Ok then
  begin
    DeleteTree(tmp);
    ADetail := 'recovery clone failed (offline?): ' + Trim(cl.StdErr);
    Exit;
  end;

  ts := FormatDateTime('yyyymmdd-hhnnss', Now);
  try
    // 4. preserve locally-edited tracked files as "(recovered ...)" copies
    PreserveEdits(IncludeTrailingPathDelimiter(root),
      IncludeTrailingPathDelimiter(tmp), '', AMachine, ts, ARecovered);

    // 5. swap the object store in place: move the corrupt .git aside, move the
    //    fresh one in. Restore the old one if the second move fails, so we never
    //    leave the repo without a .git.
    oldGit := IncludeTrailingPathDelimiter(root) + '.git';
    bakGit := IncludeTrailingPathDelimiter(root) + '.git.corrupt-' + ts;
    newGit := IncludeTrailingPathDelimiter(tmp) + '.git';
    if not RenameFile(oldGit, bakGit) then
    begin
      DeleteTree(tmp);
      ADetail := 'could not move aside the corrupt .git';
      Exit;
    end;
    if not RenameFile(newGit, oldGit) then
    begin
      RenameFile(bakGit, oldGit);   // put the original back
      DeleteTree(tmp);
      ADetail := 'could not install the fresh .git';
      Exit;
    end;

    // 6. make the tracked files match the remote again (untracked files -- our
    //    recovered copies and any local additions -- survive), then materialize
    //    LFS content and clean up.
    AGit.ResetHard('origin/' + ABranch);
    LfsPostClone(AGit);
    DeleteTree(bakGit);
    DeleteTree(tmp);

    Result := True;
    ADetail := Format('rebuilt from origin; preserved %d edited file(s) as ' +
      '"(recovered ...)" copies', [ARecovered]);
    if Assigned(Log) then Log.Info('recover', root + ': ' + ADetail);
  except
    on E: Exception do
    begin
      DeleteTree(tmp);
      ADetail := 'recovery error: ' + E.Message;
      Result := False;
    end;
  end;
end;


{ ---------------------------------------------------------------------------
  Recovery 2: an oversize blob that already reached a local commit
  --------------------------------------------------------------------------- }

function IsOversizeRejection(const AText: string): Boolean;
var
  s: string;
begin
  s := LowerCase(AText);
  Result := (Pos('gh001', s) > 0) or (Pos('file size limit', s) > 0) or
    (Pos('exceeds github', s) > 0);
end;

{ Append to AOut every path in ACommit's tree whose blob is at/over
  GITHUB_FILE_LIMIT, and to ASrc the commit it was read from (kept index-parallel
  with AOut, so a file can later be restored from a commit that still has it).
  `ls-tree -r -l` prints "<mode> <type> <sha> <size>"#9"<path>"; a gitlink has
  '-' for the size and is skipped by the numeric parse. }
procedure CollectOversizeBlobs(AGit: TGitRunner; const ACommit: string;
  AHardLimitBytes: Int64; AOut, ASrc: TStrings);
var
  r: TGitResult;
  lines: TStringList;
  i, t, sp: Integer;
  meta, path: string;
begin
  // core.quotePath=false keeps non-ASCII paths readable instead of \NNN-escaped
  r := AGit.GitQuiet(['-c', 'core.quotePath=false', 'ls-tree', '-r',
    '-l', '--full-tree', ACommit]);
  if not r.Ok then Exit;
  lines := TStringList.Create;
  try
    lines.Text := r.StdOut;
    for i := 0 to lines.Count - 1 do
    begin
      t := Pos(#9, lines[i]);
      if t <= 0 then Continue;
      meta := Copy(lines[i], 1, t - 1);
      path := Copy(lines[i], t + 1, MaxInt);
      sp := LastDelimiter(' ', meta);
      if sp <= 0 then Continue;
      if StrToInt64Def(Trim(Copy(meta, sp + 1, MaxInt)), -1) < AHardLimitBytes then
        Continue;
      if (path = '') or (AOut.IndexOf(path) >= 0) then Continue;
      AOut.Add(path);
      ASrc.Add(ACommit);
    end;
  finally
    lines.Free;
  end;
end;

{ True if APath already exists at ABase (i.e. the remote has accepted it) with a
  blob that is itself oversize. That should be impossible -- GitHub would have
  rejected it -- but if it ever is, the blob is not ours to drop: removing it
  would delete published content rather than unblock the push. }
function PublishedOversize(AGit: TGitRunner; const ABase, APath: string;
  AHardLimitBytes: Int64): Boolean;
var
  sha: string;
begin
  Result := False;
  if ABase = '' then Exit;
  sha := Trim(AGit.GitQuiet(['rev-parse', '--verify', '-q', ABase +
    ':' + APath]).StdOut);
  if sha = '' then Exit;
  Result := StrToInt64Def(Trim(AGit.GitQuiet(['cat-file', '-s', sha]).StdOut), 0) >=
    AHardLimitBytes;
end;

{ Put ABase's version of APath back into the index -- index only, so the working
  tree keeps the user's oversize file. Used instead of dropping the path when the
  remote already has it: removing it would publish a deletion and wipe the file
  from the user's other machines on their next pull. False if ABase has no such
  path (it is a purely local addition, which the caller then unstages instead). }
function RestoreIndexFrom(AGit: TGitRunner; const ABase, APath: string): Boolean;
var
  r: TGitResult;
  ln, mode, sha: string;
  sp, t: Integer;
begin
  Result := False;
  if ABase = '' then Exit;
  r := AGit.GitQuiet(['-c', 'core.quotePath=false', 'ls-tree', ABase, '--', APath]);
  if not r.Ok then Exit;
  ln := Trim(r.StdOut);              // "<mode> blob <sha>"#9"<path>"
  t := Pos(#9, ln);
  if t <= 0 then Exit;
  ln := Copy(ln, 1, t - 1);
  sp := Pos(' ', ln);
  if sp <= 0 then Exit;
  mode := Copy(ln, 1, sp - 1);
  sp := LastDelimiter(' ', ln);
  sha := Trim(Copy(ln, sp + 1, MaxInt));
  if (mode = '') or (sha = '') then Exit;
  Result := AGit.GitQuiet(['update-index', '--add', '--cacheinfo',
    mode + ',' + sha + ',' + APath]).Ok;
end;

function DropOversizeFromUnpushed(AGit: TGitRunner; const ABranch, AMachine: string;
  ADropped: TStrings; out ADetail: string;
  AHardLimitBytes: Int64 = GITHUB_FILE_LIMIT): Boolean;
var
  base, head, newTree, newHead, full, ref: string;
  r: TGitResult;
  revs, paths, srcs, blocked: TStringList;
  i, restored, kept: Integer;
  msg, more: string;
begin
  Result := False;
  ADetail := '';
  if ADropped = nil then Exit;

  // Rewriting a detached HEAD would build a commit no branch points at, so the
  // push would be rejected all over again (the worker re-attaches HEAD itself).
  if not AGit.GitQuiet(['symbolic-ref', '-q', 'HEAD']).Ok then
  begin
    ADetail := 'detached HEAD -- not rewriting history';
    Exit;
  end;
  head := Trim(AGit.GitQuiet(['rev-parse', 'HEAD']).StdOut);
  if head = '' then
  begin
    ADetail := 'no commit on this branch yet';
    Exit;
  end;

  // '' when the branch has never been pushed: then every commit is ours to
  // rewrite and the replacement is a fresh root commit.
  base := Trim(AGit.GitQuiet(['rev-parse', '--verify', '-q', 'origin/' +
    ABranch]).StdOut);

  // Only ever rewrite commits that sit strictly on top of what the remote has.
  // A diverged branch is a different problem (and RunSyncCycle's merge/reset
  // path owns it); collapsing it here would silently drop remote history.
  if (base <> '') and (not AGit.GitQuiet(['merge-base', '--is-ancestor',
    base, 'HEAD']).Ok) then
  begin
    ADetail := 'local branch has diverged from the remote -- not rewriting history';
    Exit;
  end;

  revs := TStringList.Create;
  paths := TStringList.Create;
  srcs := TStringList.Create;
  blocked := TStringList.Create;
  try
    blocked.Sorted := True;
    blocked.Duplicates := dupIgnore;

    if base <> '' then
      r := AGit.GitQuiet(['rev-list', base + '..HEAD'])
    else
      r := AGit.GitQuiet(['rev-list', 'HEAD']);
    if not r.Ok then
    begin
      ADetail := 'cannot list the unpushed commits';
      Exit;
    end;
    revs.Text := r.StdOut;    // newest commit first

    // Find the offenders ourselves rather than trusting the wording of the
    // remote's message: GitHub names only the first file it trips over, and the
    // tree scan finds every one of them in a single pass.
    for i := 0 to revs.Count - 1 do
      if Trim(revs[i]) <> '' then
        CollectOversizeBlobs(AGit, Trim(revs[i]), AHardLimitBytes, paths, srcs);

    for i := paths.Count - 1 downto 0 do
      if PublishedOversize(AGit, base, paths[i], AHardLimitBytes) then
      begin
        paths.Delete(i);
        srcs.Delete(i);
      end;

    if paths.Count = 0 then
    begin
      ADetail := 'push was rejected for an oversize file, but none is present ' +
        'in the unpushed commits';
      Exit;
    end;

    // Take them out of the replacement commit, which is built from the index.
    // Which way depends on whether the remote already has the path:

    //  - it does (a tracked file that grew past the limit): put its last-pushed
    //    version back in the index. Removing it instead would publish a deletion
    //    and wipe the file from the user's other machines. It stays tracked, so
    //    it cannot be excluded -- git applies no ignore rule to a tracked path --
    //    and UnstageOversize is what keeps the oversize working-tree version out
    //    of every later commit. Nothing is lost either way: the repo still holds
    //    a version of the file, so we leave the working tree exactly as it is.

    //  - it does not (a purely local addition): the unpushed commits held the
    //    only copy of these bytes, so write them back into the folder first if
    //    the file is gone from it, then drop the path and exclude it.
    restored := 0;
    kept := 0;
    for i := 0 to paths.Count - 1 do
    begin
      if RestoreIndexFrom(AGit, base, paths[i]) then
      begin
        Inc(kept);
        Continue;
      end;
      full := IncludeTrailingPathDelimiter(AGit.WorkDir) + paths[i];
      if (not FileExists(full)) and
        AGit.Git(['checkout', srcs[i], '--', paths[i]]).Ok then
        Inc(restored);
      AGit.GitQuiet(['rm', '--cached', '-q', '--ignore-unmatch', '--', paths[i]]);
      blocked.Add(paths[i]);
    end;

    newTree := Trim(AGit.GitQuiet(['write-tree']).StdOut);
    if newTree = '' then
    begin
      ADetail := 'could not write the rewritten tree';
      Exit;
    end;

    // 3. Replace the unpushed commits with a single one carrying that tree.
    //    Building it with commit-tree + update-ref (rather than reset+commit)
    //    means the branch only ever moves once, and only from the exact commit
    //    we inspected -- update-ref's old-value argument makes it a no-op if
    //    anything else moved the branch underneath us.
    // same shape as gboxsync's auto-commit messages
    msg := Format('%s %s', [AMachine, FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)]);
    ref := 'refs/heads/' + ABranch;
    if (base <> '') and (newTree =
      Trim(AGit.GitQuiet(['rev-parse', base + '^{tree}']).StdOut)) then
      // the oversize file was all these commits ever added: nothing left to push
      newHead := base
    else
    begin
      if base <> '' then
        r := AGit.GitQuiet(['commit-tree', newTree, '-p', base, '-m', msg])
      else
        r := AGit.GitQuiet(['commit-tree', newTree, '-m', msg]);
      newHead := Trim(r.StdOut);
      if (not r.Ok) or (newHead = '') then
      begin
        ADetail := 'could not build the rewritten commit: ' + Trim(r.StdErr);
        Exit;
      end;
    end;
    r := AGit.Git(['update-ref', ref, newHead, head]);
    if not r.Ok then
    begin
      ADetail := 'could not move ' + ABranch + ' to the rewritten commit: ' +
        Trim(r.StdErr);
      Exit;
    end;

    // 4. Keep them out of the next commit, and tell the caller what we dropped.
    //    (The orphaned blobs stay in .git until a gc prunes them -- the engine's
    //    periodic gc does that on its own; nothing here depends on the space.)
    for i := 0 to paths.Count - 1 do
      if ADropped.IndexOf(paths[i]) < 0 then ADropped.Add(paths[i]);
    ReadExcludeBlock(AGit, blocked);
    WriteExcludeBlock(AGit, blocked);

    more := '';
    if paths.Count > 1 then more := Format(' +%d more', [paths.Count - 1]);
    ADetail := Format('took %d file(s) too large for GitHub out of the unpushed ' +
      'history (%s%s); %d kept in the repo at their last pushed version, ' +
      '%d written back to the folder', [paths.Count, paths[0],
      more, kept, restored]);
    if Assigned(Log) then Log.Info('recover', ADetail);
    Result := True;
  finally
    blocked.Free;
    srcs.Free;
    paths.Free;
    revs.Free;
  end;
end;

end.
