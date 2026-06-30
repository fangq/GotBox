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
  {$IFDEF WINDOWS}
  Windows,
  {$ENDIF}
  gboxconfigstore,
  gboxdaemon,
  gboxmsg,
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

  {$IFDEF WINDOWS}
var
  GInstanceMutex: THandle = 0;

  { Windows single-instance guard: hold a per-session named mutex for the
    process lifetime (the handle is intentionally never closed). If the mutex
    already exists, another GotBox is running. }
function AlreadyRunning: Boolean;
begin
  GInstanceMutex := CreateMutex(nil, True, 'GotBox-SingleInstance');
  Result := (GInstanceMutex <> 0) and (GetLastError = ERROR_ALREADY_EXISTS);
end;
  {$ENDIF}

begin
  if WantHelp then
  begin
    writeln(UsageText);
    Halt(0);
  end;
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
