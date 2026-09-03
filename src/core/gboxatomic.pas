{
  GotBox -- Cross-machine file sync over your own private git repositories.
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

unit gboxatomic;

{ All-or-nothing file writes.

  Every file GotBox owns is read by someone else while it is being written -- git
  reads info/exclude while a cycle rewrites it, another machine's heartbeat reads
  the root lock, and the app itself re-reads its config after a settings change.
  A plain SaveToFile truncates first and writes second, so any reader landing in
  that window sees an empty or half-written file. For the exclude blocks that
  means git briefly sees no rules and can commit exactly what the rules exist to
  keep out; for config.json or the credential file it means a crash or power cut
  in that window loses the user's setup outright.

  Writing to a sibling temp file and renaming it over the target closes the
  window: rename is atomic on POSIX, so a reader gets either the whole old file
  or the whole new one.

  AOwnerOnly chmods the TEMP file before the rename, so a file holding a secret
  is never briefly visible at the process umask -- unlike chmod-after-write,
  which always leaves that gap. LCL-free. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

{ Write ALines to APath atomically. Returns False (leaving any existing file
  untouched) if the write or the rename failed. }
function AtomicSaveLines(ALines: TStrings; const APath: string;
  AOwnerOnly: Boolean = False): Boolean;

{ Write AText to APath atomically. }
function AtomicSaveText(const AText, APath: string;
  AOwnerOnly: Boolean = False): Boolean;

implementation

uses
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  gboxlog;

var
  TmpCounter: Integer = 0;

{ A temp name in the target's own directory -- the rename has to stay on one
  filesystem to be atomic, so a system temp dir is not an option. PID plus a
  counter keeps two processes (and two threads) from picking the same name. }
function TempNameFor(const APath: string): string;
var
  pid: Integer;
begin
  {$IFDEF UNIX}
  pid := FpGetpid;
  {$ELSE}
  {$IFDEF WINDOWS}
  pid := GetCurrentProcessId;
  {$ELSE}
  pid := 0;
  {$ENDIF}
  {$ENDIF}
  Inc(TmpCounter);
  Result := APath + '.' + IntToHex(pid, 4) + IntToHex(TmpCounter, 4) + '.tmp';
end;

function AtomicSaveLines(ALines: TStrings; const APath: string;
  AOwnerOnly: Boolean): Boolean;
var
  tmp: string;
begin
  Result := False;
  if (ALines = nil) or (APath = '') then Exit;
  ForceDirectories(ExtractFilePath(APath));
  tmp := TempNameFor(APath);
  try
    ALines.SaveToFile(tmp);
    if AOwnerOnly then
    begin
      {$IFDEF UNIX}
      // tighten the temp file BEFORE it becomes the real one
      FpChmod(tmp, &600);
      {$ENDIF}
    end;
    {$IFDEF WINDOWS}
    // POSIX rename() replaces atomically; Win32 RenameFile fails if the target
    // exists, so drop it first. That reintroduces a brief no-file gap on Windows
    // only -- still better than a torn file, and every reader here treats a
    // missing file as "nothing yet" rather than as corruption.
    if FileExists(APath) then DeleteFile(APath);
    {$ENDIF}
    Result := RenameFile(tmp, APath);
  except
    Result := False;
  end;
  if not Result then
  begin
    DeleteFile(tmp);
    if Assigned(Log) then
      Log.Warn('io', 'could not write ' + APath + ' atomically; left unchanged');
  end;
end;

function AtomicSaveText(const AText, APath: string; AOwnerOnly: Boolean): Boolean;
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Text := AText;
    Result := AtomicSaveLines(sl, APath, AOwnerOnly);
  finally
    sl.Free;
  end;
end;

end.
