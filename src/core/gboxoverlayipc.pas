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
    FListener: TThread;
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
  PIPE_NOWAIT              = $00000001;
  PIPE_UNLIMITED_INSTANCES = 255;
  ERROR_PIPE_CONNECTED     = 535;
  ERROR_NO_DATA            = 232;

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

{ Read the request (a path up to LF) with a short deadline, then reply one
  byte. Uses non-blocking mode so a silent client can never stall the single
  listener thread. }
procedure TOverlayListener.Serve(hPipe: THandle);
var
  mode, nRead, nWritten: DWORD;
  buf: array[0..511] of AnsiChar;
  req, tmp: string;
  deadline: QWord;
  b: Byte;
  ok: BOOL;
begin
  mode := PIPE_READMODE_BYTE or PIPE_NOWAIT;
  SetNamedPipeHandleState(hPipe, @mode, nil, nil);
  req := '';
  deadline := GetTickCount64 + 1000;
  while GetTickCount64 < deadline do
  begin
    nRead := 0;
    ok := ReadFile(hPipe, buf, SizeOf(buf), nRead, nil);
    if ok and (nRead > 0) then
    begin
      SetString(tmp, PAnsiChar(@buf[0]), nRead);
      req := req + tmp;
      if Pos(#10, req) > 0 then Break;
      if Length(req) > REQ_MAX then Break;
    end
    else if not ok then
    begin
      if GetLastError = ERROR_NO_DATA then Sleep(5)
      else Break;                      // pipe broken / closed
    end
    else
      Sleep(5);                        // connected but nothing yet
  end;
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

function OverlayQuery(const APath: string; const AEndpoint: string;
  ATimeoutMs: Integer): TFileState;
var
  ep, req: string;
  h: THandle;
  mode, nWritten, nRead: DWORD;
  b: Byte;
  overall, rdDeadline: QWord;
  ok: BOOL;
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
    repeat
      gotByte := False;
      if WaitNamedPipe(PChar(ep), 50) then
      begin
        h := CreateFile(PChar(ep), GENERIC_READ or GENERIC_WRITE, 0, nil,
          OPEN_EXISTING, 0, 0);
        if h <> INVALID_HANDLE_VALUE then
          try
            mode := PIPE_READMODE_BYTE or PIPE_NOWAIT;
            SetNamedPipeHandleState(h, @mode, nil, nil);
            req := APath + #10;
            nWritten := 0;
            if WriteFile(h, PChar(req)^, Length(req), nWritten, nil) then
            begin
              rdDeadline := GetTickCount64 + 500;
              while (GetTickCount64 < rdDeadline) and (GetTickCount64 < overall) do
              begin
                nRead := 0;
                ok := ReadFile(h, b, 1, nRead, nil);
                if ok and (nRead = 1) then
                begin
                  Result := ByteToState(b);
                  gotByte := True;
                  Break;
                end;
                if (not ok) and (GetLastError <> ERROR_NO_DATA) then Break;
                Sleep(5);
              end;
            end;
          finally
            CloseHandle(h);
          end;
      end;
      if gotByte then Exit;
      Sleep(5);
    until GetTickCount64 >= overall;
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
begin
  if Assigned(FListener) then Exit;
  if FEndpoint = '' then Exit;            // unsupported platform: no-op
  FListener := TOverlayListener.Create(FCache, FEndpoint);
  if Assigned(Log) then
    Log.Info('overlay', 'status server on ' + FEndpoint);
end;

procedure TOverlayServer.Stop;
begin
  if not Assigned(FListener) then Exit;
  TOverlayListener(FListener).Shutdown;
  FListener.WaitFor;
  FreeAndNil(FListener);
end;

end.
