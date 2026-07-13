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
  gboxdaemon, gboxlog, gboxconfigstore, gboxcredstore, gboxstatusmodel,
  gboxsuper, gboxengine, gboxrootlock, gboxfilestatus, gboxoverlayipc;

var
  GQuit: Boolean = False;

{$IFDEF UNIX}
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
  fcache: TStatusCache;
  overlay: TOverlayServer;
  token, err, detail, lockTok: string;
  owner: TLockOwner;
  hbTicks: Integer;
begin
  Result := 0;
  InitLogger(IncludeTrailingPathDelimiter(GotDataDir) + 'gotbox.log');
  Log.Info('app', 'GotBox starting (headless)');

  store := TConfigStore.Create(IncludeTrailingPathDelimiter(GotConfigDir) +
    'config.json');
  cfg := store.Load;
  status := TStatusModel.Create;
  engine := nil;
  fcache := nil;
  overlay := nil;
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

    // Cross-machine lock: never drive a working tree another GotBox instance is
    // already managing (the case that risks git corruption on a shared root).
    lockTok := NewLockToken;
    case AcquireRootLock(cfg.RootDir, cfg.MachineName, lockTok, WantTakeover, owner) of
      arHeldByOther:
      begin
        Log.Error('lock', Format('this folder is already managed by GotBox on ' +
          '"%s" (host %s, pid %d); run with --takeover to take over',
          [owner.Machine, owner.Host, owner.Pid]));
        Exit(2);
      end;
      arAcquired:
        if owner.Valid and (owner.Token <> lockTok) then
          Log.Warn('lock', Format('took over the folder from "%s"', [owner.Machine]));
    end;

    // recreate/resurrect the remote root if needed (proceed anyway on failure)
    if not EnsureGotboxRoot(cfg, token, detail) then
      Log.Warn('app', 'root reconcile: ' + detail);

    engine := TSyncEngine.Create(cfg, token, status);
    // OnNotice left nil: no desktop notifications in headless mode
    // per-file status cache + IPC server that answers file-manager overlays
    fcache := TStatusCache.Create(cfg.RootDir);
    engine.StatusCache := fcache;
    overlay := TOverlayServer.Create(fcache);
    overlay.Start;
    engine.Start;
    Log.Info('app', 'headless sync running; send SIGTERM/SIGINT to stop');

    {$IFDEF UNIX}
    FpSignal(SIGTERM, @HandleStop);
    FpSignal(SIGINT, @HandleStop);
    // `gotbox --status` sends SIGUSR1 to open the GUI's Status window; a headless
    // daemon has no window, so ignore it rather than let the default action
    // (terminate) kill the sync.
    FpSignal(SIGUSR1, SignalHandler(SIG_IGN));
    {$ENDIF}
    // CheckSynchronize (not plain Sleep) pumps the engine's submodule reconcile,
    // which it marshals via TThread.Queue (the GUI build gets this from
    // Application.Run). Every LOCK_HEARTBEAT_SEC we also refresh the root lock
    // and confirm we still hold it -- if another instance took the folder over,
    // stop, so the two never drive one working tree at once.
    hbTicks := 0;
    while not GQuit do
    begin
      CheckSynchronize(250);
      Inc(hbTicks);
      if hbTicks >= (LOCK_HEARTBEAT_SEC * 1000) div 250 then
      begin
        hbTicks := 0;
        if StillRootOwner(cfg.RootDir, lockTok) then
          RefreshRootLock(cfg.RootDir, cfg.MachineName, lockTok)
        else
        begin
          Log.Warn('lock',
            'another GotBox instance took over this folder; stopping');
          GQuit := True;
        end;
      end;
    end;
    Log.Info('app', 'stopping; shutting down');
  finally
    ReleaseRootLock(cfg.RootDir, lockTok);   // free the lock before cfg is gone
    overlay.Free;  // stop + join the overlay server before the cache it reads
    engine.Free;   // TSyncEngine.Destroy stops + joins the workers (nil-safe)
    fcache.Free;
    status.Free;
    cfg.Free;
    store.Free;
  end;
end;

end.
