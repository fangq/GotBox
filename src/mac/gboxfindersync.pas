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

unit gboxfindersync;

{ macOS Finder Sync extension (the Dropbox/TortoiseGit-style status badges).
  This is the principal class of GotBoxFinder.appex, which Finder loads in its
  own process. It watches the GotBox root and, for each file/folder Finder asks
  about, queries the running GotBox process over the existing local socket
  (gboxoverlayipc.OverlayQuery) and sets a synced/modified/conflict badge.

  The query is timeout-bounded and fully guarded, so a missing or slow GotBox
  service can never hang Finder -- it just yields no badge (same fail-safe as the
  Windows overlay DLL). Written in FPC Objective-Pascal; builds on macOS only.

  FinderSync.framework has no FPC bindings, so the two classes we touch
  (FIFinderSync, FIFinderSyncController) are declared here as external
  objcclasses -- same technique as the CoreServices/CoreFoundation externals in
  gboxfilewatcher.pas. }

{$mode objfpc}{$H+}
{$modeswitch objectivec1}
{$linkframework FinderSync}

interface

uses
  CocoaAll;

type
  { The controller singleton the extension talks to (set watched folders, define
    and apply badges). Only the methods we use are declared. }
  FIFinderSyncController = objcclass external (NSObject)
  public
    class function defaultController: FIFinderSyncController;
      message 'defaultController';
    procedure setDirectoryURLs(urls: NSSet); message 'setDirectoryURLs:';
    procedure setBadgeImage_label_forBadgeIdentifier(image: NSImage;
      alabel: NSString; badgeID: NSString);
      message 'setBadgeImage:label:forBadgeIdentifier:';
    procedure setBadgeIdentifier_forURL(badgeID: NSString; url: NSURL);
      message 'setBadgeIdentifier:forURL:';
  end;

  { Base class provided by the framework; we override the badge-request hook. }
  FIFinderSync = objcclass external (NSObject)
  public
    procedure requestBadgeIdentifierForURL(url: NSURL);
      message 'requestBadgeIdentifierForURL:';
  end;

  { GotBox's principal class -- named in GotBoxFinder-Info.plist's
    NSExtensionPrincipalClass so NSExtensionMain can instantiate it. }
  GotBoxFinderSync = objcclass(FIFinderSync)
  public
    function init: id; override; message 'init';
    procedure requestBadgeIdentifierForURL(url: NSURL); override;
      message 'requestBadgeIdentifierForURL:';
  end;

implementation

uses
  SysUtils, gboxfilestatus, gboxoverlayipc, gboxconfigstore;

const
  BADGE_SYNCED = 'synced';
  BADGE_MODIFIED = 'modified';
  BADGE_CONFLICT = 'conflict';

function S(const AStr: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(AStr));
end;

{ The GotBox sync root the config points at (fallback: the default ~/GotBox).
  Read the same config.json the app writes; never raise. }
function CurrentRootDir: string;
var
  store: TConfigStore;
  cfg: TGotConfig;
begin
  Result := DefaultRootDir;
  try
    store := TConfigStore.Create(IncludeTrailingPathDelimiter(GotConfigDir) +
      'config.json');
    try
      cfg := store.Load;
      try
        if cfg.RootDir <> '' then
          Result := cfg.RootDir;
      finally
        cfg.Free;
      end;
    finally
      store.Free;
    end;
  except
  end;
end;

{ Load a badge PNG from the extension bundle's Resources and register it. }
procedure RegisterBadge(ctrl: FIFinderSyncController;
  const AId, AFile, ALabel: string);
var
  res: NSString;
  img: NSImage;
begin
  res := NSBundle.mainBundle.resourcePath;
  if res = nil then
    Exit;
  img := NSImage(NSImage.alloc).initWithContentsOfFile(
    res.stringByAppendingPathComponent(S(AFile)));
  if img <> nil then
    ctrl.setBadgeImage_label_forBadgeIdentifier(img, S(ALabel), S(AId));
end;

{ ---- GotBoxFinderSync ---- }

function GotBoxFinderSync.init: id;
var
  ctrl: FIFinderSyncController;
  urls: NSSet;
begin
  Result := inherited init;
  if Result = nil then
    Exit;
  ctrl := FIFinderSyncController.defaultController;
  if ctrl = nil then
    Exit;
  RegisterBadge(ctrl, BADGE_SYNCED, 'overlay-synced.png', 'Synced');
  RegisterBadge(ctrl, BADGE_MODIFIED, 'overlay-modified.png', 'Modified');
  RegisterBadge(ctrl, BADGE_CONFLICT, 'overlay-conflict.png', 'Conflict');
  // watch the GotBox root (Finder only asks about paths inside these)
  urls := NSSet.setWithObject(NSURL.fileURLWithPath(S(CurrentRootDir)));
  ctrl.setDirectoryURLs(urls);
end;

procedure GotBoxFinderSync.requestBadgeIdentifierForURL(url: NSURL);
var
  path, bid: string;
  st: TFileState;
  ctrl: FIFinderSyncController;
begin
  try
    if url = nil then
      Exit;
    path := string(url.path.UTF8String);
    st := OverlayQuery(path, '', 300);   // bounded; fsNone on any failure
    case st of
      fsSynced: bid := BADGE_SYNCED;
      fsModified: bid := BADGE_MODIFIED;
      fsConflict: bid := BADGE_CONFLICT;
      else
        Exit;                            // fsNone -> leave unbadged
    end;
    ctrl := FIFinderSyncController.defaultController;
    if ctrl <> nil then
      ctrl.setBadgeIdentifier_forURL(S(bid), url);
  except
    // never let an exception escape into Finder's process
  end;
end;

end.
