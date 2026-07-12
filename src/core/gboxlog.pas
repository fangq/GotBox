unit gboxlog;

{ Thread-safe logger: appends to a rotating file and keeps an in-memory ring
  buffer that the status window can display. Safe to call from any thread. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs;

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
    procedure WriteLine(const ALine: string);
  public
    constructor Create(const ALogPath: string; ARingMax: Integer = 500);
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

constructor TLogger.Create(const ALogPath: string; ARingMax: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRing := TStringList.Create;
  FRingMax := ARingMax;
  FPath := ALogPath;
  FFileOpen := False;
  try
    ForceDirectories(ExtractFileDir(FPath));
    AssignFile(FFile, FPath);
    if FileExists(FPath) then
      Append(FFile)
    else
      Rewrite(FFile);
    FFileOpen := True;
  except
    { logging must never crash the app; fall back to ring-only }
    FFileOpen := False;
  end;
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
