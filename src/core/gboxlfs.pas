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

unit gboxlfs;

{ Optional Git LFS integration. GitHub rejects a plain `git push` containing any
  file over 100 MB, which would break a repo's sync. To avoid that, files at or
  above a configurable size threshold are registered with Git LFS *before* they
  are first committed: the repo's LFS filters/hooks are installed and the path
  is added to .gitattributes, so the following `git add`/commit stores the file
  as a small LFS pointer (the bytes upload to the LFS store on push).

  Degrades to a no-op when git-lfs is not installed, so the rest of the engine
  keeps working (large files just fail to push, as before). LCL-free. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxgitrunner;

const
  { GitHub rejects a plain `git push` containing any file over this size; nothing
    GotBox can do transports such a file without Git LFS. }
  GITHUB_FILE_LIMIT = Int64(100) * 1024 * 1024;

{ True if the `git lfs` command works (git-lfs is installed and on PATH). }
function LfsAvailable(AGit: TGitRunner): Boolean;

{ Append to AOut (deduplicated, repo-relative) each new/modified working-tree
  file that is at/above AHardLimitBytes and NOT already LFS-tracked -- i.e. a
  file that would be rejected on push and that Git LFS is not going to absorb.
  Returns AOut's resulting count. Never removes entries (the caller keeps a
  persistent blocked set). }
function FindOversizeUnhandled(AGit: TGitRunner; AHardLimitBytes: Int64;
  AOut: TStrings): Integer;

{ Maintain a managed block in <git-dir>/info/exclude listing ABlocked (so a
  `git add -A` skips them and they are never committed as a doomed >100 MB blob).
  Removes the block when ABlocked is empty. Foreign lines are preserved. }
procedure WriteExcludeBlock(AGit: TGitRunner; ABlocked: TStrings);

{ For each new/modified file in AGit's working tree that is >= AThresholdBytes
  and not already LFS-tracked, install the repo's LFS filters (once) and register
  the path with `git lfs track`. No-op when git-lfs is unavailable or the
  threshold is <= 0. Returns the number of files newly tracked. }
function TrackLargeFiles(AGit: TGitRunner; AThresholdBytes: Int64): Integer;

{ Install the repo-local LFS filters/hooks and materialize any LFS content in a
  freshly cloned tree (so pointer files become the real files). No-op if git-lfs
  is unavailable. }
procedure LfsPostClone(AGit: TGitRunner);

implementation

uses
  gboxlog;

function LfsAvailable(AGit: TGitRunner): Boolean;
begin
  Result := AGit.GitQuiet(['lfs', 'version']).Ok;
end;

{ Size of the file at APath, or -1 if it is not a regular file. }
function FileSizeBytes(const APath: string): Int64;
var
  sr: TSearchRec;
begin
  Result := -1;
  if FindFirst(APath, faAnyFile, sr) = 0 then
  begin
    if (sr.Attr and faDirectory) = 0 then
      Result := sr.Size;
    SysUtils.FindClose(sr);
  end;
end;

{ Repo-relative path from a `git status --porcelain` line: drop the 2-char XY
  code + space, take the rename target after " -> ", and unquote a "quoted" path. }
function StatusPath(const ALine: string): string;
var
  p: Integer;
