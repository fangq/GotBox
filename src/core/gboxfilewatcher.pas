unit gboxfilewatcher;

{ Cross-platform file-change watcher behind a small abstraction so native
  backends (inotify / ReadDirectoryChangesW / FSEvents) can be slotted in later.

  The current implementation is TPollingFileWatcher: a background thread that
  periodically walks the tree and fires OnChanged when an aggregate signature
  (file count + a per-file checksum of relpath/mtime/size) differs from the last
  scan. It skips the .git directory and any names matching the ignore globs.

  OnChanged is invoked from the watcher's own thread; the handler must be
  thread-safe (the RepoWorker just sets a debounce flag under a lock). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TFileWatchEvent = procedure(Sender: TObject) of object;

  TFileWatcher = class
  protected
    FRoot: string;
    FIgnore: TStringList;
    FOnChanged: TFileWatchEvent;
  public
    constructor Create(const ARoot: string; AIgnore: TStrings); virtual;
    destructor Destroy; override;
    procedure Start; virtual; abstract;
    procedure Stop; virtual; abstract;
    property OnChanged: TFileWatchEvent read FOnChanged write FOnChanged;
  end;

{ Returns the best available watcher for this platform. For now always polling. }
function CreateFileWatcher(const ARoot: string; AIgnore: TStrings;
  APollMs: Integer = 1500): TFileWatcher;

{ Simple shell-style glob match supporting * and ? (case-insensitive). }
function MatchGlob(const AName, APattern: string): Boolean;

implementation

function MatchGlob(const AName, APattern: string): Boolean;
var
  n, p, nLen, pLen, star, mark: Integer;
begin
  n := 1;
  p := 1;
  nLen := Length(AName);
  pLen := Length(APattern);
  star := 0;
  mark := 0;
  while n <= nLen do
  begin
    if (p <= pLen) and ((APattern[p] = '?') or
      (UpCase(APattern[p]) = UpCase(AName[n]))) then
    begin
      Inc(n);
      Inc(p);
    end
    else if (p <= pLen) and (APattern[p] = '*') then
    begin
      star := p;
      mark := n;
      Inc(p);
    end
    else if star <> 0 then
    begin
      p := star + 1;
      Inc(mark);
      n := mark;
    end
    else
      Exit(False);
  end;
  while (p <= pLen) and (APattern[p] = '*') do Inc(p);
  Result := p > pLen;
end;

type
  TPollThread = class;

  TPollingFileWatcher = class(TFileWatcher)
  private
    FThread: TPollThread;
    FPollMs: Integer;
  public
    constructor Create(const ARoot: string; AIgnore: TStrings; APollMs: Integer);
    procedure Start; override;
    procedure Stop; override;
  end;

  TPollThread = class(TThread)
  private
    FOwner: TPollingFileWatcher;
    FLastSig: QWord;
    FLastCount: Integer;
    FHasBaseline: Boolean;
    function Ignored(const AName: string): Boolean;
    procedure ScanDir(const ADir: string; var ASig: QWord; var ACount: Integer);
    function Scan(out ASig: QWord; out ACount: Integer): Boolean;
  protected
    procedure Execute; override;
  end;

  { ---- TFileWatcher ---- }

constructor TFileWatcher.Create(const ARoot: string; AIgnore: TStrings);
begin
  inherited Create;
  FRoot := ARoot;
  FIgnore := TStringList.Create;
  if Assigned(AIgnore) then FIgnore.Assign(AIgnore);
end;

destructor TFileWatcher.Destroy;
begin
  FIgnore.Free;
  inherited Destroy;
end;

function CreateFileWatcher(const ARoot: string; AIgnore: TStrings;
  APollMs: Integer): TFileWatcher;
begin
  Result := TPollingFileWatcher.Create(ARoot, AIgnore, APollMs);
end;

{ ---- TPollingFileWatcher ---- }

constructor TPollingFileWatcher.Create(const ARoot: string; AIgnore: TStrings;
  APollMs: Integer);
begin
  inherited Create(ARoot, AIgnore);
  FPollMs := APollMs;
end;

procedure TPollingFileWatcher.Start;
begin
  if Assigned(FThread) then Exit;
  FThread := TPollThread.Create(True);
  FThread.FOwner := Self;
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

procedure TPollingFileWatcher.Stop;
begin
  if not Assigned(FThread) then Exit;
  FThread.Terminate;
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

{ ---- TPollThread ---- }

function TPollThread.Ignored(const AName: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to FOwner.FIgnore.Count - 1 do
    if MatchGlob(AName, FOwner.FIgnore[i]) then
      Exit(True);
end;

procedure TPollThread.ScanDir(const ADir: string; var ASig: QWord; var ACount: Integer);
var
  sr: TSearchRec;
  full, rel: string;
  h: QWord;
  k: Integer;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + AllFilesMask,
    faAnyFile, sr) <> 0 then
    Exit;
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      if (sr.Attr and faDirectory) <> 0 then
      begin
        if SameText(sr.Name, '.git') then Continue;
        if Ignored(sr.Name) then Continue;
        ScanDir(IncludeTrailingPathDelimiter(ADir) + sr.Name, ASig, ACount);
      end
      else
      begin
        if Ignored(sr.Name) then Continue;
        full := IncludeTrailingPathDelimiter(ADir) + sr.Name;
        rel := Copy(full, Length(FOwner.FRoot) + 1, MaxInt);
        // order-independent accumulation (XOR) of a per-file hash
        h := 1469598103934665603;             // FNV-1a offset basis
        for k := 1 to Length(rel) do
          h := (h xor QWord(Ord(rel[k]))) * 1099511628211;
        h := h xor (QWord(sr.Time) * 2654435761);
        h := h xor QWord(sr.Size);
        ASig := ASig xor h;
        Inc(ACount);
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

function TPollThread.Scan(out ASig: QWord; out ACount: Integer): Boolean;
begin
  ASig := 0;
  ACount := 0;
  Result := DirectoryExists(FOwner.FRoot);
  if Result then
    ScanDir(ExcludeTrailingPathDelimiter(FOwner.FRoot), ASig, ACount);
end;

procedure TPollThread.Execute;
var
  sig: QWord;
  cnt, slept: Integer;
begin
  while not Terminated do
  begin
    if Scan(sig, cnt) then
    begin
      if not FHasBaseline then
      begin
        FLastSig := sig;
        FLastCount := cnt;
        FHasBaseline := True;
      end
      else if (sig <> FLastSig) or (cnt <> FLastCount) then
      begin
        FLastSig := sig;
        FLastCount := cnt;
        if Assigned(FOwner.FOnChanged) then FOwner.FOnChanged(FOwner);
      end;
    end;
    // sleep in small slices so Stop is responsive
    slept := 0;
    while (not Terminated) and (slept < FOwner.FPollMs) do
    begin
      Sleep(50);
      Inc(slept, 50);
    end;
  end;
end;

end.
