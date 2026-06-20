unit gboxmsg;

{ Small UI helpers so dialogs reliably appear centered and focused. The default
  LCL ShowMessage/MessageDlg position relative to the (hidden, top-left) main
  form, so they land in the corner; these create the dialog explicitly and
  center it on the primary monitor's work area. CenterForm does the same for the
  app's own modal/visible forms (poScreenCenter is unreliable on some WMs). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Dialogs;

{ Center AForm on the primary monitor work area (call before Show/ShowModal). }
procedure CenterForm(AForm: TCustomForm);

{ Centered, focused, stay-on-top message dialogs. }
procedure MsgInfo(const AMsg: string);
procedure MsgError(const AMsg: string);
function MsgConfirm(const AMsg: string): Boolean;

implementation

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