begin
  Result := '';
  if Length(ALine) < 4 then
    Exit;
  Result := Copy(ALine, 4, MaxInt);          // after "XY "
  p := Pos(' -> ', Result);
  if p > 0 then
    Result := Copy(Result, p + 4, MaxInt);   // rename target
  Result := Trim(Result);
  if (Length(Result) >= 2) and (Result[1] = '"') and
    (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

function IsLfsTracked(AGit: TGitRunner; const APath: string): Boolean;
var
  r: TGitResult;
begin
  r := AGit.GitQuiet(['check-attr', 'filter', '--', APath]);
  Result := r.Ok and (Pos('filter: lfs', r.StdOut) > 0);
end;

{ Install the repo-local LFS filters + pre-push hook once (cheap to re-check). }
procedure EnsureInstalled(AGit: TGitRunner);
begin
  if not AGit.GitQuiet(['config', '--local', '--get', 'filter.lfs.smudge']).Ok then
    AGit.Git(['lfs', 'install', '--local']);
end;

function TrackLargeFiles(AGit: TGitRunner; AThresholdBytes: Int64): Integer;
var
  st: TGitResult;
  lines: TStringList;
  i: Integer;
  rel, full: string;
  installed: Boolean;
begin
  Result := 0;
  if AThresholdBytes <= 0 then
    Exit;
  if not LfsAvailable(AGit) then
    Exit;

  // list each new/modified file individually (untracked dirs expanded)
  st := AGit.GitQuiet(['status', '--porcelain', '--untracked-files=all']);
  if not st.Ok then
    Exit;

  installed := False;
  lines := TStringList.Create;
  try
    lines.Text := st.StdOut;
    for i := 0 to lines.Count - 1 do
    begin
      if Trim(lines[i]) = '' then
        Continue;
      rel := StatusPath(lines[i]);
      if rel = '' then
        Continue;
      full := IncludeTrailingPathDelimiter(AGit.WorkDir) + rel;
      if FileSizeBytes(full) < AThresholdBytes then
        Continue;
      if IsLfsTracked(AGit, rel) then
        Continue;
      if not installed then
      begin
        EnsureInstalled(AGit);
        installed := True;
      end;
      // git lfs track writes the (escaped) path pattern to .gitattributes
      if AGit.Git(['lfs', 'track', rel]).Ok then
      begin
        Inc(Result);
        if Assigned(Log) then
          Log.Info('lfs', 'tracking large file with LFS: ' + rel);
      end;
    end;
  finally
    lines.Free;
  end;
end;

function FindOversizeUnhandled(AGit: TGitRunner; AHardLimitBytes: Int64;
  AOut: TStrings): Integer;
var
  st: TGitResult;
  lines: TStringList;
  i: Integer;
  rel, full: string;
begin
  Result := 0;
  if AOut = nil then Exit;
  st := AGit.GitQuiet(['status', '--porcelain', '--untracked-files=all']);
  if st.Ok then
  begin
    lines := TStringList.Create;
    try
      lines.Text := st.StdOut;
      for i := 0 to lines.Count - 1 do
      begin
        if Trim(lines[i]) = '' then Continue;
        rel := StatusPath(lines[i]);
        if rel = '' then Continue;
        full := IncludeTrailingPathDelimiter(AGit.WorkDir) + rel;
        if FileSizeBytes(full) < AHardLimitBytes then Continue;
        if IsLfsTracked(AGit, rel) then Continue;    // LFS will absorb it
        if AOut.IndexOf(rel) < 0 then AOut.Add(rel);
      end;
    finally
      lines.Free;
    end;
  end;
  Result := AOut.Count;
end;

const
  OVERSIZE_BEGIN = '# >>> gotbox: oversize files (need git-lfs, not synced) >>>';
  OVERSIZE_END = '# <<< gotbox oversize <<<';

procedure WriteExcludeBlock(AGit: TGitRunner; ABlocked: TStrings);
var
  gitDir, exclPath: string;
  excl: TStringList;
  a, b, i: Integer;
begin
  gitDir := Trim(AGit.GitQuiet(['rev-parse', '--absolute-git-dir']).StdOut);
  if gitDir = '' then Exit;
  exclPath := IncludeTrailingPathDelimiter(gitDir) + 'info' + PathDelim + 'exclude';
  excl := TStringList.Create;
  try
    if FileExists(exclPath) then excl.LoadFromFile(exclPath);
    // drop any previous managed block
    a := excl.IndexOf(OVERSIZE_BEGIN);
    if a >= 0 then
    begin
      b := excl.IndexOf(OVERSIZE_END);
      if b < a then b := excl.Count - 1;
      for i := b downto a do excl.Delete(i);
    end;
    // re-add it from the current blocked set (leading '/' anchors to repo root)
    if (ABlocked <> nil) and (ABlocked.Count > 0) then
    begin
      excl.Add(OVERSIZE_BEGIN);
      for i := 0 to ABlocked.Count - 1 do excl.Add('/' + ABlocked[i]);
      excl.Add(OVERSIZE_END);
    end;
    ForceDirectories(ExtractFilePath(exclPath));
    excl.SaveToFile(exclPath);
  finally
    excl.Free;
  end;
end;

procedure LfsPostClone(AGit: TGitRunner);
begin
  if not LfsAvailable(AGit) then
    Exit;
  AGit.Git(['lfs', 'install', '--local']);
  AGit.Git(['lfs', 'pull']);   // fetch + check out the real bytes for pointers
end;

end.
