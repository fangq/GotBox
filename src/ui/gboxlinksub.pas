{
  GotBox -- Dropbox-like file sync over your own private git repositories.
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

unit gboxlinksub;

{ "Link submodule" dialog: choose a local name (the path under .gotbox) and the
  upstream source -- either create a new private repo (give its repo name) or use
  an existing repo URL. Returns the choices to the caller, which performs the
  git work via gboxsuper.AddSubmodule. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Dialogs, gboxmsg;

type
  TLinkSubForm = class(TForm)
    lblName: TLabel;
    eName: TEdit;
    rbCreate: TRadioButton;
    lblUpstream: TLabel;
    eUpstream: TEdit;
    rbExisting: TRadioButton;
    lblUrl: TLabel;
    eUrl: TEdit;
    chkAutoSync: TCheckBox;
    lblSyncHint: TLabel;
    btnOK: TButton;
    btnCancel: TButton;
    procedure rbModeChange(Sender: TObject);
    procedure chkAutoSyncChange(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
  private
    procedure SyncEnabled;
  public
    LocalName: string;
    CreateUpstream: Boolean;
    UpstreamName: string;
    ExistingUrl: string;
    { True = automatic sync (auto add/commit/trim, like the root); False =
      managed (default): GotBox only transports the user's own commits. }
    AutoSync: Boolean;
    { Shows the dialog; returns True if accepted with valid input. When the
      "create new" mode is chosen and the upstream name is left blank, it
      defaults to the local name. }
    function Run: Boolean;
  end;

var
  LinkSubForm: TLinkSubForm;

implementation

{$R *.lfm}

procedure TLinkSubForm.SyncEnabled;
begin
  eUpstream.Enabled := rbCreate.Checked;
  eUrl.Enabled := rbExisting.Checked;
end;

procedure TLinkSubForm.rbModeChange(Sender: TObject);
begin
  SyncEnabled;
end;

procedure TLinkSubForm.chkAutoSyncChange(Sender: TObject);
begin
  // warn (and require confirmation) only when turning automatic sync ON
  if chkAutoSync.Checked then
    if not MsgConfirm(
      'Automatic sync will auto-commit and push EVERY change in this folder as ' +
      'machine-stamped commits, stage any new/untracked files, and periodically ' +
      'squash (rewrite) its history to keep it small.' + LineEnding +
      LineEnding + 'This can contaminate or truncate a real project''s git history. Use '
      + 'Managed mode unless this folder is just a data drop.' +
      LineEnding + LineEnding + 'Enable automatic sync anyway?') then
      chkAutoSync.Checked := False;   // reverted -> stays managed
end;

procedure TLinkSubForm.btnOKClick(Sender: TObject);
begin
  if Trim(eName.Text) = '' then
  begin
    MsgInfo('Enter a local folder name or relative path for the submodule ' +
      '(e.g. "notes" or "projects/notes").');
    Exit;
  end;
  if rbExisting.Checked and (Trim(eUrl.Text) = '') then
  begin
    MsgInfo('Enter the existing repository URL.');
    Exit;
  end;
  ModalResult := mrOK;
end;

function TLinkSubForm.Run: Boolean;
begin
  Result := False;
  if Visible then begin
    BringToFront;
    Exit;
  end;
  eName.Text := '';
  eUpstream.Text := '';
  eUrl.Text := '';
  rbCreate.Checked := True;
  chkAutoSync.Checked := False;   // managed is the default
  SyncEnabled;

  CenterForm(Self);
  Result := ShowModal = mrOK;
  if not Result then Exit;

  LocalName := Trim(eName.Text);
  CreateUpstream := rbCreate.Checked;
  ExistingUrl := Trim(eUrl.Text);
  UpstreamName := Trim(eUpstream.Text);
  AutoSync := chkAutoSync.Checked;
  if CreateUpstream and (UpstreamName = '') then
    UpstreamName := LocalName;   // default the repo name to the local name
end;

end.
