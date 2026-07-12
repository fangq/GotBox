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

unit gboxmain;

{ Hidden main controller form. Owns the system-tray icon and its popup menu,
  holds the global config/status objects, and opens the Login/Config/Status
  windows on demand. The app has no visible main window -- it lives in the tray. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Forms, Controls, Graphics, Menus, ExtCtrls,
  StdCtrls, Dialogs, LCLType, LCLIntf, IntfGraphics, GraphType, fpimage,
  gboxconfigstore, gboxstatusmodel, gboxlog,
  gboxcredstore, gboxengine, gboxsuper, gboxfilewatcher, gboxrootlock, gboxmsg,
  gboxfilestatus, gboxoverlayipc, gboxdaemon, gboxgitrunner, gboxhistory;

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
    FStatusCache: TStatusCache;   // per-file status for the file-manager overlay
    FOverlay: TOverlayServer;     // answers overlay queries from FStatusCache
    FLastAgg: TRepoState;
    FTrayShown: Boolean;   // has the tray icon been set at least once?
    FStatusItem: TMenuItem;   // disabled top menu item mirroring the state (tray
                              // tooltips are unreliable on Linux SNI/xfce)
    FIcons: array[TRepoState] of TIcon;
    FBootWatcher: TFileWatcher;
    // qualified: an LCL unit in the uses clause shadows TCriticalSection with
    // the System record type, so name it from SyncObjs explicitly
    FNoteLock: SyncObjs.TCriticalSection;   // queue of pending notices (worker->GUI)
    FNotes: TStringList;                     // each line: title <TAB> body
    FLockToken: string;                      // our root-lock identity for this run
    FLockTimer: TTimer;                      // root-lock heartbeat + takeover watchdog
    FPendingToken: string;
    // token handed to DoCreateEngine (main thread)
    {$IFDEF LINUX}
    FScaleTimer: TTimer;                     // polls desktop scale for live HiDPI refresh
    procedure ScaleTick(Sender: TObject);
    {$ENDIF}
    procedure LockTick(Sender: TObject);
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
    procedure BringUp;
    // heavy startup work (runs off the GUI thread)
    procedure RunOnMain(AMethod: TThreadMethod);
    procedure DoStopEngine;                  // FEngine lifecycle -- main thread only
    procedure EnsureOverlay;                 // create/refresh cache + overlay server
    procedure DoCreateEngine;
    procedure EnableLockTimer;
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
    procedure HandleOpenWeb(const ARepo: string);
    procedure HandleListTags(const ARepo: string; AOut: TStrings);
    procedure HandleAddTag(const ARepo, ALabel, AMessage: string);
    procedure HandleSquashTags(const ARepo: string);
    function RepoDir(const ARepo: string): string;
    // menu handlers
    procedure mnuOpenRoot(Sender: TObject);
    procedure mnuLinkSub(Sender: TObject);
    procedure mnuSyncNow(Sender: TObject);
    procedure mnuStatus(Sender: TObject);
    procedure mnuSettings(Sender: TObject);
    procedure mnuAccount(Sender: TObject);
    procedure mnuExportLog(Sender: TObject);
    procedure mnuEnableOverlays(Sender: TObject);
    procedure mnuFinderOverlays(Sender: TObject);
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

type
  { One-shot worker that runs the heavy startup bring-up off the GUI thread. }
  TBringUpThread = class(TThread)
  private
    FForm: TMainForm;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TMainForm);
  end;

constructor TBringUpThread.Create(AForm: TMainForm);
begin
  FForm := AForm;
  FreeOnTerminate := True;
  inherited Create(False);   // run now
end;

procedure TBringUpThread.Execute;
begin
  FForm.BringUp;
end;

{$IFDEF LCLGtk2}
// The gtk2/ayatana tray backend publishes each status icon as a fresh flat file
// in /tmp/appindicators/ and switches to it by name. The panel's GtkIconTheme has
// that directory cached from its first scan, so a just-written name often fails
// to resolve and the indicator shows a fallback icon. Forcing the default icon
// theme to rescan emits GtkIconTheme::changed, which makes the panel reload.
function gtk_icon_theme_get_default: Pointer; cdecl;
  external 'libgtk-x11-2.0.so.0';
