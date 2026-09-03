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

program testlog;

{ The log file is size-capped (gboxlog): GotBox runs for weeks and traces every
  git invocation, so an uncapped log is the largest thing the app owns. Verifies
  that the file rolls to a single ".1" generation, that only one generation is
  kept however many times it rolls, that an already-oversized file left by a
  previous run is rolled at startup, and that the in-memory ring the status
  window reads is unaffected by any of it.

  Uses a tiny cap instead of the real 8 MB one, so the mechanism is exercised
  without writing megabytes. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  gboxlog;

var
  failures: Integer = 0;

  procedure Check(ACond: Boolean; const AName: string);
  begin
    if ACond then WriteLn('  ok   - ', AName)
    else
    begin
      WriteLn('  FAIL - ', AName);
      Inc(failures);
    end;
  end;

  function Bytes(const APath: string): Int64;
  var
    f: TFileStream;
  begin
    Result := -1;
    if not FileExists(APath) then Exit;
    f := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      Result := f.Size;
    finally
      f.Free;
    end;
  end;

  function Contains(const APath, ASubstr: string): Boolean;
  var
    sl: TStringList;
  begin
    Result := False;
    if not FileExists(APath) then Exit;
    sl := TStringList.Create;
    try
      sl.LoadFromFile(APath);
      Result := Pos(ASubstr, sl.Text) > 0;
    finally
      sl.Free;
    end;
  end;

var
  base, path, prev: string;
  lg: TLogger;
  ring: TStringList;
  i: Integer;
const
  CAP = 4096;   // stand-in for LOG_MAX_BYTES

begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-log-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  ForceDirectories(base);
  path := IncludeTrailingPathDelimiter(base) + 'gotbox.log';
  prev := path + '.1';
  WriteLn('workspace: ', base);

  // ---- rolls once past the cap, keeping the old content in .1 ---------------
  lg := TLogger.Create(path, 500, CAP);
  try
    lg.Info('t', 'FIRST-LINE-MARKER');
    // pad only until the FIRST roll happens: keep going and the marker ages out
    // of .1 too, which is correct behaviour but not what this case is checking
    i := 0;
    while (not FileExists(prev)) and (i < 5000) do
    begin
      Inc(i);
      lg.Info('t', 'padding line ' + IntToStr(i) + StringOfChar('x', 40));
    end;
    Check(FileExists(prev), 'the log rolled to a .1 generation');
    Check(Contains(prev, 'FIRST-LINE-MARKER'),
      'the rolled-out generation keeps the earlier lines');
    Check(Bytes(path) < CAP, 'the live log is back under the cap');
    Check(not Contains(path, 'FIRST-LINE-MARKER'),
      'the live log started fresh');

    // ---- the ring the status window reads is independent of the file --------
    ring := lg.Snapshot;
    try
      Check(ring.Count > 0, 'the in-memory ring survives a roll');
    finally
      ring.Free;
    end;

    // ---- many rolls still leave exactly one old generation ------------------
    for i := 1 to 2000 do
      lg.Info('t', 'more padding ' + IntToStr(i) + StringOfChar('y', 40));
    Check(FileExists(path) and FileExists(prev), 'both generations exist');
    Check(not FileExists(path + '.2'), 'only ONE old generation is kept');
    Check((Bytes(path) < CAP * 2) and (Bytes(prev) < CAP * 2),
      'neither generation grows without bound');
  finally
    lg.Free;
  end;

  // ---- an oversized file left by a previous run is rolled at startup --------
  DeleteFile(path);
  DeleteFile(prev);
  with TStringList.Create do
  try
    for i := 1 to 200 do Add('stale line ' + IntToStr(i) + StringOfChar('z', 40));
    SaveToFile(path);
  finally
    Free;
  end;
  Check(Bytes(path) > CAP, 'setup: a stale oversized log is in place');
  lg := TLogger.Create(path, 500, CAP);
  try
    Check(FileExists(prev), 'an oversized log from a previous run rolls at startup');
    Check(Bytes(path) < CAP, 'and the new run starts from an empty file');
  finally
    lg.Free;
  end;

  // ---- a zero/negative cap disables rolling (never surprises an embedder) ---
  DeleteFile(path);
  DeleteFile(prev);
  lg := TLogger.Create(path, 500, 0);
  try
    for i := 1 to 200 do
      lg.Info('t', 'uncapped ' + IntToStr(i) + StringOfChar('w', 40));
    Check(not FileExists(prev), 'a cap of 0 disables rolling');
  finally
    lg.Free;
  end;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
