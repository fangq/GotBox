program gotboxd;

{ Headless GotBox daemon: runs the sync engine with no GUI/tray and no LCL
  widgetset, so it needs no X server -- suitable for servers or plain SSH
  sessions. The GUI build (gotbox) still provides the tray; this binary is the
  no-display counterpart. Both share the single-instance guard, so only one of
  them syncs a given root at a time.

  Usage: gotboxd [-d]     (-d detaches into the background) }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  gboxdaemon,
  gboxheadless;

begin
  if WantHelp then
  begin
    writeln(UsageText);
    Halt(0);
  end;

  // detach before any worker threads start (Daemonize forks)
  if WantDaemon then
    Daemonize;

  // after any fork, so the guard records the persistent child pid
  if AlreadyRunning then
  begin
    writeln('GotBox is already running.');
    Halt(0);
  end;

  Halt(RunHeadless);
end.