procedure gtk_icon_theme_rescan_if_needed(icon_theme: Pointer); cdecl;
  external 'libgtk-x11-2.0.so.0';

procedure RefreshTrayIconTheme;
begin
  gtk_icon_theme_rescan_if_needed(gtk_icon_theme_get_default);
end;
{$ELSE}

procedure RefreshTrayIconTheme;
begin
end;
{$ENDIF}

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

  {$IFDEF LINUX}
  // Live HiDPI refresh: gtk2 never tells us when the desktop scale changes, so
  // poll it and re-scale open windows when it does (no restart needed).
  FScaleTimer := TTimer.Create(Self);
  FScaleTimer.Interval := 3000;
  FScaleTimer.OnTimer := @ScaleTick;
  FScaleTimer.Enabled := True;
  {$ENDIF}

  // Root-lock heartbeat + takeover watchdog (enabled once the engine starts, or
  // while standing by for another machine to release the folder).
  FLockTimer := TTimer.Create(Self);
  FLockTimer.Interval := LOCK_HEARTBEAT_SEC * 1000;
  FLockTimer.OnTimer := @LockTick;
  FLockTimer.Enabled := False;

  // Defer first-run prompts + engine start until the message loop is running.
  // Showing a modal dialog from inside FormCreate (before Application.Run) is
  // unreliable on gtk2 and can crash; QueueAsyncCall runs this once we're live.
  Application.QueueAsyncCall(@StartupTasks, 0);
end;

{$IFDEF LINUX}
procedure TMainForm.ScaleTick(Sender: TObject);
begin
  // RefreshScale recomputes the target DPI and re-scales every form if it moved
  if RefreshScale and Assigned(Log) then
    Log.Info('ui', 'UI rescaled to desktop DPI change');
end;
{$ENDIF}

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

    // Prompts are done (main thread); run the slow bring-up (clone / reconcile /
    // engine start) on a worker thread so the tray menu stays responsive during
    // the first sync. FEngine is still created only on the main thread.
    TBringUpThread.Create(Self);
  except
    on E: Exception do
      if Assigned(Log) then Log.Error('app', 'startup tasks failed: ' + E.Message);
  end;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  if Assigned(Log) then Log.Info('app', 'GotBox stopping');
  {$IFDEF LINUX}
  if Assigned(FScaleTimer) then FScaleTimer.Enabled := False;
  {$ENDIF}
  if Assigned(FLockTimer) then FLockTimer.Enabled := False;
  StopBootWatch;
  StopEngine;        // stop worker threads before freeing the status model
  FOverlay.Free;     // stop the overlay server before freeing the cache it reads
  FStatusCache.Free;
  if FLockToken <> '' then
    ReleaseRootLock(FConfig.RootDir, FLockToken);   // free the lock for others
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
  // A disabled status line at the top: the tray tooltip (Hint) is honoured on
  // Windows but not by Linux StatusNotifier hosts (xfce), so the menu is the
  // reliable place to show the current sync state on every desktop.
  FStatusItem := TMenuItem.Create(TrayMenu);
  FStatusItem.Caption := 'Status: starting...';
  FStatusItem.Enabled := False;
  TrayMenu.Items.Add(FStatusItem);
  AddSep;

  AddItem('Open root folder', @mnuOpenRoot);
  AddItem('Link submodule...', @mnuLinkSub);
  AddItem('Sync now', @mnuSyncNow);
  AddSep;
  AddItem('Status...', @mnuStatus);
  AddItem('Settings...', @mnuSettings);
  AddItem('Account...', @mnuAccount);
  AddItem('Export log...', @mnuExportLog);
  {$IFDEF WINDOWS}
  // Explorer status badges are a Windows shell extension; registering it needs
  // admin (one UAC prompt), so it is an explicit opt-in action, not automatic.
  AddItem('Enable Explorer icon overlays...', @mnuEnableOverlays);
  {$ENDIF}
  {$IFDEF DARWIN}
  // Finder status badges come from an app extension the user enables once in
  // System Settings; this item just points them there.
  AddItem('Finder icon overlays...', @mnuFinderOverlays);
  {$ENDIF}
  AddSep;
  AddItem('About', @mnuAbout);
  AddItem('Quit', @mnuQuit);
end;

procedure TMainForm.BuildIcons;

