{
  GotBox -- Dropbox-like file sync over your own private git repositories.
  Copyright (C) 2026 Qianqian Fang <q.fang@northeastern.edu> and contributors.

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

unit gboxrootlock;

{ Cooperative "who is managing this root" lock, so two GotBox instances (GUI or
  headless) can't drive the same working tree at once -- the case that risks git
  corruption when a root lives on a shared/network folder. The per-machine
  single-instance guard (gboxdaemon) can't see across machines; this one can,
  because the lock file lives inside the root's own .git.

  It is ADVISORY, not a hard mutex: a heartbeat timestamp lets a crashed owner's
  lock be reclaimed after it goes stale, and a running owner detects a takeover
  by noticing its token is no longer on disk (then pauses itself). Ownership is
  identified by a random per-acquisition TOKEN, not the pid, so a reused pid
  can't be mistaken for the same instance.

  The lock file is <root>/.git/gotbox-owner -- never in the working tree, so it
  is never committed or synced. On the normal one-clone-per-machine setup .git
  is local, so the lock is naturally per-machine; on a shared root it is the
  shared coordination point. LCL-free: used by both gotbox and gotboxd. }

{$mode objfpc}{$H+}

interface

type
  TLockOwner = record
    Valid: Boolean;      // False when there is no (readable) lock
    Machine: string;     // the owner's configured machine name
    Host: string;        // OS hostname (informational)
    Pid: Integer;        // owner pid (informational)
    Token: string;       // unique per acquisition -- the real identity
    Heartbeat: Int64;    // unix seconds of the last refresh
  end;

  TAcquireResult = (arAcquired, arHeldByOther, arNoRoot);

const
  LOCK_HEARTBEAT_SEC = 30;   // how often an owner should refresh the lock
  LOCK_STALE_SEC = 90;       // a lock older than this is considered abandoned

{ A fresh, unique token for this acquisition. }
function NewLockToken: string;

{ Path of the lock file for ARoot (inside .git). }
function RootLockPath(const ARoot: string): string;

{ Current owner; Valid=False if none/unreadable or ARoot has no .git. }
function ReadRootOwner(const ARoot: string): TLockOwner;

{ True if AOwner's heartbeat is older than LOCK_STALE_SEC (or invalid). }
function OwnerIsStale(const AOwner: TLockOwner): Boolean;

{ Try to become the manager of ARoot. Acquires (writes our token) when the lock
  is free, stale, already ours, or ATakeover is set; otherwise returns
  arHeldByOther and leaves the existing lock untouched (AOwner describes it). }
function AcquireRootLock(const ARoot, AMachine, AToken: string;
  ATakeover: Boolean; out AOwner: TLockOwner): TAcquireResult;

{ Refresh our heartbeat (write our token + now). Call ~every LOCK_HEARTBEAT_SEC. }
function RefreshRootLock(const ARoot, AMachine, AToken: string): Boolean;

{ True if the on-disk owner token still equals AToken (we haven't been taken
  over). False also means "someone else took over" -- pause yourself. }
function StillRootOwner(const ARoot, AToken: string): Boolean;

{ Delete the lock iff we still own it (safe to call on shutdown). }
procedure ReleaseRootLock(const ARoot, AToken: string);

implementation

uses
  Classes, SysUtils, DateUtils
  {$IFDEF UNIX}, BaseUnix{$ENDIF}
  {$IFDEF WINDOWS}, Windows{$ENDIF};

function NowUnix: Int64;
begin
  Result := DateTimeToUnix(Now, False);   // treat Now as local -> real UTC secs
end;

function SelfPid: Integer;
begin
  {$IFDEF UNIX}
  Result := FpGetpid;
  {$ELSE}
  {$IFDEF WINDOWS}
  Result := GetCurrentProcessId;
  {$ELSE}
  Result := 0;
  {$ENDIF}
  {$ENDIF}
end;

function HostName: string;
begin
  {$IFDEF WINDOWS}
  Result := GetEnvironmentVariable('COMPUTERNAME');
  {$ELSE}
  Result := GetEnvironmentVariable('HOSTNAME');
  {$ENDIF}
  if Result = '' then Result := 'host';
end;

function NewLockToken: string;
begin
  // random + pid + time: unique per acquisition (identity survives pid reuse)
  Result := IntToHex(Random($7FFFFFFF), 8) + '-' + IntToHex(SelfPid, 4) +
    '-' + IntToHex(NowUnix, 10);
end;

function RootLockPath(const ARoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ARoot) + '.git' + PathDelim + 'gotbox-owner';
end;

function ReadRootOwner(const ARoot: string): TLockOwner;
var
  sl: TStringList;
  p: string;
begin
  Result := Default(TLockOwner);
  p := RootLockPath(ARoot);
  if not FileExists(p) then Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(p);
    except
      Exit;   // unreadable/half-written -> treat as no lock
    end;
    Result.Machine := sl.Values['machine'];
    Result.Host := sl.Values['host'];
    Result.Pid := StrToIntDef(sl.Values['pid'], 0);
    Result.Token := sl.Values['token'];
    Result.Heartbeat := StrToInt64Def(sl.Values['heartbeat'], 0);
    // a lock with no token is meaningless; ignore it
    Result.Valid := Result.Token <> '';
  finally
    sl.Free;
  end;
end;

function OwnerIsStale(const AOwner: TLockOwner): Boolean;
begin
  Result := (not AOwner.Valid) or (NowUnix - AOwner.Heartbeat > LOCK_STALE_SEC);
end;

function WriteOwner(const ARoot, AMachine, AToken: string): Boolean;
var
  sl: TStringList;
begin
  Result := False;
  // no .git -> nothing to coordinate (root not set up yet)
  if not DirectoryExists(IncludeTrailingPathDelimiter(ARoot) + '.git') then Exit;
  sl := TStringList.Create;
  try
    sl.Add('machine=' + AMachine);
    sl.Add('host=' + HostName);
    sl.Add('pid=' + IntToStr(SelfPid));
    sl.Add('token=' + AToken);
    sl.Add('heartbeat=' + IntToStr(NowUnix));
    try
      sl.SaveToFile(RootLockPath(ARoot));
      Result := True;
    except
      Result := False;
    end;
  finally
    sl.Free;
  end;
end;

function AcquireRootLock(const ARoot, AMachine, AToken: string;
  ATakeover: Boolean; out AOwner: TLockOwner): TAcquireResult;
begin
  AOwner := Default(TLockOwner);
  if not DirectoryExists(IncludeTrailingPathDelimiter(ARoot) + '.git') then
    Exit(arNoRoot);
  AOwner := ReadRootOwner(ARoot);
  if AOwner.Valid and (not OwnerIsStale(AOwner)) and (AOwner.Token <> AToken) and
    (not ATakeover) then
    Exit(arHeldByOther);
  if WriteOwner(ARoot, AMachine, AToken) then
    Result := arAcquired
  else
    Result := arHeldByOther;   // couldn't write -> behave as not-ours
end;

function RefreshRootLock(const ARoot, AMachine, AToken: string): Boolean;
begin
  Result := WriteOwner(ARoot, AMachine, AToken);
end;

function StillRootOwner(const ARoot, AToken: string): Boolean;
var
  o: TLockOwner;
begin
  o := ReadRootOwner(ARoot);
  Result := o.Valid and (o.Token = AToken);
end;

procedure ReleaseRootLock(const ARoot, AToken: string);
begin
  if StillRootOwner(ARoot, AToken) then
    DeleteFile(RootLockPath(ARoot));
end;

initialization
  Randomize;

end.
