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

unit gboxmsg;

{ Small UI helpers so dialogs reliably appear centered and focused. The default
  LCL ShowMessage/MessageDlg position relative to the (hidden, top-left) main
  form, so they land in the corner; these create the dialog explicitly and
  center it on the primary monitor's work area. CenterForm does the same for the
  app's own modal/visible forms (poScreenCenter is unreliable on some WMs). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Dialogs, Process;

{ Show a transient desktop notification (a bubble in the OS notification area)
  via the native notifier: notify-send on Linux, osascript on macOS. Returns
  False if no notifier is available (caller may fall back to a tray balloon).
  Avoids LCL's gtk2 tray-balloon, which renders top-left and emits Gtk-CRITICAL. }
function DesktopNotify(const ATitle, AMsg: string): Boolean;

{ Adaptive HiDPI scaling. On gtk2, Application.Scaled caps at the Xft DPI and
  will not honour the desktop's integer window-scaling factor (it even reverts a
  manual bump on Show), so on Linux we scale forms ourselves to
  Xft.dpi * WindowScalingFactor -- matching what gtk3 apps render at, so geometry
  and fonts grow together. GOTBOX_SCALE / GDK_SCALE (a factor vs 96) override the
  target. Each is a no-op when the target equals the form's current PPI (e.g.
  Windows/macOS, where Application.Scaled already scaled it). }
procedure ScaleFormUp(AForm: TCustomForm);
{ Scale every form that currently exists to the desktop's target DPI; call once
  at startup (after the forms are created). }
procedure ApplyAdaptiveScale;
{ Re-read the desktop scale and, if it changed, re-scale every open form (and
  re-center the visible ones). Call periodically (e.g. from a timer) for live
  response to desktop scaling changes. Returns True if a change was applied. }
function RefreshScale: Boolean;

{ Center AForm on the primary monitor work area (call before Show/ShowModal). }
procedure CenterForm(AForm: TCustomForm);

{ Centered, focused, stay-on-top message dialogs. }
procedure MsgInfo(const AMsg: string);
procedure MsgError(const AMsg: string);
function MsgConfirm(const AMsg: string): Boolean;

implementation

{ Run a short-lived command, waiting for it; True if it launched and exited 0. }
function RunQuiet(const AExe: string; const AArgs: array of string): Boolean;
var
  p: TProcess;
  i: Integer;
begin
  Result := False;
  if FileSearch(AExe, GetEnvironmentVariable('PATH')) = '' then Exit;
  p := TProcess.Create(nil);
  try
    p.Executable := AExe;
    for i := 0 to High(AArgs) do p.Parameters.Add(AArgs[i]);
    p.Options := [poNoConsole, poWaitOnExit];
    try
      p.Execute;
      Result := p.ExitStatus = 0;
    except
      Result := False;
    end;
  finally
    p.Free;
  end;
end;

function DesktopNotify(const ATitle, AMsg: string): Boolean;
  {$IFDEF DARWIN}
var
  body, title: string;
  {$ENDIF}
begin
  {$IFDEF LINUX}
  // args passed separately, so quotes/specials in the text are safe
  Result := RunQuiet('notify-send', ['-a', 'GotBox', ATitle, AMsg]);
  {$ELSE}
  {$IFDEF DARWIN}
  body := StringReplace(AMsg, '"', '''', [rfReplaceAll]);
  title := StringReplace(ATitle, '"', '''', [rfReplaceAll]);
  Result := RunQuiet('osascript', ['-e',
    'display notification "' + body + '" with title "' + title + '"']);
  {$ELSE}
  Result := False;   // Windows: caller falls back to the tray balloon
  {$ENDIF}
  {$ENDIF}
end;

{ The desktop's integer window-scaling factor (xfce's Gdk/WindowScalingFactor),
  or 0 if unknown. gtk2 ignores it, so we read it ourselves to match other apps. }
function DesktopWindowScalingFactor: Integer;
{$IFDEF LINUX}
var
  outp: string;
begin
  Result := 0;
  outp := '';
  try
    if RunCommand('xfconf-query',
      ['-c', 'xsettings', '-p', '/Gdk/WindowScalingFactor'], outp) then
      Result := StrToIntDef(Trim(outp), 0);
  except
    Result := 0;   // xfconf-query missing or no xsettings channel
  end;
end;
{$ELSE}
begin
  Result := 0;
end;
{$ENDIF}

var
  GAppliedPPI: Integer = 0;   // the PPI all forms are currently scaled to

{ The DPI we want forms scaled to right now: an explicit GOTBOX_SCALE/GDK_SCALE
  override (a factor vs 96), else the widgetset's reported DPI multiplied by the
  desktop integer window-scaling factor. Recomputed on every call (no caching)
  so live refresh picks up changes. }
