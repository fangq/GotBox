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
