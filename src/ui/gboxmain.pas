unit gboxmain;

{ Hidden main controller form. Owns the system-tray icon and its popup menu,
  holds the global config/status objects, and opens the Login/Config/Status
  windows on demand. The app has no visible main window -- it lives in the tray. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Menus, ExtCtrls, Dialogs,
  LCLType, LCLIntf, gboxconfigstore, gboxstatusmodel, gboxlog,
  gboxcredstore, gboxengine, gboxsuper, gboxfilewatcher, gboxmsg;

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
    FBootWatcher: TFileWatcher;
    procedure TryBootstrap;
    procedure BootWatchChanged(Sender: TObject);
    procedure StartBootWatch;
    procedure StopBootWatch;
    procedure BuildTrayMenu;
    procedure BuildIcons;
    procedure FreeIcons;
    procedure UpdateTrayState;
    procedure StatusModelChanged;
    procedure StartEngine;
    procedure StopEngine;
    procedure MaybePromptLogin;
    procedure Notify(const ATitle, AMsg: string);
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

  MaybePromptLogin;  // ask for GitHub creds up front if they're missing

  StartEngine;   // begin syncing if the .gotbox root already exists
  TryBootstrap;  // or auto-create .gotbox if content already sits in the root
  StartBootWatch; // and watch (via inotify/native) for content appearing later
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  if Assigned(Log) then Log.Info('app', 'GotBox stopping');
  StopBootWatch;
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
      Notify('GotBox - conflict',
        'A file changed on two machines. Both versions were kept; open Status to resolve.')
    else
      Notify('GotBox - sync error', 'A repo could not sync. Open Status for details.');
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
  token, err, detail: string;
begin
  StopEngine;
  // only run once the .gotbox root has been set up locally
  if not IsGitWorkTree(FConfig.RootDir) then Exit;
  if not PrepareRemote(token, err) then
  begin
    if Assigned(Log) then Log.Warn('engine', 'sync not started: ' + err);
    Exit;
  end;

  // Reconcile the root with its remote: if the remote .gotbox was deleted, this
  // recreates the private repo and pushes the local content back (resurrect).
  // Confirmed via authenticated REST, so it won't misfire on an auth 404.
  if not EnsureGotboxRoot(FConfig, token, detail) then
    if Assigned(Log) then
      Log.Warn('engine', 'root reconcile: ' + detail);   // proceed anyway

  FEngine := TSyncEngine.Create(FConfig, token, FStatus);
  FEngine.Start;
end;

procedure TMainForm.StopEngine;
begin
  if Assigned(FEngine) then
    FreeAndNil(FEngine);   // TSyncEngine.Destroy stops + joins the workers
end;

{ At startup, if the GitHub backend is selected but the username or token is
  missing, show the login dialog. The ssh backend uses keys, so nothing to ask. }
procedure TMainForm.MaybePromptLogin;
var
  cred: TCredStore;
  tok: string;
  haveCreds: Boolean;
begin
  if SameText(FConfig.RemoteKind, 'git') then Exit;   // ssh keys; nothing to collect

  haveCreds := False;
  if FConfig.GithubUser <> '' then
  begin
    cred := TCredStore.Create;
    try
      haveCreds := cred.LoadToken(FConfig.GithubUser, tok);
    finally
      cred.Free;
    end;
  end;
  if haveCreds then Exit;

  if LoginForm.RunLogin(FConfig) then
  begin
    FStore.Save(FConfig);
    if Assigned(Log) then
      Log.Info('ui', 'account set at startup for ' + FConfig.GithubUser);
  end;
end;

{ Event-driven bootstrap: if the backend is configured and the .gotbox root
  isn't set up yet, auto-create it as soon as real content appears in the root,
  then start syncing. Triggered by the native root watcher and by UI actions
  (account/settings saved) -- no polling. Runs on the main thread. }
procedure TMainForm.TryBootstrap;
var
  token, err, detail: string;
begin
  if Assigned(FEngine) and FEngine.Running then
  begin
    StopBootWatch;   // already syncing; the root worker watches from here on
    Exit;
  end;
  if not PrepareRemote(token, err) then Exit;   // backend not ready yet

  if IsGitWorkTree(FConfig.RootDir) then
  begin
    StartEngine;     // root already a .gotbox tree (cloned/linked elsewhere)
    StopBootWatch;
    Exit;
  end;

  if not RootHasContent(FConfig.RootDir) then Exit;   // nothing to sync yet

  if Assigned(Log) then
    Log.Info('bootstrap', 'content detected in root; creating .gotbox');
  if EnsureGotboxRoot(FConfig, token, detail) then
  begin
    StartEngine;
    StopBootWatch;
  end
  else if Assigned(Log) then
    Log.Warn('bootstrap', 'auto-create failed: ' + detail);
end;

procedure TMainForm.BootWatchChanged(Sender: TObject);
begin
  // fired from the watcher thread; marshal the bootstrap onto the GUI thread
  TThread.Queue(nil, @TryBootstrap);
end;

procedure TMainForm.StartBootWatch;
begin
  StopBootWatch;
  if (FConfig.RootDir = '') or not DirectoryExists(FConfig.RootDir) then Exit;
  if IsGitWorkTree(FConfig.RootDir) then Exit;   // already set up; no need
  FBootWatcher := CreateFileWatcher(FConfig.RootDir, FConfig.IgnoreGlobs);
  FBootWatcher.OnChanged := @BootWatchChanged;
  FBootWatcher.Start;
end;

procedure TMainForm.StopBootWatch;
begin
  if Assigned(FBootWatcher) then
  begin
    FBootWatcher.Stop;
    FreeAndNil(FBootWatcher);
  end;
end;

procedure TMainForm.TrayIconDblClick(Sender: TObject);
begin
  mnuStatus(Sender);
end;

{ Non-blocking informational notice. Prefer the OS notifier (notify-send /
  osascript); fall back to the tray balloon only where there's no notifier
  (e.g. Windows) -- LCL's gtk2 tray balloon is broken (top-left + Gtk-CRITICAL). }
procedure TMainForm.Notify(const ATitle, AMsg: string);
begin
  if DesktopNotify(ATitle, AMsg) then Exit;
  TrayIcon.BalloonTitle := ATitle;
  TrayIcon.BalloonHint := AMsg;
  TrayIcon.ShowBalloonHint;
end;

procedure TMainForm.mnuOpenRoot(Sender: TObject);
begin
  if (FConfig.RootDir <> '') and DirectoryExists(FConfig.RootDir) then
    OpenDocument(FConfig.RootDir)
  else
    Notify('GotBox', 'No root folder configured yet. Open Settings to choose one.');
end;

procedure TMainForm.mnuLinkSub(Sender: TObject);
var
  token, err, detail: string;
  ok: Boolean;
  entry: TRepoEntry;
begin
  if not PrepareRemote(token, err) then
  begin
    MsgError(err);
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
        MsgError('Could not set up the .gotbox root:' + LineEnding + detail);
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
    MsgError('Link failed:' + LineEnding + detail);
    Exit;
  end;

  // record the new submodule in config (for the per-submodule Paused flag)
  entry.LocalName := LinkSubForm.LocalName;
  entry.RemoteUrl := '';
  entry.Paused := False;
  FConfig.UpsertRepo(entry);
  FStore.Save(FConfig);

  StartEngine;   // (re)start sync to pick up the new submodule
  Notify('GotBox', 'Linked submodule "' + LinkSubForm.LocalName + '".');
end;

procedure TMainForm.mnuSyncNow(Sender: TObject);
begin
  if Assigned(FEngine) and FEngine.Running then
  begin
    FEngine.SyncAllNow;
    Log.Info('ui', 'Sync now requested');
  end
  else
    Notify('GotBox', 'Nothing is being synced yet. Use "Link submodule..." first.');
end;

procedure TMainForm.mnuStatus(Sender: TObject);
begin
  StatusForm.OnTogglePause := @HandleTogglePause;
  StatusForm.OnSyncRepo := @HandleSyncRepo;
  StatusForm.OnOpenRepo := @HandleOpenRepo;
  StatusForm.Bind(FStatus);
  if not StatusForm.Visible then
  begin
    CenterForm(StatusForm);
    StatusForm.Show;
  end;
  StatusForm.BringToFront;
  StatusForm.SetFocus;
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
    // root may have changed: re-evaluate bootstrap and (re)arm the watcher
    TryBootstrap;
    StartBootWatch;
  end;
end;

procedure TMainForm.mnuAccount(Sender: TObject);
begin
  if LoginForm.RunLogin(FConfig) then
  begin
    FStore.Save(FConfig);
    Log.Info('ui', 'Account updated for user ' + FConfig.GithubUser);
    // backend just became ready: content already in the root can now bootstrap
    TryBootstrap;
  end;
end;

procedure TMainForm.mnuQuit(Sender: TObject);
begin
  Application.Terminate;
end;

end.
