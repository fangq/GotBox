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
{ Help/usage text for --help. }
function UsageText: string;

{ Detach from the controlling terminal and run in the background (Unix/macOS).
  No-op on Windows. MUST be called at program start -- before the widgetset is
  initialized and before any worker threads are created -- because it forks. }
procedure Daemonize;

implementation

uses
  SysUtils
  {$IFDEF UNIX}, BaseUnix, ctypes{$ENDIF};

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

function UsageText: string;
begin
  Result :=
    'GotBox -- Dropbox-like file sync over GitHub private repos' +
    LineEnding + LineEnding + 'Usage: gotbox [options]' + LineEnding +
    LineEnding + 'Options:' + LineEnding +
    '  -d, --daemon   detach from the terminal and run in the background' +
    LineEnding + '  -h, --help     show this help and exit' + LineEnding;
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

end.
