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

unit gboxoverlayipc;

{ Tiny local IPC that lets an out-of-process client (the Windows Explorer icon-
  overlay DLL) ask the running GotBox process for one path's sync status without
  itself running git. The already-running service hosts a server bound to a
  per-user endpoint; a client connects, writes one filesystem path + LF, and
  reads back a single status byte:

      0 = none (no overlay)   1 = synced   2 = modified   3 = conflict

  On Windows the endpoint is a named pipe (\\.\pipe\GotBox-Overlay-<user>) --
  what the overlay DLL, running inside explorer.exe as the same user, connects
  to. On Unix it is a Unix-domain socket under /tmp; there is no overlay
  consumer there, but the identical server/client run so the protocol is
  exercised by the Linux test suite. Everything is fail-safe: if the server is
  absent or slow, the client returns fsNone within a short timeout so the file
  manager never hangs. The server reads from a shared TStatusCache, so answering
  a query never runs git on the request path. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxfilestatus;

type
  { Background server that answers path->state queries from a TStatusCache. The
    cache is borrowed (not owned); it must outlive the server. Failures to bind
    the endpoint are non-fatal: overlays simply will not work. }
  TOverlayServer = class
  private
    FCache: TStatusCache;
    FEndpoint: string;
    FListeners: array of TThread;
  public
    constructor Create(ACache: TStatusCache; const AEndpoint: string = '');
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    property Endpoint: string read FEndpoint;
  end;

{ The endpoint used by default (named pipe on Windows, socket path on Unix),
  namespaced by the current user so instances of different users never clash. }
function DefaultOverlayEndpoint: string;

{ Client side (used by the overlay DLL and the test): ask the server for a
  path's state. Returns fsNone on any error/timeout -- never raises, never
  blocks longer than ATimeoutMs. AEndpoint = '' uses DefaultOverlayEndpoint. }
function OverlayQuery(const APath: string; const AEndpoint: string = '';
  ATimeoutMs: Integer = 500): TFileState;

implementation

uses
  gboxlog
  {$IF DEFINED(WINDOWS)}, Windows{$ELSEIF DEFINED(UNIX)}, BaseUnix, Sockets, ctypes{$ENDIF};

const
  REQ_MAX = 8192;     // guard against a runaway/abusive request
  { Explorer queries from several threads at once. On Windows each listener
    thread keeps its own pipe instance waiting, so concurrent clients are
    served in parallel instead of queueing on (and retrying around) a single
    instance. The Unix socket accepts a backlog, so one listener does. }
  LISTENER_COUNT = {$IFDEF WINDOWS}4{$ELSE}1{$ENDIF};

{ ---- shared request/response helpers ---- }

{ Compute the reply byte for a raw request buffer (a path, possibly with a
  trailing LF and partial follow-on bytes). Does the O(1)-ish cache lookup. }
function ReplyByteFor(ACache: TStatusCache; const ARaw: string): Byte;
var
  p: string;
  i: Integer;
begin
  p := ARaw;
  i := Pos(#10, p);
  if i > 0 then SetLength(p, i - 1);
  while (p <> '') and ((p[Length(p)] = #13) or (p[Length(p)] = ' ')) do
    SetLength(p, Length(p) - 1);
  if (p = '') or (ACache = nil) then Exit(Byte(Ord(fsNone)));
  Result := Byte(Ord(ACache.Lookup(p)));
end;

function ByteToState(AByte: Byte): TFileState;
begin
  if AByte <= Byte(Ord(High(TFileState))) then
    Result := TFileState(AByte)
  else
    Result := fsNone;
end;

{ ============================ Windows ============================ }
{$IF DEFINED(WINDOWS)}

const
  // FPC's Windows unit is missing some of these; declare them locally (same
  // values as <winbase.h>) so we never depend on RTL coverage.
  PIPE_ACCESS_DUPLEX       = $00000003;
  PIPE_TYPE_BYTE           = $00000000;
  PIPE_READMODE_BYTE       = $00000000;
  PIPE_WAIT                = $00000000;
  PIPE_UNLIMITED_INSTANCES = 255;
  ERROR_PIPE_CONNECTED     = 535;
  ERROR_IO_PENDING         = 997;

function DefaultOverlayEndpoint: string;
var
  u: string;
begin
  // qualified: the Windows unit shadows the RTL's 1-arg GetEnvironmentVariable
  u := SysUtils.GetEnvironmentVariable('USERNAME');
  u := StringReplace(u, '\', '_', [rfReplaceAll]);
  if u = '' then u := 'user';
  Result := '\\.\pipe\GotBox-Overlay-' + u;
end;

type
  TOverlayListener = class(TThread)
  private
    FCache: TStatusCache;
    FEndpoint: string;
    FDone: Boolean;
    procedure Serve(hPipe: THandle);
  protected
    procedure Execute; override;
  public
    constructor Create(ACache: TStatusCache; const AEndpoint: string);
    procedure Shutdown;   // wake a blocked ConnectNamedPipe so Execute can exit
  end;

constructor TOverlayListener.Create(ACache: TStatusCache; const AEndpoint: string);
begin
  FCache := ACache;
  FEndpoint := AEndpoint;
  FDone := False;
  inherited Create(False);   // start running
end;

{ Read the request (a path up to LF), then reply one byte. Blocking reads: the
  client writes its whole request right after connecting, so the read returns
  at once -- the old non-blocking poll paid a Sleep(5) (~15 ms on Windows) per
  query. A client that connects and never writes can hold this one listener,
  but the others keep serving, and the read ends when that client goes away. }
procedure TOverlayListener.Serve(hPipe: THandle);
var
  nRead, nWritten: DWORD;
  buf: array[0..511] of AnsiChar;
  req, tmp: string;
  b: Byte;
begin
  req := '';
  repeat
    nRead := 0;
    if not ReadFile(hPipe, buf, SizeOf(buf), nRead, nil) then Break;   // gone
    if nRead = 0 then Break;
    SetString(tmp, PAnsiChar(@buf[0]), nRead);
    req := req + tmp;
  until (Pos(#10, req) > 0) or (Length(req) > REQ_MAX);
  b := ReplyByteFor(FCache, req);
  WriteFile(hPipe, b, 1, nWritten, nil);
  FlushFileBuffers(hPipe);
end;

procedure TOverlayListener.Execute;
var
  h: THandle;
  connected: BOOL;
begin
  try
    while not Terminated do
    begin
      h := CreateNamedPipe(PChar(FEndpoint), PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES, 512, 512, 0, nil);
      if h = INVALID_HANDLE_VALUE then
      begin
        Sleep(500);          // transient; retry (Terminated re-checked at top)
        Continue;
      end;
      connected := ConnectNamedPipe(h, nil);
      if (not connected) and (GetLastError = ERROR_PIPE_CONNECTED) then
        connected := True;
      if Terminated then
      begin
        CloseHandle(h);
        Break;
      end;
      if connected then
        try
          Serve(h);
        except
          on E: Exception do
            if Assigned(Log) then Log.Warn('overlay', 'serve: ' + E.Message);
        end;
      DisconnectNamedPipe(h);
      CloseHandle(h);
    end;
  finally
    FDone := True;
  end;
end;

{ Set Terminated, then repeatedly self-connect to unblock a pending
  ConnectNamedPipe until the loop actually exits. }
procedure TOverlayListener.Shutdown;
var
  h: THandle;
  tries: Integer;
begin
  Terminate;
  tries := 0;
  while (not FDone) and (tries < 100) do
  begin
    if WaitNamedPipe(PChar(FEndpoint), 20) then
    begin
      h := CreateFile(PChar(FEndpoint), GENERIC_READ or GENERIC_WRITE, 0, nil,
        OPEN_EXISTING, 0, 0);
      if h <> INVALID_HANDLE_VALUE then CloseHandle(h);
    end;
    Sleep(20);
    Inc(tries);
  end;
end;

{ Wait up to AMs for an overlapped I/O on AH to finish; on timeout cancel it
  (and wait for the cancellation, so AOv/the buffer are not used afterwards).
  True if it completed and transferred ADone bytes. }
function FinishOverlapped(AH: THandle; var AOv: TOverlapped; AStarted: BOOL;
  AMs: DWORD; out ADone: DWORD): Boolean;
begin
  ADone := 0;
  if (not AStarted) and (GetLastError <> ERROR_IO_PENDING) then Exit(False);
  if WaitForSingleObject(AOv.hEvent, AMs) <> WAIT_OBJECT_0 then
  begin
    CancelIo(AH);
    GetOverlappedResult(AH, AOv, ADone, True);
    Exit(False);
  end;
  Result := GetOverlappedResult(AH, AOv, ADone, False);
end;

function OverlayQuery(const APath: string; const AEndpoint: string;
  ATimeoutMs: Integer): TFileState;
var
  ep, req: string;
  h, ev: THandle;
  nDone: DWORD;
  b: Byte;
  overall, now: QWord;
  ov: TOverlapped;
  gotByte: Boolean;
begin
  Result := fsNone;
  ep := AEndpoint;
  if ep = '' then ep := DefaultOverlayEndpoint;
  if ATimeoutMs < 1 then ATimeoutMs := 1;
  overall := GetTickCount64 + QWord(ATimeoutMs);
  try
    // Retry the whole connect+query until we actually read a reply byte or the
    // budget runs out. The server hosts ONE pipe instance at a time and recreates
    // it between clients, so a query can briefly find no listening instance (or a
    // just-closed one) and fail to connect. Retrying rides over that gap. A real
    // reply -- INCLUDING byte 0 (none) -- returns immediately; only a transport
    // failure (no byte) is retried, so legitimate "none" answers stay fast.
    // Overlapped I/O with real waits instead of the old Sleep(5) polling, which
    // cost ~15 ms per wait on Windows' default timer -- several per query, three
    // queries per file Explorer paints.
    ev := CreateEvent(nil, True, False, nil);
    if ev = 0 then Exit;
    try
      repeat
        gotByte := False;
        if WaitNamedPipe(PChar(ep), 50) then
        begin
          h := CreateFile(PChar(ep), GENERIC_READ or GENERIC_WRITE, 0, nil,
            OPEN_EXISTING, FILE_FLAG_OVERLAPPED, 0);
          if h <> INVALID_HANDLE_VALUE then
            try
              req := APath + #10;
              now := GetTickCount64;
              if now >= overall then Break;
              FillChar(ov, SizeOf(ov), 0);
              ov.hEvent := ev;
              ResetEvent(ev);
              if FinishOverlapped(h, ov, WriteFile(h, PChar(req)^, Length(req),
                nDone, @ov), DWORD(overall - now), nDone) and
                (nDone = DWORD(Length(req))) then
              begin
                now := GetTickCount64;
                if now < overall then
                begin
                  FillChar(ov, SizeOf(ov), 0);
                  ov.hEvent := ev;
                  ResetEvent(ev);
                  if FinishOverlapped(h, ov, ReadFile(h, b, 1, nDone, @ov),
                    DWORD(overall - now), nDone) and (nDone = 1) then
                  begin
                    Result := ByteToState(b);
                    gotByte := True;
                  end;
                end;
              end;
            finally
              CloseHandle(h);
            end;
        end;
        if gotByte then Exit;
        // no instance free / transport hiccup: retry while the budget lasts
        Sleep(1);
      until GetTickCount64 >= overall;
    finally
      CloseHandle(ev);
    end;
  except
    Result := fsNone;   // fail-safe: never propagate into the file manager
  end;
end;

{ ============================ Unix ============================ }
{$ELSEIF DEFINED(UNIX)}

function DefaultOverlayEndpoint: string;
var
  u: string;
begin
  u := GetEnvironmentVariable('USER');
  if u = '' then u := IntToStr(fpGetUID);
  Result := '/tmp/gotbox-overlay-' + u + '.sock';
end;

type
  TSunAddr = packed record
    sun_family: cushort;
    sun_path: array[0..107] of AnsiChar;
  end;

procedure FillAddr(out AAddr: TSunAddr; const APath: string);
var
  n: Integer;
begin
  FillChar(AAddr, SizeOf(AAddr), 0);
  AAddr.sun_family := AF_UNIX;
  n := Length(APath);
  if n > SizeOf(AAddr.sun_path) - 1 then n := SizeOf(AAddr.sun_path) - 1;
  if n > 0 then Move(APath[1], AAddr.sun_path[0], n);
end;

type
  TOverlayListener = class(TThread)
  private
    FCache: TStatusCache;
    FEndpoint: string;
    FSock: cint;
    procedure Serve(AConn: cint);
  protected
    procedure Execute; override;
  public
    constructor Create(ACache: TStatusCache; const AEndpoint: string);
    procedure Shutdown;
  end;

constructor TOverlayListener.Create(ACache: TStatusCache; const AEndpoint: string);
begin
  FCache := ACache;
  FEndpoint := AEndpoint;
  FSock := -1;
  inherited Create(False);
end;

procedure TOverlayListener.Serve(AConn: cint);
var
  buf: array[0..511] of AnsiChar;
  n: ssize_t;
  req, tmp: string;
  b: Byte;
begin
  req := '';
  repeat
    n := fpRecv(AConn, @buf[0], SizeOf(buf), 0);
    if n <= 0 then Break;
    SetString(tmp, PAnsiChar(@buf[0]), n);
    req := req + tmp;
  until (Pos(#10, req) > 0) or (Length(req) > REQ_MAX);
  b := ReplyByteFor(FCache, req);
  fpSend(AConn, @b, 1, 0);
end;

procedure TOverlayListener.Execute;
var
  addr: TSunAddr;
  c, sel: cint;
  rfds: TFDSet;
  tv: TTimeVal;
begin
  FSock := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if FSock < 0 then Exit;
  FillAddr(addr, FEndpoint);
  DeleteFile(FEndpoint);                          // clear any stale socket file
  if fpBind(FSock, psockaddr(@addr), SizeOf(addr)) <> 0 then
  begin
    CloseSocket(FSock);
    FSock := -1;
    Exit;
  end;
  if fpListen(FSock, 16) <> 0 then
  begin
    CloseSocket(FSock);
    FSock := -1;
    Exit;
  end;
  // Poll for a connection with a short timeout so Terminated is checked
  // promptly. (A blocking fpAccept cannot be reliably woken across processes
  // that share this per-user path, so we never depend on a self-connect.)
  while not Terminated do
  begin
    fpFD_ZERO(rfds);
    fpFD_SET(FSock, rfds);
    tv.tv_sec := 0;
    tv.tv_usec := 200 * 1000;
    sel := fpSelect(FSock + 1, @rfds, nil, nil, @tv);
    if Terminated then Break;
    if sel <= 0 then Continue;                    // timeout / EINTR -> re-check
    c := fpAccept(FSock, nil, nil);
    if c < 0 then Continue;
    try
      Serve(c);
    except
      on E: Exception do
        if Assigned(Log) then Log.Warn('overlay', 'serve: ' + E.Message);
    end;
    CloseSocket(c);
  end;
  CloseSocket(FSock);
  FSock := -1;
  DeleteFile(FEndpoint);
end;

procedure TOverlayListener.Shutdown;
begin
  Terminate;   // the select loop notices within its poll interval and exits
end;

function OverlayQuery(const APath: string; const AEndpoint: string;
  ATimeoutMs: Integer): TFileState;
var
  ep, req: string;
  addr: TSunAddr;
  s: cint;
  b: Byte;
  n: ssize_t;
begin
  Result := fsNone;
  ep := AEndpoint;
  if ep = '' then ep := DefaultOverlayEndpoint;
  s := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if s < 0 then Exit;
  try
    FillAddr(addr, ep);
    if fpConnect(s, psockaddr(@addr), SizeOf(addr)) <> 0 then Exit;   // no server
    req := APath + #10;
    fpSend(s, @req[1], Length(req), 0);
    n := fpRecv(s, @b, 1, 0);
    if n = 1 then Result := ByteToState(b);
  finally
    CloseSocket(s);
  end;
end;

{ ============================ other ============================ }
{$ELSE}

function DefaultOverlayEndpoint: string;
begin
  Result := '';
end;

type
  TOverlayListener = class(TThread)
  public
    constructor Create(ACache: TStatusCache; const AEndpoint: string);
    procedure Shutdown;
  protected
    procedure Execute; override;
  end;

constructor TOverlayListener.Create(ACache: TStatusCache; const AEndpoint: string);
begin
  inherited Create(True);   // created suspended and never started: a no-op
end;

procedure TOverlayListener.Execute;
begin
end;

procedure TOverlayListener.Shutdown;
begin
end;

function OverlayQuery(const APath: string; const AEndpoint: string;
  ATimeoutMs: Integer): TFileState;
begin
  Result := fsNone;
end;

{$ENDIF}

{ ---- TOverlayServer ---- }

constructor TOverlayServer.Create(ACache: TStatusCache; const AEndpoint: string);
begin
  inherited Create;
  FCache := ACache;
  if AEndpoint <> '' then FEndpoint := AEndpoint
  else FEndpoint := DefaultOverlayEndpoint;
end;

destructor TOverlayServer.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TOverlayServer.Start;
var
  i: Integer;
begin
  if Length(FListeners) > 0 then Exit;
  if FEndpoint = '' then Exit;            // unsupported platform: no-op
  SetLength(FListeners, LISTENER_COUNT);
  for i := 0 to High(FListeners) do
    FListeners[i] := TOverlayListener.Create(FCache, FEndpoint);
  if Assigned(Log) then
    Log.Info('overlay', 'status server on ' + FEndpoint);
end;

procedure TOverlayServer.Stop;
var
  i: Integer;
begin
  if Length(FListeners) = 0 then Exit;
  // terminate ALL first: a wake-up connection made for one listener may be
  // accepted by another, which must then exit too rather than serve it
  for i := 0 to High(FListeners) do
    FListeners[i].Terminate;
  for i := 0 to High(FListeners) do
    TOverlayListener(FListeners[i]).Shutdown;
  for i := 0 to High(FListeners) do
  begin
    FListeners[i].WaitFor;
    FListeners[i].Free;
  end;
  SetLength(FListeners, 0);
end;

end.
