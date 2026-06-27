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
{ Apply ScaleFormUp to every form that currently exists; call once at startup. }
procedure ApplyAdaptiveScale;

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
  GTargetPPI: Integer = -1;   // cached target DPI (computed once)

{ The DPI we want forms scaled to: an explicit GOTBOX_SCALE/GDK_SCALE override,
  else the larger of the widgetset's reported DPI and WindowScalingFactor*96. }
function TargetPPI: Integer;
var
  s: string;
  fs: TFormatSettings;
  factor: Double;
  wsf: Integer;
begin
  if GTargetPPI >= 0 then Exit(GTargetPPI);

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
    begin
      GTargetPPI := Round(96 * factor);
      Exit(GTargetPPI);
    end;
  end;

  // baseline: the DPI the widgetset reports (Xft.dpi on gtk2). gtk2 already
  // renders fonts at this DPI, but the forms are designed at 96, so scaling to
  // just this leaves fonts lagging the geometry.
  GTargetPPI := Screen.PixelsPerInch;
  // Multiply by the desktop's integer window-scaling factor so geometry AND
  // fonts scale uniformly and match other apps (gtk3 renders at
  // WindowScalingFactor * Xft.dpi); gtk2 ignores the factor, so we apply it.
  wsf := DesktopWindowScalingFactor;
  if wsf >= 2 then
    GTargetPPI := GTargetPPI * wsf;
  Result := GTargetPPI;
end;

procedure ScaleFormUp(AForm: TCustomForm);
var
  tgt, cur: Integer;
begin
  if AForm = nil then
    Exit;
  tgt := TargetPPI;
  cur := AForm.PixelsPerInch;
  if cur <= 0 then
    cur := 96;
  if tgt > cur then
    AForm.AutoAdjustLayout(lapAutoAdjustForDPI, cur, tgt,
      AForm.Width, Round(AForm.Width * tgt / cur));
end;

procedure ApplyAdaptiveScale;
var
  i: Integer;
begin
  if TargetPPI <= 96 then
    Exit;
  for i := 0 to Screen.CustomFormCount - 1 do
    try
      ScaleFormUp(Screen.CustomForms[i]);
    except
      // never let cosmetic scaling abort startup
    end;
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
