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

unit gboxexclude;

{ Managed blocks in <git-dir>/info/exclude.

  GotBox keeps several independent sets of "do not commit this" rules there --
  the user's ignore globs, stray nested repos, files too large for GitHub -- and
  each is rewritten from scratch whenever it changes. They share one file, so
  each set lives between its own BEGIN/END marker lines and a rewrite touches
  only its own block: anything the user put in the file by hand, and every other
  managed block, is preserved.

  info/exclude rather than a committed .gitignore because these rules are
  per-machine: they come from this machine's configuration and from what is
  actually on this disk, and writing them into the synced tree would push one
  machine's local state onto all the others. Note that git applies ignore rules
  only to UNtracked paths, so a block never removes a file that is already
  committed. LCL-free. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxgitrunner;

const
  { The user's ignore globs (gboxconfigstore.IgnoreGlobs), mirrored into git so
    the patterns keep matching files out of commits, not just out of the
    watcher's change events. }
  IGNORE_BEGIN = '# >>> gotbox: ignored patterns (from Settings) >>>';
  IGNORE_END = '# <<< gotbox ignored <<<';

{ Path of AGit's <git-dir>/info/exclude, or '' if the git dir can't be resolved. }
function ExcludeFilePath(AGit: TGitRunner): string;

{ Append to AOut the lines currently inside the ABegin/AEnd block, verbatim and
  in order (markers excluded). Returns AOut's resulting count. }
function ReadExcludeSection(AGit: TGitRunner; const ABegin, AEnd: string;
  AOut: TStrings): Integer;

{ Replace the ABegin/AEnd block with ALines, leaving every other line in the
  file untouched. Removes the block entirely when ALines is empty. }
procedure WriteExcludeSection(AGit: TGitRunner; const ABegin, AEnd: string;
  ALines: TStrings);

{ Mirror AGlobs into the ignore block, translated to gitignore syntax. Patterns
  are matched by name at any depth, the same way the file watcher matches them. }
procedure WriteIgnoreGlobs(AGit: TGitRunner; AGlobs: TStrings);

implementation

uses
  gboxatomic;

function ExcludeFilePath(AGit: TGitRunner): string;
var
  gitDir: string;
begin
  Result := '';
  gitDir := Trim(AGit.GitQuiet(['rev-parse', '--absolute-git-dir']).StdOut);
  if gitDir = '' then Exit;
  Result := IncludeTrailingPathDelimiter(gitDir) + 'info' + PathDelim + 'exclude';
end;

function ReadExcludeSection(AGit: TGitRunner; const ABegin, AEnd: string;
  AOut: TStrings): Integer;
var
  exclPath: string;
  excl: TStringList;
  a, i: Integer;
begin
  Result := 0;
  if AOut = nil then Exit;
  Result := AOut.Count;
  exclPath := ExcludeFilePath(AGit);
  if (exclPath = '') or (not FileExists(exclPath)) then Exit;
  excl := TStringList.Create;
  try
    excl.LoadFromFile(exclPath);
    a := excl.IndexOf(ABegin);
    if a < 0 then Exit;
    for i := a + 1 to excl.Count - 1 do
    begin
      if excl[i] = AEnd then Break;
      AOut.Add(excl[i]);
    end;
  finally
    excl.Free;
  end;
  Result := AOut.Count;
end;

procedure WriteExcludeSection(AGit: TGitRunner; const ABegin, AEnd: string;
  ALines: TStrings);
var
  exclPath: string;
  excl: TStringList;
  a, b, i: Integer;
begin
  exclPath := ExcludeFilePath(AGit);
  if exclPath = '' then Exit;
  excl := TStringList.Create;
  try
    if FileExists(exclPath) then excl.LoadFromFile(exclPath);
    // drop any previous copy of THIS block (others stay where they are)
    a := excl.IndexOf(ABegin);
    if a >= 0 then
    begin
      b := excl.IndexOf(AEnd);
      if b < a then b := excl.Count - 1;
      for i := b downto a do excl.Delete(i);
    end;
    if (ALines <> nil) and (ALines.Count > 0) then
    begin
      excl.Add(ABegin);
      for i := 0 to ALines.Count - 1 do excl.Add(ALines[i]);
      excl.Add(AEnd);
    end;
    // atomically: git reads this file while a cycle rewrites it, and a reader
    // that catches it truncated sees no rules at all
    AtomicSaveLines(excl, exclPath);
  finally
    excl.Free;
  end;
end;

{ A glob straight from the config is already gitignore's own syntax (`*` and `?`
  matching within one path component), with two characters that mean something
  else at the start of a line: '#' opens a comment and '!' negates. Escape those
  so a pattern like `#*#` (emacs autosave files) is read as a pattern. }
function AsIgnorePattern(const AGlob: string): string;
begin
  Result := Trim(AGlob);
  if Result = '' then Exit;
  if (Result[1] = '#') or (Result[1] = '!') then
    Result := '\' + Result;
end;

procedure WriteIgnoreGlobs(AGit: TGitRunner; AGlobs: TStrings);
var
  lines, cur: TStringList;
  i: Integer;
  pat: string;
begin
  lines := TStringList.Create;
  try
    if Assigned(AGlobs) then
      for i := 0 to AGlobs.Count - 1 do
      begin
        pat := AsIgnorePattern(AGlobs[i]);
        // '.git' is in the glob list for the watcher's benefit; git never tracks
        // a .git directory anyway, so writing it here would only be noise
        if (pat = '') or (pat = '.git') then Continue;
        if lines.IndexOf(pat) < 0 then lines.Add(pat);
      end;
    // this runs every cycle: skip the write when the block already says exactly
    // this, so a steady state costs one small read and no disk churn
    cur := TStringList.Create;
    try
      ReadExcludeSection(AGit, IGNORE_BEGIN, IGNORE_END, cur);
      if cur.Equals(lines) then Exit;
    finally
      cur.Free;
    end;
    WriteExcludeSection(AGit, IGNORE_BEGIN, IGNORE_END, lines);
  finally
    lines.Free;
  end;
end;

end.
