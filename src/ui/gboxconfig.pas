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

unit gboxconfig;

{ Settings window: root directory, history cap, sync intervals, machine name,
  and ignore patterns. Edits a TGotConfig in place; returns True if accepted. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Spin, Dialogs, gboxmsg,
  gboxremote, gboxconfigstore;

type
  TConfigForm = class(TForm)
    lblRoot: TLabel;
    eRoot: TEdit;
    btnBrowse: TButton;
    lblKind: TLabel;
    lblBackend: TLabel;
    btnAccount: TButton;
    lblTray: TLabel;
    cbTray: TComboBox;
    lblTrayNote: TLabel;
    lblMachine: TLabel;
    eMachine: TEdit;
    lblCap: TLabel;
    seCap: TSpinEdit;
    lblDebounce: TLabel;
    seDebounce: TSpinEdit;
    lblPull: TLabel;
    sePull: TSpinEdit;
    lblGc: TLabel;
    seGc: TSpinEdit;
    lblIgnore: TLabel;
    mIgnore: TMemo;
    btnOK: TButton;
    btnCancel: TButton;
    procedure btnAccountClick(Sender: TObject);
    procedure btnBrowseClick(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
  private
    FCfg: TGotConfig;             // the config being edited (for the summary)
    FOnAccount: TNotifyEvent;
  public
    function Edit(ACfg: TGotConfig): Boolean;
    { Raised by "Change..."; the main form opens the Account window. Settings
      does not reach into LoginForm itself, mirroring TStatusForm.OnAccount. }
    property OnAccount: TNotifyEvent read FOnAccount write FOnAccount;
  end;

var
  ConfigForm: TConfigForm;

implementation

{$R *.lfm}

const
  { cbTray item order -> TGotConfig.TrayStyle }
  TRAY_STYLES: array[0..2] of string = (TRAY_AUTO, TRAY_APPIND, TRAY_CLASSIC);

function TrayStyleIndex(const AStyle: string): Integer;
var
  i: Integer;
begin
  for i := Low(TRAY_STYLES) to High(TRAY_STYLES) do
    if TRAY_STYLES[i] = NormalizeTrayStyle(AStyle) then Exit(i);
  Result := 0;
end;

procedure TConfigForm.btnAccountClick(Sender: TObject);
begin
  if not Assigned(FOnAccount) then Exit;
  FOnAccount(Self);                       // nested modal; the LCL handles it
  if Assigned(FCfg) then lblBackend.Caption := BackendSummary(FCfg);
end;

procedure TConfigForm.btnBrowseClick(Sender: TObject);
var
  dir: string;
begin
  dir := eRoot.Text;
  if SelectDirectory('Choose the GotBox root folder', dir, dir) then
    eRoot.Text := dir;
end;

procedure TConfigForm.btnOKClick(Sender: TObject);
begin
  if (eRoot.Text <> '') and not DirectoryExists(eRoot.Text) then
  begin
    if MsgConfirm('Root folder does not exist. Create it?') then
      ForceDirectories(eRoot.Text)
    else
      Exit;
  end;
  ModalResult := mrOK;
end;

function TConfigForm.Edit(ACfg: TGotConfig): Boolean;
begin
  Result := False;
  if Visible then begin
    BringToFront;
    Exit;
  end;   // already open; don't re-ShowModal
  eRoot.Text := ACfg.RootDir;
  FCfg := ACfg;
  lblBackend.Caption := BackendSummary(ACfg);
  eMachine.Text := ACfg.MachineName;
  seCap.Value := ACfg.HistoryCap;
  seDebounce.Value := ACfg.CommitDebounceMs;
  sePull.Value := ACfg.PullIntervalSec;
  seGc.Value := ACfg.GcEveryNCommits;
  mIgnore.Lines.Assign(ACfg.IgnoreGlobs);
  cbTray.ItemIndex := TrayStyleIndex(ACfg.TrayStyle);
  {$IFNDEF LINUX}
  // the app-indicator / XEmbed choice exists only on Linux
  lblTray.Visible := False;
  cbTray.Visible := False;
  lblTrayNote.Visible := False;
  {$ENDIF}

  CenterForm(Self);
  Result := ShowModal = mrOK;
  if not Result then Exit;

  ACfg.RootDir := eRoot.Text;
  // the backend itself is chosen in the Account window, not here
  ACfg.MachineName := Trim(eMachine.Text);
  ACfg.HistoryCap := seCap.Value;
  ACfg.CommitDebounceMs := seDebounce.Value;
  ACfg.PullIntervalSec := sePull.Value;
  ACfg.GcEveryNCommits := seGc.Value;
  ACfg.IgnoreGlobs.Assign(mIgnore.Lines);
  if cbTray.ItemIndex >= 0 then
    ACfg.TrayStyle := TRAY_STYLES[cbTray.ItemIndex];
end;

end.