// A flat, single-tone isometric box whose body colour encodes the status, with
// a constant light "G" traced along the cube's own edges (the geometry is
// lifted from assets/icons/gbox.svg; see tools/make-icon.py). Flat (not shaded)
// so the G stays legible at the ~22-24px the tray renders at. Transparency is
// done with a colour key -- LCL canvas drawing is aliased, so keying is clean.
  function MakeBox(AColor: TColor): TIcon;
  const
    SZ = 48;                    // render at 2x so the panel scales DOWN (crisp);
    // a 24px source gets upscaled to panel height and
    // the thin G blurs into a solid block
    MG = 0.09;                  // margin so the G stroke isn't clipped
    KEY = TColor($00FE00FE);     // transparent colour-key (not used by any face)
    GCOL = TColor($00EDEDED);    // constant light "G" (#ededed)
  var
    bmp, obmp: TBitmap;
    src, dst: TLazIntfImage;
    desc: TRawImageDescription;
    gw, x, y: Integer;
    col: TFPColor;
    top, ul, ur, cc, ll, lr, bot: TPoint;

    function Q(nx, ny: Double): TPoint;
    var
      s: Double;
    begin
      s := 1 - 2 * MG;
      Result := Point(Round((MG + nx * s) * SZ), Round((MG + ny * s) * SZ));
    end;

  begin
    // normalized cube vertices (top / upper-left / upper-right / centre / ...)
    top := Q(0.5, 0.0);
    ul := Q(0.0, 0.25);
    ur := Q(1.0, 0.25);
    cc := Q(0.5, 0.5);
    ll := Q(0.0, 0.75);
    lr := Q(1.0, 0.75);
    bot := Q(0.5, 1.0);
    gw := SZ div 8;
    if gw < 2 then gw := 2;

    bmp := TBitmap.Create;
    try
      // Draw the box on an opaque bitmap over a magenta colour-key background.
      // (We can't just set pf32bit + draw: LCL's Canvas leaves the alpha channel
      // at 0, and the 1-bit TransparentColor mask isn't exported as PNG alpha by
      // the ayatana AppIndicator backend -- both make the tray icon vanish. So we
      // rebuild the pixels below into a real BGRA image, keying the background to
      // alpha 0 and everything else to opaque, then hand it to the TIcon as a
      // 32-bit bitmap so its gtk2 handle is a GdkPixbuf WITH an alpha channel --
      // the ayatana backend saves Icon.Handle straight to PNG via gdk_pixbuf_save.)
      bmp.SetSize(SZ, SZ);
      bmp.Canvas.Brush.Style := bsSolid;
      bmp.Canvas.Brush.Color := KEY;
      bmp.Canvas.FillRect(0, 0, SZ, SZ);

      bmp.Canvas.Brush.Color := AColor;            // flat hexagon body = status colour
      bmp.Canvas.Pen.Color := AColor;
      bmp.Canvas.Pen.Width := 1;
      bmp.Canvas.Polygon([top, ur, lr, bot, ll, ul]);

      bmp.Canvas.Pen.Color := GCOL;                // constant light "G"
      bmp.Canvas.Pen.Width := gw;                  // top->ul->ll->bot->lr->ur->centre
      bmp.Canvas.Pen.JoinStyle := pjsRound;        // (skips top->ur = the G's mouth)
      bmp.Canvas.Pen.EndCap := pecRound;
      bmp.Canvas.Polyline([top, ul, ll, bot, lr, ur, cc]);

      src := bmp.CreateIntfImage;
      dst := TLazIntfImage.Create(0, 0);
      try
        desc.Init_BPP32_B8G8R8A8_BIO_TTB(SZ, SZ);
        dst.DataDescription := desc;
        for y := 0 to SZ - 1 do
          for x := 0 to SZ - 1 do
          begin
            col := src.Colors[x, y];
            // background key = magenta (high red+blue, near-zero green) -> clear
            if (col.green < $4000) and (col.red > $C000) and (col.blue > $C000) then
              col.alpha := 0
            else
              col.alpha := alphaOpaque;
            dst.Colors[x, y] := col;
          end;
        // Load the BGRA image into a 32-bit bitmap and Assign it to the icon.
        // (Going via CreateBitmaps + TIcon.Handle := bh instead yields a raster
        // handle that is NOT a valid GdkPixbuf, so the ayatana backend's
        // gdk_pixbuf_save reads garbage -> a black-background, alpha-less icon.)
        obmp := TBitmap.Create;
        try
          obmp.PixelFormat := pf32bit;
          obmp.LoadFromIntfImage(dst);
          Result := TIcon.Create;
          Result.Assign(obmp);
        finally
          obmp.Free;
        end;
      finally
        dst.Free;
        src.Free;
      end;
    finally
      bmp.Free;
    end;
  end;

