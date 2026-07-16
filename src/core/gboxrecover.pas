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

  Only meaningful for auto-synced repos; a "managed" repo (the user commits by
  hand) is left for manual recovery so we never discard their unpushed commits. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxgitrunner;

{ Rebuild AGit's (corrupt) working copy from origin, preserving uncommitted local
  edits as "(recovered ...)" copies. Returns True on a completed recovery, with
  the number of preserved files in ARecovered; False (with ADetail) if the repo
  was actually healthy, had no origin, or the remote was unreachable (retry
  later). AGit must carry the repo WorkDir and its auth (user/token). }
function RecloneCorruptRepo(AGit: TGitRunner; const ABranch, AMachine: string;
  out ADetail: string; out ARecovered: Integer): Boolean;

implementation

uses
  gboxlog, gboxsync, gboxlfs;

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

end.
