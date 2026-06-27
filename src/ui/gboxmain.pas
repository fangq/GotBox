unit gboxmain;

{ Hidden main controller form. Owns the system-tray icon and its popup menu,
  holds the global config/status objects, and opens the Login/Config/Status
  windows on demand. The app has no visible main window -- it lives in the tray. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Forms, Controls, Graphics, Menus, ExtCtrls,
  Dialogs, LCLType, LCLIntf, gboxconfigstore, gboxstatusmodel, gboxlog,
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
    FTrayShown: Boolean;   // has the tray icon been set at least once?
    FIcons: array[TRepoState] of TIcon;
    FBootWatcher: TFileWatcher;
    // qualified: an LCL unit in the uses clause shadows TCriticalSection with
    // the System record type, so name it from SyncObjs explicitly
    FNoteLock: SyncObjs.TCriticalSection;   // queue of pending notices (worker->GUI)
    FNotes: TStringList;                     // each line: title <TAB> body
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
    procedure StartupTasks(Data: PtrInt);
    procedure Notify(const ATitle, AMsg: string);
    procedure HandleSyncNotice(const ATitle, ABody: string);
    procedure DrainNotices;
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
    procedure mnuExportLog(Sender: TObject);
    procedure mnuAbout(Sender: TObject);
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

  FNoteLock := SyncObjs.TCriticalSection.Create;
  FNotes := TStringList.Create;

  // Tray/icon setup is non-essential: if it fails (e.g. no system tray), log it
  // but keep the app alive so the rest of startup still runs.
  try
    BuildIcons;
    BuildTrayMenu;
    TrayIcon.PopUpMenu := TrayMenu;
    TrayIcon.Hint := 'GotBox';
    TrayIcon.Visible := True;
    FLastAgg := rsIdle;
    UpdateTrayState;
  except
    on E: Exception do
      if Assigned(Log) then Log.Error('app', 'tray init failed: ' + E.Message);
  end;

  // Defer first-run prompts + engine start until the message loop is running.
  // Showing a modal dialog from inside FormCreate (before Application.Run) is
  // unreliable on gtk2 and can crash; QueueAsyncCall runs this once we're live.
  Application.QueueAsyncCall(@StartupTasks, 0);
end;

{ Runs after the message loop starts: prompt for any missing first-run setup
  (GitHub account, root folder), then bring the sync engine up. Wrapped so a
  failure is logged instead of taking the whole app down. }
procedure TMainForm.StartupTasks(Data: PtrInt);
begin
  try
    if Assigned(Log) then Log.Info('app', 'startup: checking configuration');
    MaybePromptLogin;   // GitHub user + PAT if missing

    // First run: the root defaults to $HOME/GotBox -- create it so the app works
    // out of the box. Only prompt if it's blank or can't be created.
    if FConfig.RootDir <> '' then
      ForceDirectories(FConfig.RootDir);
    if (FConfig.RootDir = '') or not DirectoryExists(FConfig.RootDir) then
      if ConfigForm.Edit(FConfig) then
        FStore.Save(FConfig);

    StartEngine;    // begin syncing if the .gotbox root already exists
    TryBootstrap;   // clone an existing remote, or create from local content
    StartBootWatch; // watch for content appearing later (event-driven)
  except
    on E: Exception do
      if Assigned(Log) then Log.Error('app', 'startup tasks failed: ' + E.Message);
  end;
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
  FNotes.Free;
  FNoteLock.Free;
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
  AddItem('Export log...', @mnuExportLog);
  AddSep;
  AddItem('About', @mnuAbout);
  AddItem('Quit', @mnuQuit);
end;

procedure TMainForm.BuildIcons;

  function MakeDot(AColor: TColor): TIcon;
  const
    SZ = 24;   // AppIndicator/SNI panels render at ~22-24px; 16 looked blurry
  var
    bmp: TBitmap;
  begin
    bmp := TBitmap.Create;
    try
      bmp.SetSize(SZ, SZ);
      bmp.Canvas.Brush.Color := AColor;
      bmp.Canvas.FillRect(0, 0, SZ, SZ);
      bmp.Canvas.Brush.Style := bsClear;
      bmp.Canvas.Pen.Color := clBlack;
      bmp.Canvas.Rectangle(0, 0, SZ, SZ);
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

  // Only touch the tray icon when the aggregate state actually changes. The
  // LCL gtk2 AppIndicator backend writes a NEW temp PNG with a new icon name on
  // every Icon assignment; reassigning on each status-model change churns the
  // name so fast that StatusNotifier panels (ayatana) give up and show a generic
  // fallback icon. Updating only on real change keeps the icon name stable.
  if FTrayShown and (agg = FLastAgg) then
    Exit;

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
  FTrayShown := True;
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
  FEngine.OnNotice := @HandleSyncNotice;   // set before Start so workers pick it up
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

  // Set up the root if either: the remote .gotbox already exists (fresh machine
  // -> clone it, even into an empty root) OR local content exists (first machine
  // -> create the repo and push). Otherwise wait for content to appear.
  if not (RootHasContent(FConfig.RootDir) or GotboxRemoteReady(FConfig, token)) then
    Exit;

  if Assigned(Log) then
    Log.Info('bootstrap',
      'setting up .gotbox (clone existing remote or create from local content)');
  if EnsureGotboxRoot(FConfig, token, detail) then
  begin
    StartEngine;
    StopBootWatch;
  end
  else if Assigned(Log) then
    Log.Warn('bootstrap', 'setup failed: ' + detail);
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

{ Called on a worker thread: queue the notice and ask the GUI thread to drain. }
procedure TMainForm.HandleSyncNotice(const ATitle, ABody: string);
begin
  FNoteLock.Enter;
  try
    FNotes.Add(ATitle + #9 + ABody);
  finally
    FNoteLock.Leave;
  end;
  TThread.Queue(nil, @DrainNotices);
end;

{ GUI thread: show all queued "synced" notices. }
procedure TMainForm.DrainNotices;
var
  pending: TStringList;
  i, sp: Integer;
  line: string;
begin
  pending := TStringList.Create;
  try
    FNoteLock.Enter;
    try
      pending.Assign(FNotes);
      FNotes.Clear;
    finally
      FNoteLock.Leave;
    end;
    for i := 0 to pending.Count - 1 do
    begin
      line := pending[i];
      sp := Pos(#9, line);
      if sp > 0 then
        Notify(Copy(line, 1, sp - 1), Copy(line, sp + 1, MaxInt))
      else
        Notify('GotBox', line);
    end;
  finally
    pending.Free;
  end;
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

procedure TMainForm.mnuExportLog(Sender: TObject);
var
  dlg: TSaveDialog;
  src: TFileStream;
  dst: TFileStream;
begin
  if not Assigned(Log) or (Log.Path = '') or not FileExists(Log.Path) then
  begin
    Notify('GotBox', 'No log file to export yet.');
    Exit;
  end;
  dlg := TSaveDialog.Create(nil);
  try
    dlg.Title := 'Export GotBox log';
    dlg.Filter := 'Log files|*.log;*.txt|All files|*.*';
    dlg.DefaultExt := 'log';
    dlg.Options := dlg.Options + [ofOverwritePrompt];
    dlg.FileName := 'gotbox-' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.log';
    if not dlg.Execute then Exit;
    try
      // copy the on-disk log (shared read so the logger can keep appending)
      src := TFileStream.Create(Log.Path, fmOpenRead or fmShareDenyNone);
      try
        dst := TFileStream.Create(dlg.FileName, fmCreate);
        try
          dst.CopyFrom(src, 0);
        finally
          dst.Free;
        end;
      finally
        src.Free;
      end;
      Notify('GotBox', 'Log exported to ' + dlg.FileName);
    except
      on E: Exception do
        MsgError('Could not export the log:' + LineEnding + E.Message);
    end;
  finally
    dlg.Free;
  end;
end;

procedure TMainForm.mnuAbout(Sender: TObject);
begin
  MsgInfo('GotBox ' + GOTBOX_VERSION + LineEnding + LineEnding +
    'Edit locally, auto-sync everywhere via private GitHub repos.' +
    LineEnding + LineEnding + 'https://github.com/fangq/GotBox');
end;

procedure TMainForm.mnuQuit(Sender: TObject);
begin
  Application.Terminate;
end;

end.