begin
  FIcons[rsIdle] := MakeBox(RGBToColor(149, 165, 166));    // grey
  FIcons[rsSynced] := MakeBox(RGBToColor(39, 158, 95));    // muted green
  FIcons[rsSyncing] := MakeBox(RGBToColor(52, 152, 219));  // blue
  FIcons[rsConflict] := MakeBox(RGBToColor(243, 156, 18)); // amber
  FIcons[rsError] := MakeBox(RGBToColor(231, 76, 60));     // red
  FIcons[rsPaused] := MakeBox(RGBToColor(149, 165, 166));  // grey
  FIcons[rsOffline] := MakeBox(RGBToColor(127, 140, 141)); // slate grey (offline)
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
  s: string;
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
    rsError: s := 'error';
    rsConflict: s := 'conflict';
    rsSyncing: s := 'syncing';
    rsPaused: s := 'paused';
    rsOffline: s := 'offline (no network)';
    rsIdle: s := 'idle (not syncing)';
    else
      s := 'synced';
  end;
  TrayIcon.Hint := 'GotBox - ' + s;               // honoured on Windows
  if Assigned(FStatusItem) then                   // reliable everywhere (xfce/SNI)
    FStatusItem.Caption := 'Status: ' + s;

  // swap the tray icon colour to match the aggregate state
  if Assigned(FIcons[agg]) then
  begin
    TrayIcon.Icon := FIcons[agg];
    TrayIcon.InternalUpdate;
    // make the panel notice the freshly-written icon file (see RefreshTrayIconTheme)
    RefreshTrayIconTheme;
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

{ Run AMethod on the GUI thread: directly if we are already there, else marshal
  via Synchronize. Lets StartEngine run its slow git/network work on a worker
  thread while every FEngine/LCL touch still happens on the main thread. }
procedure TMainForm.RunOnMain(AMethod: TThreadMethod);
begin
  if GetCurrentThreadID = MainThreadID then AMethod()
  else
    TThread.Synchronize(nil, AMethod);
end;

procedure TMainForm.DoStopEngine;   // main thread only (via RunOnMain)
begin
  if Assigned(FEngine) then
    FreeAndNil(FEngine);   // TSyncEngine.Destroy stops + joins the workers
end;

procedure TMainForm.EnableLockTimer;   // main thread only (TTimer is LCL)
begin
  FLockTimer.Enabled := True;
end;

{ Create (or re-create when the root changed) the per-file status cache and the
  overlay IPC server that reads it. Called as the engine comes up. }
procedure TMainForm.EnsureOverlay;
begin
  if Assigned(FStatusCache) and (FStatusCache.RootDir <>
    ExcludeTrailingPathDelimiter(FConfig.RootDir)) then
  begin
    FreeAndNil(FOverlay);          // stop the server before freeing its cache
    FreeAndNil(FStatusCache);
  end;
  if not Assigned(FStatusCache) then
    FStatusCache := TStatusCache.Create(FConfig.RootDir);
  if not Assigned(FOverlay) then
  begin
    FOverlay := TOverlayServer.Create(FStatusCache);
    FOverlay.Start;
  end;
end;

procedure TMainForm.DoCreateEngine;   // main thread only: FEngine + timer
begin
  DoStopEngine;
  FEngine := TSyncEngine.Create(FConfig, FPendingToken, FStatus);
  FEngine.OnNotice := @HandleSyncNotice;   // set before Start so workers pick it up
  EnsureOverlay;
  FEngine.StatusCache := FStatusCache;      // workers refresh it after each cycle
  FEngine.Start;
  FLockTimer.Enabled := True;   // heartbeat the lock + watch for a takeover
end;

