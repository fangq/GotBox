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

unit gboxlog;

{ Thread-safe logger: appends to a size-capped file and keeps an in-memory ring
  buffer that the status window can display. Safe to call from any thread.

  The file really is capped, which matters because GotBox runs for weeks at a
  time and traces every git invocation: at LOG_MAX_BYTES it is rolled to a single
  ".1" generation and started fresh, so the logs occupy at most twice that and
  the previous run's tail survives long enough to diagnose whatever just went
  wrong. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs;

const
  { Roll the log at this size, keeping one previous generation. }
  LOG_MAX_BYTES = Int64(8) * 1024 * 1024;

type
  TLogLevel = (llDebug, llInfo, llWarn, llError);

  TLogger = class
  private
    FLock: TCriticalSection;
    FFile: TextFile;
    FFileOpen: Boolean;
    FPath: string;
    FRing: TStringList;
    FRingMax: Integer;
    FBytes: Int64;             { bytes in the open file; drives the roll }
    FMaxBytes: Int64;          { roll at this size (only tests pass anything else) }
    procedure OpenFile;
    procedure RollIfLarge;
    procedure WriteLine(const ALine: string);
  public
    constructor Create(const ALogPath: string; ARingMax: Integer = 500;
      AMaxBytes: Int64 = LOG_MAX_BYTES);
    destructor Destroy; override;
    procedure Log(ALevel: TLogLevel; const AScope, AMsg: string);
    procedure Debug(const AScope, AMsg: string);
    procedure Info(const AScope, AMsg: string);
    procedure Warn(const AScope, AMsg: string);
    procedure Error(const AScope, AMsg: string);
    { Returns a snapshot copy of recent log lines (caller frees). }
    function Snapshot: TStringList;
    { Path of the on-disk log file (for "Export log"). }
    property Path: string read FPath;
  end;

var
  { Global logger instance, created by InitLogger during startup. }
  Log: TLogger = nil;

procedure InitLogger(const ALogPath: string);
procedure DoneLogger;

implementation

const
  LevelStr: array[TLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');

procedure InitLogger(const ALogPath: string);
begin
  if Log = nil then
    Log := TLogger.Create(ALogPath);
end;

procedure DoneLogger;
begin
  FreeAndNil(Log);
end;

constructor TLogger.Create(const ALogPath: string; ARingMax: Integer; AMaxBytes: Int64);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRing := TStringList.Create;
  FRingMax := ARingMax;
  FPath := ALogPath;
  FMaxBytes := AMaxBytes;
  FFileOpen := False;
  OpenFile;
  RollIfLarge;   // a log left oversized by an earlier run is rolled at startup
end;

{ Size of APath, or 0 when it does not exist / can't be read. }
function FileBytes(const APath: string): Int64;
var
  sr: TSearchRec;
begin
  Result := 0;
  if FindFirst(APath, faAnyFile, sr) = 0 then
  begin
    if (sr.Attr and faDirectory) = 0 then Result := sr.Size;
    SysUtils.FindClose(sr);
  end;
end;

procedure TLogger.OpenFile;
begin
  try
    ForceDirectories(ExtractFileDir(FPath));
    AssignFile(FFile, FPath);
    if FileExists(FPath) then
      Append(FFile)
    else
      Rewrite(FFile);
    FFileOpen := True;
    FBytes := FileBytes(FPath);
  except
    { logging must never crash the app; fall back to ring-only }
    FFileOpen := False;
    FBytes := 0;
  end;
end;

{ Roll to a single ".1" generation once the file passes the cap. Caller holds
  the lock (or is the constructor, before anything else can log). }
procedure TLogger.RollIfLarge;
var
  prev: string;
begin
  if (FMaxBytes <= 0) or (FBytes < FMaxBytes) then Exit;
  prev := FPath + '.1';
  try
    if FFileOpen then
    begin
      CloseFile(FFile);
      FFileOpen := False;
    end;
    DeleteFile(prev);            // only one generation is kept
    RenameFile(FPath, prev);
  except
    { a failed roll must not take the app down: fall through and reopen }
  end;
  OpenFile;
end;

destructor TLogger.Destroy;
begin
  FLock.Enter;
  try
    if FFileOpen then
      CloseFile(FFile);
  except
  end;
  FLock.Leave;
  FRing.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TLogger.WriteLine(const ALine: string);
begin
  if FFileOpen then
  begin
    try
      WriteLn(FFile, ALine);
      Flush(FFile);
      // count rather than stat: this runs on every line, and a git-traced
      // session writes a great many of them
      Inc(FBytes, Length(ALine) + 2);
      RollIfLarge;
    except
      FFileOpen := False;
    end;
  end;
  FRing.Add(ALine);
  while FRing.Count > FRingMax do
    FRing.Delete(0);
end;

procedure TLogger.Log(ALevel: TLogLevel; const AScope, AMsg: string);
var
  line: string;
begin
  line := Format('%s [%-5s] %-12s %s',
    [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), LevelStr[ALevel], AScope, AMsg]);
  FLock.Enter;
  try
    WriteLine(line);
  finally
    FLock.Leave;
  end;
end;

procedure TLogger.Debug(const AScope, AMsg: string);
begin
  Log(llDebug, AScope, AMsg);
end;

procedure TLogger.Info(const AScope, AMsg: string);
begin
  Log(llInfo, AScope, AMsg);
end;

procedure TLogger.Warn(const AScope, AMsg: string);
begin
  Log(llWarn, AScope, AMsg);
end;

procedure TLogger.Error(const AScope, AMsg: string);
begin
  Log(llError, AScope, AMsg);
end;

function TLogger.Snapshot: TStringList;
begin
  Result := TStringList.Create;
  FLock.Enter;
  try
    Result.Assign(FRing);
  finally
    FLock.Leave;
  end;
end;

end.
