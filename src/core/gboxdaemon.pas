{
  GotBox -- Dropbox-like file sync over your own private git repositories.
  Copyright (C) 2026 Qianqian Fang <q.fang@northeastern.edu> and contributors.

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

unit gboxdaemon;

{ Command-line handling and background (daemon) startup for GotBox.

  LCL-free so the core stays widgetset-independent. "Daemon mode" here means the
  classic Unix sense: detach from the controlling terminal and keep running in
  the background of the desktop session -- the tray icon and any first-run
  dialogs still appear, but the launching shell gets its prompt back and the app
  survives the terminal closing. On Windows a GUI-subsystem app launched from a
  console is already detached, so there is nothing to do. }

{$mode objfpc}{$H+}

interface

{ True if -d / --daemon was passed on the command line. }
function WantDaemon: Boolean;
{ True if -h / --help (or -?) was passed. }
function WantHelp: Boolean;
{ True if --takeover was passed (take over a root another instance manages). }
function WantTakeover: Boolean;
{ Help/usage text for --help. }
function UsageText: string;

{ Detach from the controlling terminal and run in the background (Unix/macOS).
  No-op on Windows. MUST be called at program start -- before the widgetset is
  initialized and before any worker threads are created -- because it forks. }
procedure Daemonize;

{ Single-instance guard, shared by the GUI (gotbox) and headless (gotboxd)
  binaries so the two can never sync the same root at once. Records our pid in
  the config dir; returns True (and does not overwrite) if a live GotBox process
  is already recorded. }
function AlreadyRunning: Boolean;

implementation

uses
  Classes, SysUtils, gboxconfigstore
  {$IFDEF UNIX}, BaseUnix, ctypes{$ENDIF}
  {$IFDEF WINDOWS}, Windows{$ENDIF};

function HasArg(const AShort, ALong: string): Boolean;
var
  i: Integer;
  a: string;
begin
  Result := False;
  for i := 1 to ParamCount do
  begin
    a := ParamStr(i);
    if (a = AShort) or (a = ALong) then
      Exit(True);
  end;
end;

function WantDaemon: Boolean;
begin
  Result := HasArg('-d', '--daemon');
end;

function WantHelp: Boolean;
begin
  Result := HasArg('-h', '--help') or HasArg('-?', '--help');
end;

function WantTakeover: Boolean;
begin
  Result := HasArg('--takeover', '--takeover');
end;

function UsageText: string;
begin
  Result :=
    'GotBox -- Dropbox-like file sync over GitHub private repos' +
    LineEnding + LineEnding + 'Usage: gotbox [options]' + LineEnding +
    LineEnding + 'Options:' + LineEnding +
    '  -d, --daemon   detach from the terminal and run in the background' +
    LineEnding + '  --takeover     take over a root another GotBox instance is managing'
    + LineEnding + '  -h, --help     show this help and exit' +
    LineEnding + LineEnding +
    'For a headless host or a plain SSH session (no X display), use the ' +
    'GUI-free' + LineEnding + 'daemon instead:  gotboxd [-d]' + LineEnding;
end;

{$IFDEF UNIX}
procedure Daemonize;
var
  pid: TPid;
  fd: cint;
begin
  // First fork: the parent returns the shell prompt; the child carries on.
  pid := FpFork;
  if pid < 0 then
    Exit;            // fork failed -- stay in the foreground rather than abort
  if pid > 0 then
    Halt(0);         // parent process exits

  // New session: detach from the controlling terminal.
  FpSetSid;

  // Second fork so we are not a session leader and can never reacquire a tty.
  pid := FpFork;
  if pid < 0 then
    Exit;
  if pid > 0 then
    Halt(0);

  // Point stdio at /dev/null: the terminal is gone, so writes to it would
  // otherwise fail (and could raise SIGPIPE). The app logs to its data dir.
  fd := FpOpen('/dev/null', O_RDWR, 0);
  if fd >= 0 then
  begin
    FpDup2(fd, 0);
    FpDup2(fd, 1);
    FpDup2(fd, 2);
    if fd > 2 then
      FpClose(fd);
  end;
end;
{$ELSE}

procedure Daemonize;
begin
  // Windows: a GUI-subsystem app launched from a console is already detached.
end;
{$ENDIF}

{$IFDEF UNIX}
function ProcIsGotbox(APid: LongInt): Boolean;
var
  comm: string;
  sl: TStringList;
begin
  Result := True;   // if we can't tell (no /proc), assume the live pid is ours
  comm := '/proc/' + IntToStr(APid) + '/comm';
  if FileExists(comm) then
  begin
    sl := TStringList.Create;
    try
      sl.LoadFromFile(comm);
      // matches both "gotbox" (GUI) and "gotboxd" (headless) so they exclude
      // each other -- two syncers on one root would fight
      Result := Pos('gotbox', LowerCase(sl.Text)) > 0;
    finally
      sl.Free;
    end;
  end;
end;

function AlreadyRunning: Boolean;
var
  pidfile: string;
  oldpid: LongInt;
  sl: TStringList;
begin
  Result := False;
  pidfile := IncludeTrailingPathDelimiter(GotConfigDir) + 'gotbox.pid';
  if FileExists(pidfile) then
  begin
    sl := TStringList.Create;
    try
      sl.LoadFromFile(pidfile);
      oldpid := StrToIntDef(Trim(sl.Text), 0);
    finally
      sl.Free;
    end;
    // a live process (signal 0 == existence check) that is actually GotBox
    if (oldpid > 0) and (oldpid <> FpGetpid) and (FpKill(oldpid, 0) = 0) and
      ProcIsGotbox(oldpid) then
      Exit(True);
  end;
  // record our pid (overwrites a stale file from a crashed instance)
  sl := TStringList.Create;
  try
    sl.Text := IntToStr(FpGetpid);
    sl.SaveToFile(pidfile);
  finally
    sl.Free;
  end;
end;
{$ENDIF}

{$IFDEF WINDOWS}
var
  GInstanceMutex: THandle = 0;

function AlreadyRunning: Boolean;
begin
  GInstanceMutex := CreateMutex(nil, True, 'GotBox-SingleInstance');
  Result := (GInstanceMutex <> 0) and (GetLastError = ERROR_ALREADY_EXISTS);
end;
{$ENDIF}

end.
