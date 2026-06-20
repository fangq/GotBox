unit gboxconfig;

{ Settings window: root directory, history cap, sync intervals, machine name,
  and ignore patterns. Edits a TGotConfig in place; returns True if accepted. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Spin, Dialogs,
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
    if MessageDlg('Root folder does not exist. Create it?', mtConfirmation,
      [mbYes, mbNo], 0) = mrYes then
      ForceDirectories(eRoot.Text)
    else
      Exit;
  end;
  ModalResult := mrOK;
end;

function TConfigForm.Edit(ACfg: TGotConfig): Boolean;
begin
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
