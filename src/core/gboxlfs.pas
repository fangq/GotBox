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

{ True if the `git lfs` command works (git-lfs is installed and on PATH). }
function LfsAvailable(AGit: TGitRunner): Boolean;

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

procedure LfsPostClone(AGit: TGitRunner);
begin
  if not LfsAvailable(AGit) then
    Exit;
  AGit.Git(['lfs', 'install', '--local']);
  AGit.Git(['lfs', 'pull']);   // fetch + check out the real bytes for pointers
end;

end.
