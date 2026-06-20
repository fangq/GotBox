unit gboxmain;

{ Hidden main controller form. Owns the system-tray icon and its popup menu,
  holds the global config/status objects, and opens the Login/Config/Status
  windows on demand. The app has no visible main window -- it lives in the tray. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Menus, ExtCtrls, Dialogs,
  LCLType, LCLIntf, gboxconfigstore, gboxstatusmodel, gboxlog,
  gboxcredstore, gboxrepolink, gboxengine;

type
  TMainForm = class(TForm)
    TrayIcon: TTrayIcon;
    TrayMenu: TPopupMenu;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure TrayIconDblClick(Sender: TObject);
  private
    FConfig: TGotConfig;
    FStore: TConfigStore;
    FStatus: TStatusModel;
    FEngine: TSyncEngine;
    procedure BuildTrayMenu;
    procedure UpdateTrayState;
    procedure StatusModelChanged;
    procedure StartEngine;
    procedure StopEngine;
    // menu handlers
    procedure mnuOpenRoot(Sender: TObject);
    procedure mnuScanLink(Sender: TObject);
    procedure mnuSyncNow(Sender: TObject);
    procedure mnuStatus(Sender: TObject);
    procedure mnuSettings(Sender: TObject);
    procedure mnuAccount(Sender: TObject);
    procedure mnuQuit(Sender: TObject);
  public
    property Config: TGotConfig read FConfig;
    property Status: TStatusModel read FStatus;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

uses
  gboxconfig, gboxlogin, gboxstatus;

procedure TMainForm.FormCreate(Sender: TObject);
begin
  // start hidden; this form is just the tray host
  BorderStyle := bsNone;
  ShowInTaskBar := stNever;

  InitLogger(IncludeTrailingPathDelimiter(GotDataDir) + 'gotbox.log');
  Log.Info('app', 'GotBox starting');

  FStore := TConfigStore.Create(IncludeTrailingPathDelimiter(GotConfigDir) +
    'config.json');
  FConfig := FStore.Load;

  FStatus := TStatusModel.Create;
  FStatus.OnChanged := @StatusModelChanged;

  BuildTrayMenu;
  TrayIcon.PopUpMenu := TrayMenu;
  TrayIcon.Hint := 'GotBox';
  TrayIcon.Visible := True;
  UpdateTrayState;

  StartEngine;   // begin syncing already-linked repos, if any
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  if Assigned(Log) then Log.Info('app', 'GotBox stopping');
  StopEngine;        // stop worker threads before freeing the status model
  FStatus.Free;
  FConfig.Free;
  FStore.Free;
  DoneLogger;
end;

procedure TMainForm.BuildTrayMenu;

  function AddItem(const ACaption: string; AHandler: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(TrayMenu);
    Result.Caption := ACaption;
    Result.OnClick := AHandler;
    TrayMenu.Items.Add(Result);
  end;

  procedure AddSep;
  var
    it: TMenuItem;
  begin
    it := TMenuItem.Create(TrayMenu);
    it.Caption := '-';
    TrayMenu.Items.Add(it);
  end;

begin
  AddItem('Open root folder', @mnuOpenRoot);
  AddItem('Scan && link folders', @mnuScanLink);
  AddItem('Sync now', @mnuSyncNow);
  AddSep;
  AddItem('Status...', @mnuStatus);
  AddItem('Settings...', @mnuSettings);
  AddItem('Account...', @mnuAccount);
  AddSep;
  AddItem('Quit', @mnuQuit);
end;

procedure TMainForm.UpdateTrayState;
begin
  // M1: a single icon; later this swaps per AggregateState colour.
  case FStatus.AggregateState of
    rsError: TrayIcon.Hint := 'GotBox - error';
    rsConflict: TrayIcon.Hint := 'GotBox - conflict';
    rsSyncing: TrayIcon.Hint := 'GotBox - syncing';
    else
      TrayIcon.Hint := 'GotBox - synced';
  end;
end;

procedure TMainForm.StatusModelChanged;
begin
  // Called possibly from worker threads; marshal to the GUI thread.
  TThread.Queue(nil, @UpdateTrayState);
end;

procedure TMainForm.StartEngine;
var
  cred: TCredStore;
  token: string;
begin
  StopEngine;
  if (FConfig.RootDir = '') or (FConfig.GithubUser = '') or
    (Length(FConfig.Repos) = 0) then
    Exit;

  cred := TCredStore.Create;
  try
    if not cred.LoadToken(FConfig.GithubUser, token) then
    begin
      if Assigned(Log) then Log.Warn('engine', 'no stored token; sync not started');
      Exit;
    end;
  finally
    cred.Free;
  end;

  FEngine := TSyncEngine.Create(FConfig, token, FStatus);
  FEngine.Start;
end;

procedure TMainForm.StopEngine;
begin
  if Assigned(FEngine) then
    FreeAndNil(FEngine);   // TSyncEngine.Destroy stops + joins the workers
end;

procedure TMainForm.TrayIconDblClick(Sender: TObject);
begin
  mnuStatus(Sender);
end;

procedure TMainForm.mnuOpenRoot(Sender: TObject);
begin
  if (FConfig.RootDir <> '') and DirectoryExists(FConfig.RootDir) then
    OpenDocument(FConfig.RootDir)
  else
    ShowMessage('No root folder configured yet. Open Settings to choose one.');
end;

procedure TMainForm.mnuScanLink(Sender: TObject);
var
  cred: TCredStore;
  token, msg: string;
  linker: TRepoLinker;
  res: TLinkResultArray;
  i, nOk, nErr: Integer;
begin
  if (FConfig.RootDir = '') or not DirectoryExists(FConfig.RootDir) then
  begin
    ShowMessage('Set a valid root folder in Settings first.');
    Exit;
  end;
  if FConfig.GithubUser = '' then
  begin
    ShowMessage('Sign in with the Account window first.');
    Exit;
  end;

  cred := TCredStore.Create;
  try
    if not cred.LoadToken(FConfig.GithubUser, token) then
    begin
      ShowMessage('No stored token found. Use Account to sign in again.');
      Exit;
    end;
  finally
    cred.Free;
  end;

  // Blocking scan (talks to GitHub). Acceptable for a manual action; the
  // continuous sync engine (milestone 5) will move this onto worker threads.
  Screen.Cursor := crHourGlass;
  try
    linker := TRepoLinker.Create(FConfig, token, FStatus);
    try
      res := linker.ScanAndLink;
    finally
      linker.Free;
    end;
  finally
    Screen.Cursor := crDefault;
  end;

  FStore.Save(FConfig);
  nOk := 0;
  nErr := 0;
  for i := 0 to High(res) do
    if res[i].Action = laError then Inc(nErr)
    else
      Inc(nOk);
  msg := Format('Linked %d folder(s), %d error(s).', [nOk, nErr]);
  Log.Info('link', msg);

  StartEngine;   // (re)start sync to pick up newly linked repos
  ShowMessage(msg);
end;

procedure TMainForm.mnuSyncNow(Sender: TObject);
begin
  if Assigned(FEngine) and FEngine.Running then
  begin
    FEngine.SyncAllNow;
    Log.Info('ui', 'Sync now requested');
  end
  else
    ShowMessage('Nothing is being synced yet. Use "Scan && link folders" first.');
end;

procedure TMainForm.mnuStatus(Sender: TObject);
begin
  StatusForm.Bind(FStatus);
  StatusForm.Show;
  StatusForm.BringToFront;
end;

procedure TMainForm.mnuSettings(Sender: TObject);
begin
  if ConfigForm.Edit(FConfig) then
  begin
    FStore.Save(FConfig);
    Log.Info('ui', 'Settings saved');
  end;
end;

procedure TMainForm.mnuAccount(Sender: TObject);
begin
  if LoginForm.RunLogin(FConfig) then
  begin
    FStore.Save(FConfig);
    Log.Info('ui', 'Account updated for user ' + FConfig.GithubUser);
  end;
end;

procedure TMainForm.mnuQuit(Sender: TObject);
begin
  Application.Terminate;
end;

end.
