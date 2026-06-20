program gotbox;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // LCL widgetset
  Forms,
  gboxmain,
  gboxlogin,
  gboxconfig,
  gboxstatus,
  gboxlinksub;

  {$R *.res}

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
  Application.Run;
end.