{ Bring the sync engine up. The slow parts (root lock, remote validation, and
  the .gotbox clone/reconcile) run on whatever thread calls this -- at startup
  that is a worker thread, so the tray stays responsive during the first sync --
  while the engine object itself is only ever created/freed on the main thread
  (via RunOnMain), so menu handlers never race a half-freed FEngine. }
procedure TMainForm.StartEngine;
var
  token, err, detail: string;
  lockOwner: TLockOwner;
  takeover: Boolean;
begin
  RunOnMain(@DoStopEngine);
  // only run once the .gotbox root has been set up locally
  if not IsGitWorkTree(FConfig.RootDir) then Exit;

  // Cross-machine lock: never drive a root another GotBox instance is already
  // managing (the shared-folder hazard). If another owns it, ask before taking
  // over; if the user declines, stand by (the timer retries when it frees). The
  // prompt is only possible on the main thread -- off it, just stand by.
  if FLockToken = '' then FLockToken := NewLockToken;
  if AcquireRootLock(FConfig.RootDir, FConfig.MachineName, FLockToken,
    False, lockOwner) = arHeldByOther then
  begin
    takeover := False;
    if GetCurrentThreadID = MainThreadID then
      takeover := MessageDlg('GotBox', Format(
        'This folder is already being managed by GotBox on "%s".' +
        LineEnding + LineEnding +
        'Take over here? That machine will pause syncing this folder.',
        [lockOwner.Machine]), mtWarning, [mbYes, mbNo], 0) = mrYes;
    if takeover then
      AcquireRootLock(FConfig.RootDir, FConfig.MachineName, FLockToken, True, lockOwner)
    else
    begin
      if Assigned(FStatus) then
        FStatus.SetState(GOTBOX_REPO, rsPaused, 'managed by ' + lockOwner.Machine);
      RunOnMain(@EnableLockTimer);   // keep watching; resume if it is released
      Exit;
    end;
  end;

  if not PrepareRemote(token, err) then
  begin
    if Assigned(Log) then Log.Warn('engine', 'sync not started: ' + err);
    // surface a non-green "needs attention" icon (e.g. login failed / no token)
    // instead of leaving the tray falsely showing synced/idle
    if Assigned(FStatus) then FStatus.SetState(GOTBOX_REPO, rsError, err);
    Exit;
  end;

  // Reconcile the root with its remote: if the remote .gotbox was deleted, this
  // recreates the private repo and pushes the local content back (resurrect).
  // Confirmed via authenticated REST, so it won't misfire on an auth 404.
  if not EnsureGotboxRoot(FConfig, token, detail) then
    if Assigned(Log) then
      Log.Warn('engine', 'root reconcile: ' + detail);   // proceed anyway

  FPendingToken := token;
  RunOnMain(@DoCreateEngine);   // create + start the engine on the main thread
end;

{ Heavy startup bring-up, run on a worker thread so the tray menu is responsive
  during the initial sync/clone. FEngine is still only touched on the main
  thread (StartEngine/TryBootstrap marshal via RunOnMain). }
procedure TMainForm.BringUp;
begin
  try
    StartEngine;                      // starts the engine if the root is set up
    if not Assigned(FEngine) then     // root not set up yet -> clone/create it
      TryBootstrap;
    StartBootWatch;                   // watch for content appearing later
  except
    on E: Exception do
      if Assigned(Log) then Log.Error('app', 'bring-up failed: ' + E.Message);
  end;
end;

{ Root-lock heartbeat + takeover watchdog (every LOCK_HEARTBEAT_SEC). While the
  engine runs, refresh our lock and, if another machine took the folder over,
  pause here. While standing by (engine not running because another machine
  held the lock), resume automatically once the folder is released. }
procedure TMainForm.LockTick(Sender: TObject);
var
  lockOwner: TLockOwner;
