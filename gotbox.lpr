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
  gboxstatus;

  {$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'GotBox';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.CreateForm(TLoginForm, LoginForm);
  Application.CreateForm(TConfigForm, ConfigForm);
  Application.CreateForm(TStatusForm, StatusForm);
  Application.Run;
end.
