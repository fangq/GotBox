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

unit gboxfilestatus;

{ Per-file sync status for the .gotbox tree, for file-manager icon overlays
  (TortoiseGit-style). LCL-free and widgetset-independent.

  A path is classified as synced / modified / conflict by parsing the owning
  repo's `git status --porcelain -z` (+ `git ls-files -z` for the clean/tracked
  set). Results are cached per repo with a short TTL so bursts coalesce, and
  folder states roll up (a folder shows the worst state among its descendants).
  An absolute filesystem path is mapped to its owning repo -- the .gotbox root
  or the deepest matching submodule -- reusing gboxsuper.ListSubmodules and the
  same RootDir + submodule-name -> path mapping the engine uses.

  Thread-safe: the sync worker refreshes/invalidates a repo's cache; the overlay
  IPC server reads it concurrently. This unit does no I/O beyond running git via
  TGitRunner, so a stuck git op is bounded by the runner's DefaultTimeoutMs. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, gboxgitrunner;

type
  { fsNone = outside a managed repo, ignored, or unknown -> no overlay. Ordered
    by "attention severity" (see StateSeverity) for folder roll-up. }
  TFileState = (fsNone, fsSynced, fsModified, fsConflict);

  { Cache of one repo working tree: relative-path -> state for every tracked or
    non-clean entry, plus folder roll-ups. Not used directly by callers; owned
    by TStatusCache. }
  TRepoStatusCache = class
  private
    FDir: string;              // repo working-tree directory (native separators)
    FMap: TStringList;         // key = repo-relative '/'-path; Objects = state+1
    FStamp: QWord;             // last refresh (GetTickCount64); 0 = never
    procedure PutMax(const ARel: string; AState: TFileState);
    procedure RollUp(const ARel: string; AState: TFileState);
  public
    constructor Create(const ADir: string);
    destructor Destroy; override;
    procedure Refresh;                       // re-run git and rebuild the map
    function LookupRel(const ARel: string): TFileState;
    property Stamp: QWord read FStamp write FStamp;
  end;

  TStatusCache = class
  private
    FRootDir: string;          // the .gotbox working tree (RootDir)
    FLock: TCriticalSection;
    FTtlMs: Integer;
    FRepos: TStringList;       // key = repo dir; Objects = TRepoStatusCache
    function RepoCacheFor(const ARepoDir: string): TRepoStatusCache;
    function OwningRepo(const AAbsPath: string; out ARelInRepo: string): string;
  public
    constructor Create(const ARootDir: string);
    destructor Destroy; override;
    { State of an absolute path (file OR folder). Refreshes the owning repo's
      cache if older than TtlMs. fsNone when outside the tree / unavailable. }
    function Lookup(const AAbsPath: string): TFileState;
    { Drop a repo's cache so the next Lookup recomputes it (call after a sync
      cycle or a watched change). ARepoDir = that repo's working tree; empty =
      all repos. }
    procedure Invalidate(const ARepoDir: string = '');
    property RootDir: string read FRootDir;
    property TtlMs: Integer read FTtlMs write FTtlMs;
  end;

{ Severity for folder roll-up and IPC ordering: none<synced<modified<conflict. }
function StateSeverity(AState: TFileState): Integer;

{ Normalize to a repo-relative, '/'-separated, no-leading/trailing-slash path. }
function NormRel(const APath: string): string;

implementation

uses
  gboxsuper;

function StateSeverity(AState: TFileState): Integer;
begin
  Result := Ord(AState);   // enum is declared in severity order
end;

