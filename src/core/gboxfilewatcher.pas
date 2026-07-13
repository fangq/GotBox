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

unit gboxfilewatcher;

{ Cross-platform file-change watcher behind a small abstraction. Native backends
  are used per platform, with a polling backend as a portable fallback:

    Linux   -> inotify (recursive; watches added per directory)
    Windows -> ReadDirectoryChangesW (recursive via bWatchSubtree)
    macOS   -> FSEvents (recursive stream)
    other   -> polling

  Define GOTBOX_POLLING to force the polling backend everywhere. If a native
  backend fails to initialise it simply does nothing; the RepoWorker's periodic
  pull still picks up changes, so sync degrades gracefully rather than breaking.

  OnChanged is invoked from the watcher's own thread; the handler must be
  thread-safe (the RepoWorker just sets a debounce flag under a lock). The .git
  directory and ignore-glob matches are never reported. }

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
    function Ignored(const AName: string): Boolean;
    procedure Fire;
  public
    constructor Create(const ARoot: string; AIgnore: TStrings); virtual;
    destructor Destroy; override;
    procedure Start; virtual; abstract;
    procedure Stop; virtual; abstract;
    property OnChanged: TFileWatchEvent read FOnChanged write FOnChanged;
  end;

{ Returns the best available watcher for this platform. }
function CreateFileWatcher(const ARoot: string; AIgnore: TStrings;
  APollMs: Integer = 1500): TFileWatcher;

{ Simple shell-style glob match supporting * and ? (case-insensitive). }
function MatchGlob(const AName, APattern: string): Boolean;

implementation

uses
  {$IFDEF LINUX}BaseUnix, Linux,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  gboxlog;

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

{ ---- TFileWatcher base ---- }

constructor TFileWatcher.Create(const ARoot: string; AIgnore: TStrings);
begin
  inherited Create;
  FRoot := ExcludeTrailingPathDelimiter(ARoot);
  FIgnore := TStringList.Create;
  if Assigned(AIgnore) then FIgnore.Assign(AIgnore);
end;

destructor TFileWatcher.Destroy;
begin
  FIgnore.Free;
  inherited Destroy;
end;

