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
    btnOK: TButton;
    btnCancel: TButton;
    procedure rbModeChange(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
  private
    procedure SyncEnabled;
  public
    LocalName: string;
    CreateUpstream: Boolean;
    UpstreamName: string;
    ExistingUrl: string;
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

procedure TLinkSubForm.btnOKClick(Sender: TObject);
begin
  if Trim(eName.Text) = '' then
  begin
    MsgInfo('Enter a local name for the submodule folder.');
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
  eName.Text := '';
  eUpstream.Text := '';
  eUrl.Text := '';
  rbCreate.Checked := True;
  SyncEnabled;

  CenterForm(Self);
  Result := ShowModal = mrOK;
  if not Result then Exit;

  LocalName := Trim(eName.Text);
  CreateUpstream := rbCreate.Checked;
  ExistingUrl := Trim(eUrl.Text);
  UpstreamName := Trim(eUpstream.Text);
  if CreateUpstream and (UpstreamName = '') then
    UpstreamName := LocalName;   // default the repo name to the local name
end;

end.