function NormRel(const APath: string): string;
begin
  Result := StringReplace(APath, '\', '/', [rfReplaceAll]);
  while (Result <> '') and (Result[1] = '/') do
    Delete(Result, 1, 1);
  while (Result <> '') and (Result[Length(Result)] = '/') do
    Delete(Result, Length(Result), 1);
end;

{ Case-insensitive path matching on Windows/macOS, sensitive on Linux. }
function PathCaseSensitive: Boolean;
begin
  {$IF DEFINED(WINDOWS) OR DEFINED(DARWIN)}
  Result := False;
  {$ELSE}
  Result := True;
  {$ENDIF}
end;

function PathEq(const A, B: string): Boolean;
begin
  if PathCaseSensitive then Result := A = B
  else
    Result := SameText(A, B);
end;

{ True if APath equals APrefix or is a descendant of it (both NormRel'd). }
function IsPrefixPath(const APrefix, APath: string): Boolean;
begin
  if APrefix = '' then Exit(True);
  if PathEq(APath, APrefix) then Exit(True);
  Result := (Length(APath) > Length(APrefix)) and
    (APath[Length(APrefix) + 1] = '/') and
    PathEq(Copy(APath, 1, Length(APrefix)), APrefix);
end;

{ ---- TRepoStatusCache ---- }

constructor TRepoStatusCache.Create(const ADir: string);
begin
  inherited Create;
  FDir := ExcludeTrailingPathDelimiter(ADir);
  FMap := TStringList.Create;
  FMap.CaseSensitive := PathCaseSensitive;
  FMap.Sorted := True;
  FMap.Duplicates := dupIgnore;
  FStamp := 0;
end;

destructor TRepoStatusCache.Destroy;
begin
  FMap.Free;
  inherited Destroy;
end;

{ Store the max-severity state seen for ARel. }
procedure TRepoStatusCache.PutMax(const ARel: string; AState: TFileState);
var
  i: Integer;
  cur: TFileState;
begin
  if ARel = '' then Exit;
  i := FMap.IndexOf(ARel);
  if i < 0 then
    FMap.AddObject(ARel, TObject(PtrInt(Ord(AState) + 1)))
  else
  begin
    cur := TFileState(PtrInt(FMap.Objects[i]) - 1);
    if StateSeverity(AState) > StateSeverity(cur) then
      FMap.Objects[i] := TObject(PtrInt(Ord(AState) + 1));
  end;
end;

{ Record AState for ARel and propagate it up every ancestor folder. }
procedure TRepoStatusCache.RollUp(const ARel: string; AState: TFileState);
var
  p: string;
  sl: Integer;
begin
  p := NormRel(ARel);
  PutMax(p, AState);
  repeat
    sl := LastDelimiter('/', p);
    if sl <= 0 then Break;
    p := Copy(p, 1, sl - 1);
    PutMax(p, AState);      // ancestor folder
  until p = '';
end;

{ Split a NUL-separated git -z blob into records (trailing empty dropped). }
procedure SplitNul(const AData: string; AOut: TStrings);
var
  i, start: Integer;
begin
  AOut.Clear;
  start := 1;
  for i := 1 to Length(AData) do
    if AData[i] = #0 then
    begin
      AOut.Add(Copy(AData, start, i - start));
      start := i + 1;
    end;
  if start <= Length(AData) then
    AOut.Add(Copy(AData, start, MaxInt));
end;

procedure TRepoStatusCache.Refresh;
var
  git: TGitRunner;
  r: TGitResult;
  recs: TStringList;
  i: Integer;
  line, x, y, path: string;
  st: TFileState;
begin
  FMap.Clear;
  git := TGitRunner.Create(FDir);
  recs := TStringList.Create;
  try
    git.DefaultTimeoutMs := GIT_DEFAULT_TIMEOUT_MS;   // never hang a caller
    if not IsGitWorkTree(FDir) then
    begin
      FStamp := GetTickCount64;
      Exit;
    end;

    // 1) tracked files -> synced (overridden below by any non-clean state)
    r := git.GitQuiet(['ls-files', '-z']);
    if r.Ok then
    begin
      SplitNul(r.StdOut, recs);
      for i := 0 to recs.Count - 1 do
        if recs[i] <> '' then
          RollUp(recs[i], fsSynced);
    end;

    // 2) non-clean entries from porcelain override with modified/conflict
    r := git.GitQuiet(['status', '--porcelain', '-z', '--untracked-files=all']);
    if r.Ok then
    begin
      SplitNul(r.StdOut, recs);
      i := 0;
      while i < recs.Count do
      begin
        line := recs[i];
        Inc(i);
        if Length(line) < 3 then Continue;
        x := line[1];
        y := line[2];
        path := Copy(line, 4, MaxInt);        // after "XY "
        // renames/copies emit the origin path as the NEXT -z record: consume it
        if (x = 'R') or (x = 'C') or (y = 'R') or (y = 'C') then
          Inc(i);
        if (x = 'U') or (y = 'U') or ((x = 'A') and (y = 'A')) or
          ((x = 'D') and (y = 'D')) then
          st := fsConflict
        else
          st := fsModified;                    // M/A/D/R/C/T and untracked "??"
        RollUp(path, st);
      end;
    end;

    FStamp := GetTickCount64;
  finally
    recs.Free;
    git.Free;
  end;
end;

function TRepoStatusCache.LookupRel(const ARel: string): TFileState;
var
  i: Integer;
  key: string;
begin
  key := NormRel(ARel);
  if key = '' then
  begin
    // the repo root itself: worst of everything = its own roll-up under ''
    i := FMap.IndexOf('');
    if i >= 0 then Exit(TFileState(PtrInt(FMap.Objects[i]) - 1));
    Exit(fsSynced);   // an empty but valid work tree
  end;
  i := FMap.IndexOf(key);
  if i < 0 then Exit(fsNone);
  Result := TFileState(PtrInt(FMap.Objects[i]) - 1);
end;

{ ---- TStatusCache ---- }

constructor TStatusCache.Create(const ARootDir: string);
begin
  inherited Create;
  FRootDir := ExcludeTrailingPathDelimiter(ARootDir);
  FLock := TCriticalSection.Create;
  FTtlMs := 4000;
  FRepos := TStringList.Create;
  FRepos.OwnsObjects := True;
  FRepos.CaseSensitive := PathCaseSensitive;
  FRepos.Sorted := True;
end;

destructor TStatusCache.Destroy;
begin
  FRepos.Free;
  FLock.Free;
  inherited Destroy;
end;

{ Map an absolute path to the deepest owning repo (root or a submodule) and the
  path relative to THAT repo's working tree. Returns '' if outside RootDir. }
function TStatusCache.OwningRepo(const AAbsPath: string;
  out ARelInRepo: string): string;
var
  absN, rootN, relRoot, subRel, best: string;
  subs: TSubmoduleArray;
  i: Integer;
begin
  Result := '';
  ARelInRepo := '';
  absN := NormRel(AAbsPath);
  rootN := NormRel(FRootDir);
  if not IsPrefixPath(rootN, absN) then Exit;    // outside the .gotbox tree
  relRoot := NormRel(Copy(absN, Length(rootN) + 1, MaxInt));   // path under root

  best := '';                       // deepest submodule local name matched
  subs := ListSubmodules(FRootDir);
  for i := 0 to High(subs) do
  begin
    subRel := NormRel(subs[i].LocalName);
    if IsPrefixPath(subRel, relRoot) and (Length(subRel) > Length(best)) then
      best := subRel;
  end;

  if best = '' then
  begin
    Result := FRootDir;
    ARelInRepo := relRoot;
  end
  else
  begin
    Result := ExcludeTrailingPathDelimiter(
      IncludeTrailingPathDelimiter(FRootDir) + SetDirSeparators(best));
    ARelInRepo := NormRel(Copy(relRoot, Length(best) + 1, MaxInt));
  end;
end;

function TStatusCache.RepoCacheFor(const ARepoDir: string): TRepoStatusCache;
var
  i: Integer;
begin
  i := FRepos.IndexOf(ARepoDir);
  if i >= 0 then
    Result := TRepoStatusCache(FRepos.Objects[i])
  else
  begin
    Result := TRepoStatusCache.Create(ARepoDir);
    FRepos.AddObject(ARepoDir, Result);
  end;
end;

function TStatusCache.Lookup(const AAbsPath: string): TFileState;
var
  repoDir, relInRepo: string;
  rc: TRepoStatusCache;
begin
  Result := fsNone;
  FLock.Enter;
  try
    repoDir := OwningRepo(AAbsPath, relInRepo);
    if repoDir = '' then Exit;
    rc := RepoCacheFor(repoDir);
    // >= (not >) so TtlMs=0 means "always refresh": on Windows GetTickCount64
    // has ~15ms granularity, so two lookups in the same tick would otherwise
    // reuse a stale cache (the source of the flaky untracked-overlay result).
    if (rc.Stamp = 0) or (GetTickCount64 - rc.Stamp >= QWord(FTtlMs)) then
      rc.Refresh;
    Result := rc.LookupRel(relInRepo);
  finally
    FLock.Leave;
  end;
end;

procedure TStatusCache.Invalidate(const ARepoDir: string);
var
  i: Integer;
begin
  FLock.Enter;
  try
    if ARepoDir = '' then
    begin
      for i := 0 to FRepos.Count - 1 do
        TRepoStatusCache(FRepos.Objects[i]).Stamp := 0;
    end
    else
    begin
      i := FRepos.IndexOf(ExcludeTrailingPathDelimiter(ARepoDir));
      if i >= 0 then TRepoStatusCache(FRepos.Objects[i]).Stamp := 0;
    end;
  finally
    FLock.Leave;
  end;
end;

end.