begin
  if FLockToken = '' then Exit;
  if not IsGitWorkTree(FConfig.RootDir) then Exit;
  if Assigned(FEngine) then
  begin
    if StillRootOwner(FConfig.RootDir, FLockToken) then
      RefreshRootLock(FConfig.RootDir, FConfig.MachineName, FLockToken)
    else
    begin
      // another machine took over -> pause so two never drive one tree at once
      StopEngine;
      if Assigned(FStatus) then
        FStatus.SetState(GOTBOX_REPO, rsPaused, 'another machine took over');
      Notify('GotBox - paused',
        'Another machine took over this folder; syncing is paused here.');
    end;
  end
  else
  begin
    // standing by: take the folder back as soon as it is free/stale
    if AcquireRootLock(FConfig.RootDir, FConfig.MachineName, FLockToken,
      False, lockOwner) = arAcquired then
    begin
      Notify('GotBox', 'This folder is free again; resuming sync here.');
      StartEngine;
    end;
  end;
end;

procedure TMainForm.StopEngine;
begin
  RunOnMain(@DoStopEngine);   // FEngine is only ever freed on the main thread
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
  token, err, detail, localName: string;
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

  // accept a relative path (e.g. "projects/notes"); store the same normalized
  // form git uses in .gitmodules so the per-repo config keys match
  if not NormalizeSubmodulePath(LinkSubForm.LocalName, localName, detail) then
  begin
    MsgError('Invalid submodule path:' + LineEnding + detail);
    Exit;
  end;

  Screen.Cursor := crHourGlass;
  try
    ok := AddSubmodule(FConfig, token, localName, LinkSubForm.UpstreamName,
      LinkSubForm.ExistingUrl, LinkSubForm.CreateUpstream, detail);
  finally
    Screen.Cursor := crDefault;
  end;

  if not ok then
  begin
    MsgError('Link failed:' + LineEnding + detail);
    Exit;
  end;

  // record the new submodule in config (per-submodule Paused + sync mode)
  entry.LocalName := localName;
  entry.RemoteUrl := '';
  entry.Paused := False;
  entry.AutoSync := LinkSubForm.AutoSync;   // managed by default (see the dialog)
  FConfig.UpsertRepo(entry);
  FStore.Save(FConfig);

  StartEngine;   // (re)start sync to pick up the new submodule
  Notify('GotBox', 'Linked submodule "' + localName + '".');
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
  StatusForm.OnOpenWeb := @HandleOpenWeb;
  StatusForm.OnListTags := @HandleListTags;
  StatusForm.OnAddTag := @HandleAddTag;
  StatusForm.OnSquashTags := @HandleSquashTags;
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

