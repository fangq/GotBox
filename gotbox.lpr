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

program gotbox;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // LCL widgetset
  Forms,
  Controls,
  Classes,
  SysUtils,
  gboxdaemon,
  gboxmsg,
  gboxmain,
  gboxlogin,
  gboxconfig,
  gboxstatus,
  gboxlinksub;

  {$R *.res}

var
  ovlExit: Integer;
begin
  if WantHelp then
  begin
    writeln(UsageText);
    Halt(0);
  end;
  // --status: ask the already-running GotBox to open its Status window (for
  // when the tray menu can't be popped, e.g. over x2go/NX). Never starts the app.
  if WantShowStatus then
  begin
    {$IFDEF UNIX}
    if SendShowStatus then
      WriteLn('Asked the running GotBox to open its Status window.')
    else
      WriteLn('GotBox does not appear to be running.');
    {$ELSE}
    WriteLn('--status is only supported on Unix.');
    {$ENDIF}
    Halt(0);
  end;
  // Explorer icon-overlay (un)registration: self-elevates and exits, never
  // starting the tray app. No-op unless --(un)register-overlays was passed.
  if HandleOverlayRegistration(ovlExit) then
    Halt(ovlExit);
  // Over an x2go/NX session, re-exec with LAZUSEAPPIND=NO so LCL uses the classic
  // XEmbed systray (the AppIndicator tray is unusable there). Must run before the
  // widgetset comes up; no-op off x2go. See MaybeReExecForX2Go.
  MaybeReExecForX2Go;
  // Detach into the background before the widgetset/threads come up (no-op
  // without -d, and on Windows). Forking later would be unsafe.
  if WantDaemon then
    Daemonize;

  // single-instance guard -- after any daemon fork, so it records the
  // persistent (child) process, not a parent that exits right after forking
  if AlreadyRunning then
  begin
    {$IFDEF UNIX}
    WriteLn('GotBox is already running.');   // no console on a Windows GUI app
    {$ENDIF}
    Halt(0);
  end;

  RequireDerivedFormResource := True;
  Application.Title := 'GotBox';
  {$IFDEF LINUX}
  // gtk2 caps Application.Scaled at the Xft DPI and reverts manual bumps on
  // Show, so it can't honour xfce's integer window-scaling factor. Leave LCL
  // auto-scaling off and scale forms ourselves (ApplyAdaptiveScale, below).
  Application.Scaled := False;
  {$ELSE}
  // Windows/macOS report true (per-monitor) DPI; LCL scaling is correct here.
  Application.Scaled := True;
  {$ENDIF}
  Application.Initialize;
  // tray-only app: never show the hidden main (tray-host) form
  Application.ShowMainForm := False;
  Application.CreateForm(TMainForm, MainForm);
  Application.CreateForm(TLoginForm, LoginForm);
  Application.CreateForm(TConfigForm, ConfigForm);
  Application.CreateForm(TStatusForm, StatusForm);
  Application.CreateForm(TLinkSubForm, LinkSubForm);
  ApplyAdaptiveScale;   // scale existing forms to the target DPI (Linux/gtk2)
  Application.Run;
end.