function DesiredPPI: Integer;
var
  s: string;
  fs: TFormatSettings;
  factor: Double;
  wsf: Integer;
begin
  // explicit override: GOTBOX_SCALE / GDK_SCALE as a factor relative to 96
  s := GetEnvironmentVariable('GOTBOX_SCALE');
  if s = '' then
    s := GetEnvironmentVariable('GDK_SCALE');
  if s <> '' then
  begin
    fs := DefaultFormatSettings;
    fs.DecimalSeparator := '.';
    factor := StrToFloatDef(StringReplace(s, ',', '.', []), 0, fs);
    if factor > 0 then
      Exit(Round(96 * factor));
  end;

  // baseline: the DPI the widgetset reports (Xft.dpi on gtk2). gtk2 renders
  // fonts at this DPI but designs forms at 96, so scaling to just this leaves
  // fonts lagging the geometry; multiply by the desktop's integer window-
  // scaling factor so geometry AND fonts scale uniformly and match other apps
  // (gtk3 renders at WindowScalingFactor * Xft.dpi).
  Result := Screen.PixelsPerInch;
  wsf := DesktopWindowScalingFactor;
  if wsf >= 2 then
    Result := Result * wsf;
end;

{ Scale one form from its current PPI to ATargetPPI (handles either direction). }
procedure ScaleFormTo(AForm: TCustomForm; ATargetPPI: Integer);
var
  cur: Integer;
begin
  if (AForm = nil) or (ATargetPPI <= 0) then
    Exit;
  cur := AForm.PixelsPerInch;
  if cur <= 0 then
    cur := 96;
  if ATargetPPI <> cur then
    AForm.AutoAdjustLayout(lapAutoAdjustForDPI, cur, ATargetPPI,
      AForm.Width, Round(AForm.Width * ATargetPPI / cur));
end;

procedure ScaleFormUp(AForm: TCustomForm);
var
  tgt: Integer;
begin
  tgt := GAppliedPPI;       // match whatever the open windows are at
  if tgt <= 0 then
    tgt := DesiredPPI;
  ScaleFormTo(AForm, tgt);
end;

{ Scale every existing form to ATargetPPI, re-centering the visible ones, and
  record it as the applied target. }
procedure ApplyScaleAll(ATargetPPI: Integer);
var
  i: Integer;
  f: TCustomForm;
begin
  for i := 0 to Screen.CustomFormCount - 1 do
  begin
    f := Screen.CustomForms[i];
    try
      ScaleFormTo(f, ATargetPPI);
      // keep an open window centered after it changes size (skip the hidden
      // tray-host main form)
      if f.Visible and (f <> Application.MainForm) then
        CenterForm(f);
    except
      // never let cosmetic scaling crash the app
    end;
  end;
  GAppliedPPI := ATargetPPI;
end;

procedure ApplyAdaptiveScale;
begin
  ApplyScaleAll(DesiredPPI);
end;

function RefreshScale: Boolean;
var
  d: Integer;
begin
  d := DesiredPPI;
  Result := (d > 0) and (d <> GAppliedPPI);
  if Result then
    ApplyScaleAll(d);
end;

procedure CenterForm(AForm: TCustomForm);
begin
  AForm.Position := poDesigned;   // we set Left/Top ourselves
  AForm.Left := Screen.WorkAreaLeft + (Screen.WorkAreaWidth - AForm.Width) div 2;
  AForm.Top := Screen.WorkAreaTop + (Screen.WorkAreaHeight - AForm.Height) div 2;
end;

function ShowCentered(const AMsg: string; AType: TMsgDlgType;
  AButtons: TMsgDlgButtons): TModalResult;
var
  dlg: TForm;
begin
  dlg := CreateMessageDialog(AMsg, AType, AButtons);
  try
    ScaleFormUp(dlg);   // dialogs are built in code, so scale them explicitly
    CenterForm(dlg);
    dlg.FormStyle := fsSystemStayOnTop;   // surface above other windows + focus
    Result := dlg.ShowModal;
  finally
    dlg.Free;
  end;
end;

procedure MsgInfo(const AMsg: string);
begin
  ShowCentered(AMsg, mtInformation, [mbOK]);
end;

procedure MsgError(const AMsg: string);
begin
  ShowCentered(AMsg, mtError, [mbOK]);
end;

function MsgConfirm(const AMsg: string): Boolean;
begin
  Result := ShowCentered(AMsg, mtConfirmation, [mbYes, mbNo]) = mrYes;
end;

end.
