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
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  gboxconfigstore,
  gboxmain,
  gboxlogin,
  gboxconfig,
  gboxstatus,
  gboxlinksub;

  {$R *.res}

 { Single-instance guard: a tray app should run once per user, otherwise every
  launch stacks another tray icon. Record our pid in the config dir; if a live
  GotBox process is already recorded, this launch bows out. }
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

 { Manual HiDPI override. Application.Scaled honours the monitor PPI that the
  widgetset reports, but gtk2 does not pick up some desktop scale settings (e.g.
  xfce's "window scaling"), leaving the app tiny on HiDPI screens. Setting
  GOTBOX_SCALE (or GDK_SCALE) to e.g. 2 scales every form explicitly. }
  procedure ApplyManualScale;
  var
    s: string;
    fs: TFormatSettings;
    factor: Double;
    i: Integer;
    f: TCustomForm;
  begin
    s := GetEnvironmentVariable('GOTBOX_SCALE');
    if s = '' then
      s := GetEnvironmentVariable('GDK_SCALE');
    if s = '' then
      Exit;
    fs := DefaultFormatSettings;
    fs.DecimalSeparator := '.';
    factor := StrToFloatDef(StringReplace(s, ',', '.', []), 1.0, fs);
    if factor <= 1.0 then
      Exit;
    for i := 0 to Screen.CustomFormCount - 1 do
    begin
      f := Screen.CustomForms[i];
      try
        f.AutoAdjustLayout(lapAutoAdjustForDPI, 96, Round(96 * factor),
          f.Width, Round(f.Width * factor));
      except
        // never let cosmetic scaling abort startup
      end;
    end;
  end;

begin
  {$IFDEF UNIX}
  if AlreadyRunning then
  begin
    WriteLn('GotBox is already running.');
    Halt(0);
  end;
  {$ENDIF}
  RequireDerivedFormResource := True;
  Application.Title := 'GotBox';
  Application.Scaled := True;
  Application.Initialize;
  // tray-only app: never show the hidden main (tray-host) form
  Application.ShowMainForm := False;
  Application.CreateForm(TMainForm, MainForm);
  Application.CreateForm(TLoginForm, LoginForm);
  Application.CreateForm(TConfigForm, ConfigForm);
  Application.CreateForm(TStatusForm, StatusForm);
  Application.CreateForm(TLinkSubForm, LinkSubForm);
  ApplyManualScale;
  Application.Run;
end.
