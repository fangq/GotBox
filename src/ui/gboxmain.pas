unit gboxmain;

{ Hidden main controller form. Owns the system-tray icon and its popup menu,
  holds the global config/status objects, and opens the Login/Config/Status
  windows on demand. The app has no visible main window -- it lives in the tray. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Menus, ExtCtrls, Dialogs,
  LCLType, LCLIntf, gboxconfigstore, gboxstatusmodel, gboxlog,
  gboxcredstore, gboxengine, gboxsuper;

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
    FLastAgg: TRepoState;
    FIcons: array[TRepoState] of TIcon;
    procedure BuildTrayMenu;
    procedure BuildIcons;
    procedure FreeIcons;
    procedure UpdateTrayState;
    procedure StatusModelChanged;
    procedure StartEngine;
    procedure StopEngine;
    function PrepareRemote(out AToken, AErr: string): Boolean;
    // status-window actions
    procedure HandleTogglePause(const ARepo: string);
    procedure HandleSyncRepo(const ARepo: string);
    procedure HandleOpenRepo(const ARepo: string);
    // menu handlers
    procedure mnuOpenRoot(Sender: TObject);
    procedure mnuLinkSub(Sender: TObject);
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
  gboxconfig, gboxlogin, gboxstatus, gboxlinksub;

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

  BuildIcons;
  BuildTrayMenu;
  TrayIcon.PopUpMenu := TrayMenu;
  TrayIcon.Hint := 'GotBox';
  TrayIcon.Visible := True;
  FLastAgg := rsIdle;
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
  FreeIcons;
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
  AddItem('Link submodule...', @mnuLinkSub);
  AddItem('Sync now', @mnuSyncNow);
  AddSep;
  AddItem('Status...', @mnuStatus);
  AddItem('Settings...', @mnuSettings);
  AddItem('Account...', @mnuAccount);
  AddSep;
  AddItem('Quit', @mnuQuit);
end;

procedure TMainForm.BuildIcons;

  function MakeDot(AColor: TColor): TIcon;
  var
    bmp: TBitmap;
  begin
    bmp := TBitmap.Create;
    try
      bmp.SetSize(16, 16);
      bmp.Canvas.Brush.Color := AColor;
      bmp.Canvas.FillRect(0, 0, 16, 16);
      bmp.Canvas.Brush.Style := bsClear;
      bmp.Canvas.Pen.Color := clBlack;
      bmp.Canvas.Rectangle(0, 0, 16, 16);
      Result := TIcon.Create;
      Result.Assign(bmp);
    finally
      bmp.Free;
    end;
  end;

begin
  FIcons[rsIdle] := MakeDot(RGBToColor(149, 165, 166));    // grey
  FIcons[rsSynced] := MakeDot(RGBToColor(46, 204, 113));   // green
  FIcons[rsSyncing] := MakeDot(RGBToColor(52, 152, 219));  // blue
  FIcons[rsConflict] := MakeDot(RGBToColor(243, 156, 18)); // amber
  FIcons[rsError] := MakeDot(RGBToColor(231, 76, 60));     // red
  FIcons[rsPaused] := MakeDot(RGBToColor(149, 165, 166));  // grey
end;

procedure TMainForm.FreeIcons;
var
  s: TRepoState;
begin
  for s := Low(TRepoState) to High(TRepoState) do
    FreeAndNil(FIcons[s]);
end;

procedure TMainForm.UpdateTrayState;
var
  agg: TRepoState;
begin
  agg := FStatus.AggregateState;
  case agg of
    rsError: TrayIcon.Hint := 'GotBox - error';
    rsConflict: TrayIcon.Hint := 'GotBox - conflict';
    rsSyncing: TrayIcon.Hint := 'GotBox - syncing';
    rsPaused: TrayIcon.Hint := 'GotBox - paused';
    else
      TrayIcon.Hint := 'GotBox - synced';
  end;

  // swap the tray icon colour to match the aggregate state
  if Assigned(FIcons[agg]) then
  begin
    TrayIcon.Icon := FIcons[agg];
    TrayIcon.InternalUpdate;
  end;

  // notify the user when we first enter a conflict/error state
  if (agg <> FLastAgg) and (agg in [rsConflict, rsError]) then
  begin
    if agg = rsConflict then
    begin
      TrayIcon.BalloonTitle := 'GotBox - conflict';
      TrayIcon.BalloonHint :=
        'A file changed on two machines. Both versions were kept; open Status to resolve.';
    end
    else
    begin
      TrayIcon.BalloonTitle := 'GotBox - sync error';
      TrayIcon.BalloonHint := 'A repo could not sync. Open Status for details.';
    end;
    TrayIcon.ShowBalloonHint;
  end;
  FLastAgg := agg;
end;

procedure TMainForm.StatusModelChanged;
begin
  // Called possibly from worker threads; marshal to the GUI thread.
  TThread.Queue(nil, @UpdateTrayState);
end;

{ Validates that the configured remote backend is usable and returns the auth
  token (empty for the ssh/self-hosted backend, which uses ssh keys). }
function TMainForm.PrepareRemote(out AToken, AErr: string): Boolean;
var
  cred: TCredStore;
begin
  AToken := '';
  AErr := '';
  Result := False;
  if (FConfig.RootDir = '') or not DirectoryExists(FConfig.RootDir) then
  begin
    AErr := 'Set a valid root folder in Settings first.';
    Exit;
  end;

  if SameText(FConfig.RemoteKind, 'git') then
  begin
    if FConfig.SshBase = '' then
    begin
      AErr := 'Set the self-hosted git base URL in Settings first.';
      Exit;
    end;
    Result := True;   // ssh key auth; no token needed
    Exit;
  end;

  // github backend
  if FConfig.GithubUser = '' then
  begin
    AErr := 'Sign in with the Account window first.';
    Exit;
  end;
  cred := TCredStore.Create;
  try
    if not cred.LoadToken(FConfig.GithubUser, AToken) then
    begin
      AErr := 'No stored token found. Use Account to sign in again.';
      Exit;
    end;
  finally
    cred.Free;
  end;
  Result := True;
end;

procedure TMainForm.StartEngine;
var
  token, err: string;
begin
  StopEngine;
  // only run once the .gotbox root has been set up locally
  if not IsGitWorkTree(FConfig.RootDir) then Exit;
  if not PrepareRemote(token, err) then
  begin
    if Assigned(Log) then Log.Warn('engine', 'sync not started: ' + err);
    Exit;
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

procedure TMainForm.mnuLinkSub(Sender: TObject);
var
  token, err, detail: string;
  ok: Boolean;
  entry: TRepoEntry;
begin
  if not PrepareRemote(token, err) then
  begin
    ShowMessage(err);
    Exit;
  end;

  // talks to the remote -- blocking, acceptable for a manual action
  Screen.Cursor := crHourGlass;
  try
    // ensure the .gotbox root exists (create the private repo on first use)
    if not IsGitWorkTree(FConfig.RootDir) then
      if not EnsureGotboxRoot(FConfig, token, detail) then
      begin
        Screen.Cursor := crDefault;
        ShowMessage('Could not set up the .gotbox root:' + LineEnding + detail);
        Exit;
      end;
  finally
    Screen.Cursor := crDefault;
  end;

  if not LinkSubForm.Run then Exit;   // user cancelled

  Screen.Cursor := crHourGlass;
  try
    ok := AddSubmodule(FConfig, token, LinkSubForm.LocalName,
      LinkSubForm.UpstreamName, LinkSubForm.ExistingUrl,
      LinkSubForm.CreateUpstream, detail);
  finally
    Screen.Cursor := crDefault;
  end;

  if not ok then
  begin
    ShowMessage('Link failed:' + LineEnding + detail);
    Exit;
  end;

  // record the new submodule in config (for the per-submodule Paused flag)
  entry.LocalName := LinkSubForm.LocalName;
  entry.RemoteUrl := '';
  entry.Paused := False;
  FConfig.UpsertRepo(entry);
  FStore.Save(FConfig);

  StartEngine;   // (re)start sync to pick up the new submodule
  ShowMessage('Linked submodule "' + LinkSubForm.LocalName + '".');
end;

procedure TMainForm.mnuSyncNow(Sender: TObject);
begin
  if Assigned(FEngine) and FEngine.Running then
  begin
    FEngine.SyncAllNow;
    Log.Info('ui', 'Sync now requested');
  end
  else
    ShowMessage('Nothing is being synced yet. Use "Link submodule..." first.');
end;

procedure TMainForm.mnuStatus(Sender: TObject);
begin
  StatusForm.OnTogglePause := @HandleTogglePause;
  StatusForm.OnSyncRepo := @HandleSyncRepo;
  StatusForm.OnOpenRepo := @HandleOpenRepo;
  StatusForm.Bind(FStatus);
  StatusForm.Show;
  StatusForm.BringToFront;
end;

procedure TMainForm.HandleTogglePause(const ARepo: string);
var
  e: TRepoEntry;
begin
  if not FConfig.FindRepo(ARepo, e) then Exit;
  e.Paused := not e.Paused;
  FConfig.UpsertRepo(e);
  FStore.Save(FConfig);
  if Assigned(Log) then
    if e.Paused then Log.Info('ui', 'paused ' + ARepo)
    else
      Log.Info('ui', 'resumed ' + ARepo);
  StartEngine;   // restart so the new Paused flags take effect
end;

procedure TMainForm.HandleSyncRepo(const ARepo: string);
begin
  if Assigned(FEngine) and FEngine.Running then
    FEngine.SyncRepo(ARepo);
end;

procedure TMainForm.HandleOpenRepo(const ARepo: string);
var
  p: string;
begin
  p := IncludeTrailingPathDelimiter(FConfig.RootDir) + ARepo;
  if DirectoryExists(p) then OpenDocument(p);
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