function TFileWatcher.Ignored(const AName: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if SameText(AName, '.git') then Exit(True);
  for i := 0 to FIgnore.Count - 1 do
    if MatchGlob(AName, FIgnore[i]) then
      Exit(True);
end;

procedure TFileWatcher.Fire;
begin
  if Assigned(FOnChanged) then FOnChanged(Self);
end;

{ ============================ polling backend ============================ }

type
  TPollThread = class;

  TPollingFileWatcher = class(TFileWatcher)
  private
    FThread: TPollThread;
    FPollMs: Integer;
  public
    constructor Create(const ARoot: string; AIgnore: TStrings; APollMs: Integer);
      reintroduce;
    procedure Start; override;
    procedure Stop; override;
  end;

  TPollThread = class(TThread)
  private
    FOwner: TPollingFileWatcher;
    FLastSig: QWord;
    FLastCount: Integer;
    FHasBaseline: Boolean;
    procedure ScanDir(const ADir: string; var ASig: QWord; var ACount: Integer);
    function Scan(out ASig: QWord; out ACount: Integer): Boolean;
  protected
    procedure Execute; override;
  end;

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
        if FOwner.Ignored(sr.Name) then Continue;
        ScanDir(IncludeTrailingPathDelimiter(ADir) + sr.Name, ASig, ACount);
      end
      else
      begin
        if FOwner.Ignored(sr.Name) then Continue;
        full := IncludeTrailingPathDelimiter(ADir) + sr.Name;
        rel := Copy(full, Length(FOwner.FRoot) + 1, MaxInt);
        h := 1469598103934665603;
        for k := 1 to Length(rel) do
          h := (h xor QWord(Ord(rel[k]))) * 1099511628211;
        h := h xor (QWord(sr.Time) * 2654435761);
        h := h xor QWord(sr.Size);
        ASig := ASig xor h;
        Inc(ACount);
      end;
    until FindNext(sr) <> 0;
  finally
    SysUtils.FindClose(sr);
  end;
end;

function TPollThread.Scan(out ASig: QWord; out ACount: Integer): Boolean;
begin
  ASig := 0;
  ACount := 0;
  Result := DirectoryExists(FOwner.FRoot);
  if Result then ScanDir(FOwner.FRoot, ASig, ACount);
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
        FOwner.Fire;
      end;
    end;
    slept := 0;
    while (not Terminated) and (slept < FOwner.FPollMs) do
    begin
      Sleep(50);
      Inc(slept, 50);
    end;
  end;
end;

{$IFDEF LINUX}
{ ============================ inotify backend ============================ }

type
  TInotifyThread = class;

  TInotifyFileWatcher = class(TFileWatcher)
  private
    FThread: TInotifyThread;
  public
    procedure Start; override;
    procedure Stop; override;
  end;

  TInotifyThread = class(TThread)
  private
    FOwner: TInotifyFileWatcher;
    FFd: cint;
    FWatchPaths: TStringList;   // Objects[i] = wd
    function PathForWd(AWd: cint): string;
    procedure AddWatch(const APath: string);
    procedure AddWatchRecursive(const APath: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TInotifyFileWatcher);
    destructor Destroy; override;
  end;

const
  INMASK = IN_CLOSE_WRITE or IN_CREATE or IN_DELETE or IN_MOVED_FROM or
    IN_MOVED_TO or IN_MOVE_SELF or IN_DELETE_SELF;

constructor TInotifyThread.Create(AOwner: TInotifyFileWatcher);
begin
  inherited Create(True);
  FOwner := AOwner;
  FWatchPaths := TStringList.Create;
  FFd := -1;
end;

destructor TInotifyThread.Destroy;
begin
  FWatchPaths.Free;
  inherited Destroy;
end;

function TInotifyThread.PathForWd(AWd: cint): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to FWatchPaths.Count - 1 do
    if PtrInt(FWatchPaths.Objects[i]) = AWd then
      Exit(FWatchPaths[i]);
end;

procedure TInotifyThread.AddWatch(const APath: string);
var
  wd: cint;
  i: Integer;
begin
  wd := inotify_add_watch(FFd, PChar(APath), INMASK);
  if wd < 0 then Exit;
  for i := 0 to FWatchPaths.Count - 1 do
    if PtrInt(FWatchPaths.Objects[i]) = wd then
    begin
      FWatchPaths[i] := APath;   // already watched (same wd) -> refresh path
      Exit;
    end;
  FWatchPaths.AddObject(APath, TObject(PtrInt(wd)));
end;

procedure TInotifyThread.AddWatchRecursive(const APath: string);
var
  sr: TSearchRec;
begin
  AddWatch(APath);
  if FindFirst(IncludeTrailingPathDelimiter(APath) + AllFilesMask, faDirectory, sr) = 0 then
  begin
    try
      repeat
        if (sr.Attr and faDirectory) = 0 then Continue;
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        if FOwner.Ignored(sr.Name) then Continue;
        AddWatchRecursive(IncludeTrailingPathDelimiter(APath) + sr.Name);
      until FindNext(sr) <> 0;
    finally
      SysUtils.FindClose(sr);
    end;
  end;
end;

procedure TInotifyThread.Execute;
var
  buf: array[0..8191] of Byte;
  r, i: PtrInt;
  hdr: PtrUInt;
  ev: Pinotify_event;
  evName, parent: string;
  isDir: Boolean;
begin
  hdr := PtrUInt(@(Pinotify_event(nil)^.name));   // offset of the name field
  AddWatchRecursive(FOwner.FRoot);

  while not Terminated do
  begin
    r := fpRead(FFd, buf, SizeOf(buf));
    if r <= 0 then
    begin
      if (r < 0) and (fpgeterrno = ESysEAGAIN) then
        Sleep(100)            // non-blocking fd: nothing pending
      else
        Sleep(50);
      Continue;
    end;

    i := 0;
    while i + PtrInt(hdr) <= r do
    begin
      ev := Pinotify_event(@buf[i]);
      if ev^.len > 0 then
        evName := StrPas(PChar(@ev^.name))
      else
        evName := '';
      isDir := (ev^.mask and IN_ISDIR) <> 0;

      // a newly created/moved-in subdirectory needs its own watch
      if isDir and ((ev^.mask and (IN_CREATE or IN_MOVED_TO)) <> 0)
        and (evName <> '') and not FOwner.Ignored(evName) then
      begin
        parent := PathForWd(ev^.wd);
        if parent <> '' then
          AddWatchRecursive(IncludeTrailingPathDelimiter(parent) + evName);
      end;

      // report the change unless it concerns an ignored entry
      if (evName = '') or not FOwner.Ignored(evName) then
        if (ev^.mask and INMASK) <> 0 then
          FOwner.Fire;

      i := i + PtrInt(hdr) + PtrInt(ev^.len);
    end;
  end;
end;

procedure TInotifyFileWatcher.Start;
var
  fd, fl: cint;
begin
  if Assigned(FThread) then Exit;
  fd := inotify_init;
  if fd < 0 then
  begin
    if Assigned(Log) then Log.Warn('watch', 'inotify_init failed; relying on periodic pull');
    Exit;
  end;
  // make the fd non-blocking so the watch thread can poll Terminated and exit
  // promptly on Stop (inotify_init1 flag handling is unreliable across libcs)
  fl := FpFcntl(fd, F_GETFL, 0);
  FpFcntl(fd, F_SETFL, fl or O_NONBLOCK);

  FThread := TInotifyThread.Create(Self);
  FThread.FFd := fd;
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

procedure TInotifyFileWatcher.Stop;
begin
  if not Assigned(FThread) then Exit;
  FThread.Terminate;
  FThread.WaitFor;
  if FThread.FFd >= 0 then fpClose(FThread.FFd);
  FreeAndNil(FThread);
end;
{$ENDIF}

{$IFDEF WINDOWS}
{ ==================== ReadDirectoryChangesW backend ==================== }
{ NOTE: compiled only on Windows (not verified on this Linux build host). }

const
  FILE_NOTIFY_CHANGE_FILE_NAME  = $00000001;
  FILE_NOTIFY_CHANGE_DIR_NAME   = $00000002;
  FILE_NOTIFY_CHANGE_ATTRIBUTES = $00000004;
  FILE_NOTIFY_CHANGE_SIZE       = $00000008;
  FILE_NOTIFY_CHANGE_LAST_WRITE = $00000010;
  FILE_FLAG_BACKUP_SEMANTICS    = $02000000;
  FILE_FLAG_OVERLAPPED          = $40000000;

type
  FILE_NOTIFY_INFORMATION = record
    NextEntryOffset: DWORD;
    Action: DWORD;
    FileNameLength: DWORD;
    FileName: array[0..0] of WideChar;
  end;
  PFILE_NOTIFY_INFORMATION = ^FILE_NOTIFY_INFORMATION;

function ReadDirectoryChangesW(hDirectory: THandle; lpBuffer: Pointer;
  nBufferLength: DWORD; bWatchSubtree: BOOL; dwNotifyFilter: DWORD;
  lpBytesReturned: LPDWORD; lpOverlapped: POverlapped;
  lpCompletionRoutine: Pointer): BOOL; stdcall;
  external 'kernel32' name 'ReadDirectoryChangesW';

function CancelIoEx(hFile: THandle; lpOverlapped: POverlapped): BOOL; stdcall;
  external 'kernel32' name 'CancelIoEx';

type
  TWinWatchThread = class;

  TWinFileWatcher = class(TFileWatcher)
  private
    FThread: TWinWatchThread;
    FDir: THandle;
    FStopEvent: THandle;   // manual-reset; signalled by Stop to unblock the wait
  public
    procedure Start; override;
    procedure Stop; override;
  end;

  TWinWatchThread = class(TThread)
  private
    FOwner: TWinFileWatcher;
  protected
    procedure Execute; override;
  end;

procedure TWinWatchThread.Execute;
var
  buf: array[0..16383] of Byte;
  bytes: DWORD;
  filter: DWORD;
  info: PFILE_NOTIFY_INFORMATION;
  off, nlen: DWORD;
  nm: WideString;
  changed: Boolean;
  ov: TOverlapped;
  ioEvent: THandle;
  waits: array[0..1] of THandle;
  wr: DWORD;
begin
  filter := FILE_NOTIFY_CHANGE_FILE_NAME or FILE_NOTIFY_CHANGE_DIR_NAME or
    FILE_NOTIFY_CHANGE_SIZE or FILE_NOTIFY_CHANGE_LAST_WRITE;
  // Overlapped (asynchronous) I/O: ReadDirectoryChangesW returns immediately and
  // signals ioEvent on completion. We then wait on BOTH ioEvent and the owner's
  // stop-event, so Stop can always wake us -- no dependence on CancelIoEx racing
  // a synchronous read (the intermittent Windows shutdown deadlock).
  ioEvent := CreateEvent(nil, True, False, nil);   // manual-reset
  if ioEvent = 0 then Exit;
  try
    while not Terminated do
    begin
      FillChar(ov, SizeOf(ov), 0);
      ov.hEvent := ioEvent;
      ResetEvent(ioEvent);
      bytes := 0;
      if not ReadDirectoryChangesW(FOwner.FDir, @buf, SizeOf(buf), True, filter,
        @bytes, @ov, nil) then
        Break;
      waits[0] := ioEvent;
      waits[1] := FOwner.FStopEvent;
      wr := WaitForMultipleObjects(2, PWOHandleArray(@waits[0]), False, INFINITE);
      if Terminated or (wr <> WAIT_OBJECT_0) then
      begin
        // stop requested (or wait failed): abort the pending read and leave
        CancelIoEx(FOwner.FDir, @ov);
        GetOverlappedResult(FOwner.FDir, ov, bytes, True);   // drain
        Break;
      end;
      // a change completed; fetch how many bytes were written
      if not GetOverlappedResult(FOwner.FDir, ov, bytes, False) then
        Continue;
      if bytes = 0 then
      begin
        FOwner.Fire;   // buffer overflow: too many changes to enumerate
        Continue;
      end;

    changed := False;
    off := 0;
    // Parse strictly within the `bytes` the OS reported, validating that each
    // record's fixed header (12 bytes) AND its name fit -- never trust the
    // NextEntryOffset chain to self-terminate in bounds. A truncated buffer
    // would otherwise walk `off` past `buf` and Move() past its end (an
    // out-of-bounds read that faults as runtime error 217 on Windows).
    while off + 12 <= bytes do    // 12 = NextEntryOffset + Action + FileNameLength
    begin
      info := PFILE_NOTIFY_INFORMATION(@buf[off]);
      nlen := info^.FileNameLength;
      if (nlen > bytes) or (off + 12 + nlen > bytes) then Break;
      SetLength(nm, nlen div SizeOf(WideChar));
      if Length(nm) > 0 then
        Move(info^.FileName, nm[1], nlen);
      // ignore anything under .git or matching an ignore glob
      if (Pos('\.git\', '\' + string(nm)) = 0) and
        not FOwner.Ignored(ExtractFileName(string(nm))) then
        changed := True;
      if info^.NextEntryOffset = 0 then Break;
      off := off + info^.NextEntryOffset;
    end;

      if changed then FOwner.Fire;
    end;
  finally
    CloseHandle(ioEvent);
  end;
end;

procedure TWinFileWatcher.Start;
begin
  if Assigned(FThread) then Exit;
  // FILE_FLAG_OVERLAPPED: the watch thread issues asynchronous reads so it can
  // wait on the completion event AND a stop-event together (see Execute).
  FDir := CreateFileW(PWideChar(WideString(FRoot)), GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OVERLAPPED, 0);
  if FDir = INVALID_HANDLE_VALUE then
  begin
    if Assigned(Log) then Log.Warn('watch', 'could not open dir for watching');
    Exit;
  end;
  FStopEvent := CreateEvent(nil, True, False, nil);   // manual-reset
  FThread := TWinWatchThread.Create(True);
  FThread.FOwner := Self;
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

procedure TWinFileWatcher.Stop;
begin
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    // Wake the thread's WaitForMultipleObjects immediately: with overlapped I/O
    // this cannot race (the manual-reset event stays signalled), so the thread
    // always aborts its pending read and exits -- Stop (and thus the owning sync
    // worker + engine.Stop) can never hang.
    if FStopEvent <> 0 then SetEvent(FStopEvent);
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  if (FDir <> 0) and (FDir <> INVALID_HANDLE_VALUE) then
  begin
    CloseHandle(FDir);
    FDir := INVALID_HANDLE_VALUE;
  end;
  if FStopEvent <> 0 then
  begin
    CloseHandle(FStopEvent);
    FStopEvent := 0;
  end;
end;
{$ENDIF}

{$IFDEF DARWIN}
{ ========================= FSEvents backend ========================= }
{ NOTE: compiled only on macOS (not verified on this Linux build host). }

{$linkframework CoreServices}
{$linkframework CoreFoundation}

type
  FSEventStreamRef = Pointer;
  CFAllocatorRef = Pointer;
  CFArrayRef = Pointer;
  CFStringRef = Pointer;
  CFRunLoopRef = Pointer;
  FSEventStreamEventId = QWord;
  ConstFSEventStreamRef = Pointer;

const
  kCFStringEncodingUTF8 = $08000100;
  kFSEventStreamEventIdSinceNow = QWord($FFFFFFFFFFFFFFFF);
  kFSEventStreamCreateFlagFileEvents = $00000010;
  kFSEventStreamCreateFlagNoDefer = $00000002;

function CFStringCreateWithCString(alloc: CFAllocatorRef; cStr: PChar;
  encoding: LongWord): CFStringRef; cdecl; external;
function CFArrayCreate(allocator: CFAllocatorRef; values: PPointer;
  numValues: PtrInt; callBacks: Pointer): CFArrayRef; cdecl; external;
procedure CFRelease(cf: Pointer); cdecl; external;
function CFRunLoopGetCurrent: CFRunLoopRef; cdecl; external;
procedure CFRunLoopRun; cdecl; external;
procedure CFRunLoopStop(rl: CFRunLoopRef); cdecl; external;

var
  { global CoreFoundation constant for the default run-loop mode }
  kCFRunLoopDefaultMode: CFStringRef; cvar; external;

type
  FSEventStreamContext = record
    version: PtrInt;
    info: Pointer;
    retain: Pointer;
    release: Pointer;
    copyDescription: Pointer;
  end;
  PFSEventStreamContext = ^FSEventStreamContext;
  FSEventStreamCallback = procedure(stream: ConstFSEventStreamRef; clientInfo: Pointer;
    numEvents: PtrUInt; eventPaths: Pointer; eventFlags: Pointer;
    eventIds: Pointer); cdecl;

function FSEventStreamCreate(allocator: CFAllocatorRef; callback: FSEventStreamCallback;
  context: PFSEventStreamContext; pathsToWatch: CFArrayRef;
  sinceWhen: FSEventStreamEventId; latency: Double; flags: LongWord): FSEventStreamRef;
  cdecl; external;
procedure FSEventStreamScheduleWithRunLoop(streamRef: FSEventStreamRef;
  runLoop: CFRunLoopRef; runLoopMode: CFStringRef); cdecl; external;
function FSEventStreamStart(streamRef: FSEventStreamRef): Boolean; cdecl; external;
procedure FSEventStreamStop(streamRef: FSEventStreamRef); cdecl; external;
procedure FSEventStreamInvalidate(streamRef: FSEventStreamRef); cdecl; external;
procedure FSEventStreamRelease(streamRef: FSEventStreamRef); cdecl; external;

type
  TMacWatchThread = class;

  TMacFileWatcher = class(TFileWatcher)
  private
    FThread: TMacWatchThread;
  public
    procedure Start; override;
    procedure Stop; override;
  end;

  TMacWatchThread = class(TThread)
  private
    FOwner: TMacFileWatcher;
    FStream: FSEventStreamRef;
    FRunLoop: CFRunLoopRef;
  protected
    procedure Execute; override;
  end;

procedure MacFSCallback(stream: ConstFSEventStreamRef; clientInfo: Pointer;
  numEvents: PtrUInt; eventPaths: Pointer; eventFlags: Pointer;
  eventIds: Pointer); cdecl;
begin
  if TObject(clientInfo) is TMacFileWatcher then
    TMacFileWatcher(clientInfo).Fire;
end;

procedure TMacWatchThread.Execute;
var
  cfPath: CFStringRef;
  cfArr: CFArrayRef;
  ctx: FSEventStreamContext;
begin
  FillChar(ctx, SizeOf(ctx), 0);
  ctx.info := Pointer(FOwner);
  cfPath := CFStringCreateWithCString(nil, PChar(FOwner.FRoot), kCFStringEncodingUTF8);
  cfArr := CFArrayCreate(nil, @cfPath, 1, nil);
  FStream := FSEventStreamCreate(nil, @MacFSCallback, @ctx, cfArr,
    kFSEventStreamEventIdSinceNow, 0.5,
    kFSEventStreamCreateFlagFileEvents or kFSEventStreamCreateFlagNoDefer);
  FRunLoop := CFRunLoopGetCurrent;
  if FStream <> nil then
  begin
    // schedule on the default mode -- the mode CFRunLoopRun actually runs in.
    // (CopyCurrentMode returns nil before the loop starts, which then traps.)
    FSEventStreamScheduleWithRunLoop(FStream, FRunLoop, kCFRunLoopDefaultMode);
    FSEventStreamStart(FStream);
    CFRunLoopRun;   // returns when CFRunLoopStop is called from Stop
    FSEventStreamStop(FStream);
    FSEventStreamInvalidate(FStream);
    FSEventStreamRelease(FStream);
  end;
  CFRelease(cfArr);
  CFRelease(cfPath);
end;

procedure TMacFileWatcher.Start;
begin
  if Assigned(FThread) then Exit;
  FThread := TMacWatchThread.Create(True);
  FThread.FOwner := Self;
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

procedure TMacFileWatcher.Stop;
begin
  if not Assigned(FThread) then Exit;
  FThread.Terminate;
  if FThread.FRunLoop <> nil then CFRunLoopStop(FThread.FRunLoop);
  FThread.WaitFor;
  FreeAndNil(FThread);
end;
{$ENDIF}

{ ============================== factory ============================== }

function CreateFileWatcher(const ARoot: string; AIgnore: TStrings;
  APollMs: Integer): TFileWatcher;
begin
  {$IFDEF GOTBOX_POLLING}
  Result := TPollingFileWatcher.Create(ARoot, AIgnore, APollMs);
  {$ELSE}
  {$IFDEF LINUX}
    Result := TInotifyFileWatcher.Create(ARoot, AIgnore);
  {$ELSE}
  {$IFDEF WINDOWS}
      Result := TWinFileWatcher.Create(ARoot, AIgnore);
  {$ELSE}
  {$IFDEF DARWIN}
        Result := TMacFileWatcher.Create(ARoot, AIgnore);
  {$ELSE}
  Result := TPollingFileWatcher.Create(ARoot, AIgnore, APollMs);
  {$ENDIF}
  {$ENDIF}
  {$ENDIF}
  {$ENDIF}
end;

end.
