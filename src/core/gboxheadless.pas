unit gboxheadless;

{ GUI-free entry point for the sync engine: load config, resolve credentials,
  reconcile the .gotbox root, start the engine, then block until a termination
  signal arrives. Uses only core units (no LCL/widgetset), so a binary built
  around it runs with no X server -- over plain SSH or on a headless host.

  This mirrors the non-UI half of TMainForm's startup (PrepareRemote +
  EnsureGotboxRoot + TSyncEngine.Start); it cannot prompt, so missing setup is
  reported and treated as a hard error rather than opening a dialog. }

{$mode objfpc}{$H+}

interface

{ Run the sync engine to completion (until SIGTERM/SIGINT). Returns a process
  exit code: 0 on a clean stop, non-zero if it could not start. }
function RunHeadless: Integer;

implementation

uses
  Classes, SysUtils,
  {$IFDEF UNIX}BaseUnix, ctypes,{$ENDIF}
  gboxlog, gboxconfigstore, gboxcredstore, gboxstatusmodel,
  gboxsuper, gboxengine;

{$IFDEF UNIX}
var
  GQuit: Boolean = False;

procedure HandleStop(sig: cint); cdecl;
begin
  GQuit := True;
end;
{$ENDIF}

{ Resolve the remote credentials the way the GUI's PrepareRemote does. Returns
  False with AErr set when the app isn't configured enough to sync. }
function ResolveRemote(ACfg: TGotConfig; out AToken, AErr: string): Boolean;
var
  cred: TCredStore;
begin
  AToken := '';
  AErr := '';
  Result := False;
  if SameText(ACfg.RemoteKind, 'git') then
  begin
    if ACfg.SshBase = '' then
    begin
      AErr := 'self-hosted git base URL not set';
      Exit;
    end;
    Exit(True);   // ssh key auth -- no token needed
  end;
  // github backend
  if ACfg.GithubUser = '' then
  begin
    AErr := 'no GitHub account configured';
    Exit;
  end;
  cred := TCredStore.Create;
  try
    if not cred.LoadToken(ACfg.GithubUser, AToken) then
    begin
      AErr := 'no stored token found (sign in once via the GUI, ' +
        'or ensure the login keyring is unlocked)';
      Exit;
    end;
  finally
    cred.Free;
  end;
  Result := True;
end;

function RunHeadless: Integer;
var
  store: TConfigStore;
  cfg: TGotConfig;
  status: TStatusModel;
  engine: TSyncEngine;
  token, err, detail: string;
begin
  Result := 0;
  InitLogger(IncludeTrailingPathDelimiter(GotDataDir) + 'gotbox.log');
  Log.Info('app', 'GotBox starting (headless)');

  store := TConfigStore.Create(IncludeTrailingPathDelimiter(GotConfigDir) +
    'config.json');
  cfg := store.Load;
  status := TStatusModel.Create;
  engine := nil;
  try
    // headless can't prompt, so unconfigured setup is a hard error
    if (cfg.RootDir = '') or (not DirectoryExists(cfg.RootDir)) then
    begin
      Log.Error('app', 'root folder not set or missing (' + cfg.RootDir +
        '); configure GotBox in the GUI once first');
      Exit(1);
    end;
    if not IsGitWorkTree(cfg.RootDir) then
    begin
      Log.Error('app', '.gotbox root not initialized at ' + cfg.RootDir +
        '; run the GUI once to set it up');
      Exit(1);
    end;
    if not ResolveRemote(cfg, token, err) then
    begin
      Log.Error('app', 'cannot start sync: ' + err);
      Exit(1);
    end;

    // recreate/resurrect the remote root if needed (proceed anyway on failure)
    if not EnsureGotboxRoot(cfg, token, detail) then
      Log.Warn('app', 'root reconcile: ' + detail);

    engine := TSyncEngine.Create(cfg, token, status);
    // OnNotice left nil: no desktop notifications in headless mode
    engine.Start;
    Log.Info('app', 'headless sync running; send SIGTERM/SIGINT to stop');

    // CheckSynchronize (not plain Sleep) so queued cross-thread callbacks run
    // on this main thread: the engine marshals its submodule reconcile via
    // TThread.Queue (the GUI build gets this from Application.Run), so without a
    // pump here gotboxd would never react to a submodule added/removed on
    // another machine while it keeps running.
    {$IFDEF UNIX}
    FpSignal(SIGTERM, @HandleStop);
    FpSignal(SIGINT, @HandleStop);
    while not GQuit do
      CheckSynchronize(250);
    Log.Info('app', 'stop signal received; shutting down');
    {$ELSE}
    // no POSIX signals: block indefinitely (stopped by killing the process)
    while True do
      CheckSynchronize(1000);
    {$ENDIF}
  finally
    engine.Free;   // TSyncEngine.Destroy stops + joins the workers (nil-safe)
    status.Free;
    cfg.Free;
    store.Free;
  end;
end;

end.
