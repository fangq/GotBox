unit gboxconflict;

{ Keep-both conflict resolution. After a merge leaves conflicted paths, for each
  one we preserve the incoming (remote / "theirs") version at the real path and
  write the local ("ours") version alongside as
  "<name> (conflict <machine> <timestamp>)<.ext>", then stage both. The caller
  finalizes the merge commit. This never loses data -- the user reconciles the
  extra file by hand. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxgitrunner;

{ Builds the keep-both copy name for a conflicted relative path. }
function ConflictCopyName(const ARelPath, AMachine: string): string;

{ Resolves all currently-unmerged paths in AGit's working tree keep-both style.
  Appends the created copy paths to AConflicts (if provided). Returns the number
  of conflicts handled. }
function ResolveKeepBoth(AGit: TGitRunner; const AMachine: string;
  AConflicts: TStrings): Integer;

implementation

procedure SaveRaw(const APath, AContent: string);
var
  fs: TFileStream;
begin
  ForceDirectories(ExtractFilePath(APath));
  fs := TFileStream.Create(APath, fmCreate);
  try
    if AContent <> '' then
      fs.WriteBuffer(AContent[1], Length(AContent));
  finally
    fs.Free;
  end;
end;

function ConflictCopyName(const ARelPath, AMachine: string): string;
var
  dir, name, ext, base, ts: string;
begin
  ts := FormatDateTime('yyyymmdd-hhnnss', Now);
  dir := ExtractFilePath(ARelPath);   // '' or 'sub/' (forward slashes from git)
  name := ExtractFileName(ARelPath);
  ext := ExtractFileExt(name);
  base := Copy(name, 1, Length(name) - Length(ext));
  Result := dir + base + ' (conflict ' + AMachine + ' ' + ts + ')' + ext;
end;

function ResolveKeepBoth(AGit: TGitRunner; const AMachine: string;
  AConflicts: TStrings): Integer;
var
  u: TGitResult;
  lines: TStringList;
  i: Integer;
  rel, oursContent, copyRel, absCopy: string;
begin
  Result := 0;
  // unmerged paths (git reports them with forward slashes)
  u := AGit.Git(['diff', '--name-only', '--diff-filter=U']);
  if not u.Ok then Exit;

  lines := TStringList.Create;
  try
    lines.Text := u.StdOut;
    for i := 0 to lines.Count - 1 do
    begin
      rel := Trim(lines[i]);
      if rel = '' then Continue;

      // "ours" = stage 2 (the local version); save it as the keep-both copy
      oursContent := AGit.ShowStage(2, rel).StdOut;
      copyRel := ConflictCopyName(rel, AMachine);
      absCopy := IncludeTrailingPathDelimiter(AGit.WorkDir) +
        StringReplace(copyRel, '/', PathDelim, [rfReplaceAll]);
      SaveRaw(absCopy, oursContent);

      // put "theirs" (the remote version) at the real path, then stage both
      AGit.CheckoutTheirs(rel);
      AGit.AddPath(rel);
      AGit.AddPath(copyRel);

      if Assigned(AConflicts) then AConflicts.Add(copyRel);
      Inc(Result);
    end;
  finally
    lines.Free;
  end;
end;

end.
