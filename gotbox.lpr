program gotbox;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // LCL widgetset
  Forms,
  Controls,
  SysUtils,
  gboxmain,
  gboxlogin,
  gboxconfig,
  gboxstatus,
  gboxlinksub;

  {$R *.res}

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