{ Working-tree directory for a status row: the root repo (.gotbox) IS RootDir
  itself (the folder isn't named ".gotbox"); a submodule is a path under it. }
function TMainForm.RepoDir(const ARepo: string): string;
begin
  if ARepo = GOTBOX_REPO then
    Result := ExcludeTrailingPathDelimiter(FConfig.RootDir)
  else
    // ARepo may be a relative path with '/' separators (nested submodule)
    Result := IncludeTrailingPathDelimiter(FConfig.RootDir) + SetDirSeparators(ARepo);
end;

procedure TMainForm.HandleOpenRepo(const ARepo: string);
var
  p: string;
begin
  p := RepoDir(ARepo);
  if DirectoryExists(p) then OpenDocument(p);
end;

{ Convert a git remote URL to a browsable https page, or '' if it can't be. }
function GitUrlToWeb(const AUrl: string): string;
var
  u, host, path: string;
  colon: Integer;
begin
  Result := '';
  u := Trim(AUrl);
  if u = '' then Exit;
  // drop a trailing ".git"
  if (Length(u) >= 4) and (LowerCase(Copy(u, Length(u) - 3, 4)) = '.git') then
    SetLength(u, Length(u) - 4);
  if Copy(u, 1, 8) = 'https://' then
    u := Copy(u, 9, MaxInt)
  else if Copy(u, 1, 7) = 'http://' then
    u := Copy(u, 8, MaxInt)
  else if Copy(u, 1, 6) = 'ssh://' then
    u := Copy(u, 7, MaxInt)
  else if Copy(u, 1, 4) = 'git@' then
  begin
    // scp form: git@host:owner/repo -> host/owner/repo
    u := Copy(u, 5, MaxInt);
    colon := Pos(':', u);
    if colon > 0 then u[colon] := '/';
  end
  else
    Exit;   // local path / unknown scheme -> no web page
  // strip any embedded credentials (user@ or user:pass@ before the host)
  if Pos('@', u) > 0 then u := Copy(u, Pos('@', u) + 1, MaxInt);
  // an ssh scp-form host may still carry a "host:port" -> keep just the host/path
  host := u;
  path := '';
  colon := Pos('/', host);
  if colon > 0 then
  begin
    path := Copy(host, colon, MaxInt);
    host := Copy(host, 1, colon - 1);
  end;
  if (host = '') or (path = '') then Exit;
  Result := 'https://' + host + path;
end;

procedure TMainForm.HandleOpenWeb(const ARepo: string);
var
  dir, url, web: string;
  git: TGitRunner;
begin
  dir := RepoDir(ARepo);
  if not DirectoryExists(dir) then Exit;
  git := TGitRunner.Create(dir);
  try
    url := Trim(git.GitQuiet(['config', '--get', 'remote.origin.url']).StdOut);
  finally
    git.Free;
  end;
  web := GitUrlToWeb(url);
  if web <> '' then
    OpenURL(web)
  else
    MsgInfo('No web page for this repo''s remote:' + LineEnding + url);
end;

procedure TMainForm.HandleListTags(const ARepo: string; AOut: TStrings);
var
  git: TGitRunner;
  tags: TTagInfoArray;
  i: Integer;
begin
  AOut.Clear;
  git := TGitRunner.Create(RepoDir(ARepo));
  try
    tags := ListTags(git);
  finally
    git.Free;
  end;
  for i := 0 to High(tags) do
    AOut.Add(tags[i].Label_ + '   ·   ' + tags[i].Subject +
      '   (' + tags[i].Date + ')');
end;

procedure TMainForm.HandleAddTag(const ARepo, ALabel, AMessage: string);
var
  git: TGitRunner;
  token, err, detail: string;
begin
  if not PrepareRemote(token, err) then
  begin
    MsgError('Cannot create the tag:' + LineEnding + err);
    Exit;
  end;
  Screen.Cursor := crHourGlass;
  git := TGitRunner.Create(RepoDir(ARepo));
  try
    git.AuthUser := FConfig.GithubUser;
    git.AuthToken := token;
    if not AddTag(git, ALabel, AMessage, detail) then
      MsgError('Add tag failed:' + LineEnding + detail);
  finally
    git.Free;
    Screen.Cursor := crDefault;
  end;
end;

procedure TMainForm.HandleSquashTags(const ARepo: string);
var
  git: TGitRunner;
  token, err, detail: string;
begin
  if not MsgConfirm('Squash all commits between tags in "' + ARepo + '"?' +
    LineEnding + LineEnding +
    'This REWRITES history and force-pushes. Other machines will reset to ' +
    'match on their next sync. Your tagged snapshots and the commits after the ' +
    'newest tag are preserved; the machine-stamped commits between tags are ' +
    'collapsed.') then
    Exit;
  if not PrepareRemote(token, err) then
  begin
    MsgError('Cannot squash:' + LineEnding + err);
    Exit;
  end;
  Screen.Cursor := crHourGlass;
  // stop the engine so the rewrite can't race the repo's sync worker
  StopEngine;
  try
    git := TGitRunner.Create(RepoDir(ARepo));
    try
      git.AuthUser := FConfig.GithubUser;
      git.AuthToken := token;
      if not SquashBetweenTags(git, detail) then
        MsgError('Squash failed:' + LineEnding + detail)
      else
        Notify('GotBox', 'Squashed history between tags in ' + ARepo + '.');
    finally
      git.Free;
    end;
  finally
    StartEngine;
    Screen.Cursor := crDefault;
  end;
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

procedure TMainForm.mnuEnableOverlays(Sender: TObject);
{$IFDEF WINDOWS}
var
  rc: Integer;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  rc := RunOverlayRegistration(False);   // self-elevates (one UAC prompt)
  if rc = 0 then
    MsgInfo('Explorer icon overlays enabled.' + LineEnding + LineEnding +
      'Restart Explorer (or sign out and back in) for the status badges to '
      + 'appear on files under your GotBox folder.')
  else if rc = 2 then
    MsgError('GotBoxOverlay.dll was not found next to the program, so overlays '
      + 'could not be enabled.')
  else
    MsgError('Could not enable the Explorer overlays. They require '
      + 'administrator rights -- the elevation prompt may have been declined.');
  {$ENDIF}
end;

procedure TMainForm.mnuFinderOverlays(Sender: TObject);
begin
  {$IFDEF DARWIN}
  MsgInfo('GotBox can show sync-status badges in Finder via a Finder extension.'
    + LineEnding + LineEnding
    + 'In the window that opens, enable "GotBox" under Finder extensions, then '
    + 'restart Finder (log out and back in, or run: killall Finder).'
    + LineEnding + LineEnding
    + 'Badges appear on files under your GotBox folder while GotBox is running.');
  OpenURL('x-apple.systempreferences:com.apple.ExtensionsPreferences');
  {$ENDIF}
end;

procedure TMainForm.mnuAbout(Sender: TObject);
var
  f: TForm;
  img: TImage;
  lbl: TLabel;
  btn: TButton;
  i, best, bestW, big, bigW: Integer;
begin
  f := TForm.CreateNew(nil);
  try
    f.Caption := 'About GotBox';
    f.BorderStyle := bsDialog;
    f.Position := poScreenCenter;
    f.ClientWidth := 430;
    f.ClientHeight := 400;

    img := TImage.Create(f);         // brand icon
    img.Parent := f;
    img.SetBounds(24, 20, 64, 64);
    img.Stretch := True;
    img.Proportional := True;
    if Assigned(Application.Icon) and not Application.Icon.Empty then
    begin
      img.Picture.Icon.Assign(Application.Icon);
      // Application.Icon's current frame is the tiny window/taskbar size; pick a
      // high-res frame instead (the largest up to 128px) so the icon is crisp
      // in this box rather than a small frame stretched up.
      best := -1;
      bestW := -1;
      big := 0;
      bigW := -1;
      with img.Picture.Icon do
        for i := 0 to Count - 1 do
        begin
          Current := i;
          if Width > bigW then
          begin
            bigW := Width;
            big := i;
          end;
          if (Width <= 128) and (Width > bestW) then
          begin
            bestW := Width;
            best := i;
          end;
        end;
      if best < 0 then best := big;   // no frame <=128: fall back to the largest
      img.Picture.Icon.Current := best;
    end;

    lbl := TLabel.Create(f);         // title
    lbl.Parent := f;
    lbl.SetBounds(104, 22, 300, 26);
    lbl.Font.Style := [fsBold];
    lbl.Font.Height := -18;
    lbl.Caption := 'GotBox ' + GOTBOX_VERSION;

    lbl := TLabel.Create(f);         // tagline
    lbl.Parent := f;
    lbl.SetBounds(104, 52, 300, 34);
    lbl.WordWrap := True;
    lbl.AutoSize := False;
    lbl.Caption := 'Dropbox-like file sync over your own private git repositories.';

    lbl := TLabel.Create(f);         // author / project / license
    lbl.Parent := f;
    lbl.SetBounds(24, 104, 382, 250);
    lbl.WordWrap := True;
    lbl.AutoSize := False;
    lbl.Caption :=
      'Lives in the system tray and keeps a folder in sync across your ' +
      'machines using your own private git repositories -- edit locally, ' +
      'auto-sync everywhere.' + LineEnding + LineEnding +
      'Author: Qianqian Fang <fangqq at gmail.com>' + LineEnding +
      'Project: https://github.com/fangq/GotBox' + LineEnding +
      'Issues: https://github.com/fangq/GotBox/issues' + LineEnding +
      LineEnding +
      'License: GNU General Public License, version 3 or later (GPLv3+).' +
      LineEnding + 'Distributed WITHOUT ANY WARRANTY; see LICENSE.txt.' +
      LineEnding + LineEnding +
      'Commercial use: if the GPLv3 conflicts with your use (e.g. embedding ' +
      'in closed-source software), contact the author for a separate ' +
      'commercial license.';

    btn := TButton.Create(f);
    btn.Parent := f;
    btn.Caption := 'OK';
    btn.ModalResult := mrOK;
    btn.Default := True;
    btn.SetBounds(f.ClientWidth - 106, f.ClientHeight - 40, 90, 30);

    ScaleFormUp(f);   // match the desktop's HiDPI scale (gboxmsg helper)
    f.ShowModal;
  finally
    f.Free;
  end;
end;

procedure TMainForm.mnuQuit(Sender: TObject);
begin
  Application.Terminate;
end;

end.
