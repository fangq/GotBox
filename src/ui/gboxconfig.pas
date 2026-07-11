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

unit gboxconfig;

{ Settings window: root directory, history cap, sync intervals, machine name,
  and ignore patterns. Edits a TGotConfig in place; returns True if accepted. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Spin, Dialogs, gboxmsg,
  gboxconfigstore;

type
  TConfigForm = class(TForm)
    lblRoot: TLabel;
    eRoot: TEdit;
    btnBrowse: TButton;
    lblKind: TLabel;
    cboKind: TComboBox;
    lblSsh: TLabel;
    eSshBase: TEdit;
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
    procedure btnBrowseClick(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
  public
    function Edit(ACfg: TGotConfig): Boolean;
  end;

var
  ConfigForm: TConfigForm;

implementation

{$R *.lfm}

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
  if SameText(ACfg.RemoteKind, 'git') then cboKind.ItemIndex := 1
  else
    cboKind.ItemIndex := 0;
  eSshBase.Text := ACfg.SshBase;
  eMachine.Text := ACfg.MachineName;
  seCap.Value := ACfg.HistoryCap;
  seDebounce.Value := ACfg.CommitDebounceMs;
  sePull.Value := ACfg.PullIntervalSec;
  seGc.Value := ACfg.GcEveryNCommits;
  mIgnore.Lines.Assign(ACfg.IgnoreGlobs);

  CenterForm(Self);
  Result := ShowModal = mrOK;
  if not Result then Exit;

  ACfg.RootDir := eRoot.Text;
  if cboKind.ItemIndex = 1 then ACfg.RemoteKind := 'git'
  else
    ACfg.RemoteKind := 'github';
  ACfg.SshBase := Trim(eSshBase.Text);
  ACfg.MachineName := Trim(eMachine.Text);
  ACfg.HistoryCap := seCap.Value;
  ACfg.CommitDebounceMs := seDebounce.Value;
  ACfg.PullIntervalSec := sePull.Value;
  ACfg.GcEveryNCommits := seGc.Value;
  ACfg.IgnoreGlobs.Assign(mIgnore.Lines);
end;

end.
