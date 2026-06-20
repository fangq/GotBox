unit gboxgitrunner;

{ Wrapper around the system `git` CLI via TProcess. The Git/porcelain calls are
  synchronous and blocking -- they are meant to be called from a worker thread
  (RepoWorker, milestone 5), never the GUI thread. Credentials are supplied
  non-interactively by setting
  GIT_TERMINAL_PROMPT=0 and relying on a configured credential helper / token
  remote, so git never blocks waiting for a password. }

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, Process;

type
  TGitResult = record
    ExitCode: Integer;
    StdOut: string;
    StdErr: string;
    function Ok: Boolean;
  end;

  TGitRunner = class
  private
    FGitExe: string;
    FWorkDir: string;
    FAuthUser: string;
    FAuthToken: string;
    function Run(const AArgs: array of string): TGitResult;
    function EnsureAskPass: string;
  public
    { AWorkDir is the repo working tree (may be empty for clone/global ops). }
    constructor Create(const AWorkDir: string);
    { Locates the git executable on PATH and common install dirs.
      Returns '' if not found. }
    class function DetectGit: string;
    class function GitAvailable: Boolean;

    property GitExe: string read FGitExe write FGitExe;
    property WorkDir: string read FWorkDir write FWorkDir;

    { GitHub user + PAT for non-interactive HTTPS auth. When AuthToken is set,
      git calls are run with a GIT_ASKPASS helper that returns the token from an
      environment variable -- the secret is never written into a file. The user
      is taken from the remote URL (https://user@github.com/...). }
    property AuthUser: string read FAuthUser write FAuthUser;
    property AuthToken: string read FAuthToken write FAuthToken;

    // raw passthrough
    function Git(const AArgs: array of string): TGitResult;

    // common porcelain helpers
    function Version: TGitResult;
    function InitRepo: TGitResult;
    function Clone(const AUrl, ADest: string): TGitResult;
    function AddAll: TGitResult;
    function CommitAll(const AMessage: string): TGitResult;
    function Push(AForce: Boolean = False): TGitResult;
    function Fetch: TGitResult;
    function PullRebase: TGitResult;
    function Merge(const ARef: string): TGitResult;
    function CountRange(const ARange: string): Integer; // commits in ARange (-1 err)
    function ShowStage(AStage: Integer; const APath: string): TGitResult;
    function CheckoutTheirs(const APath: string): TGitResult;
    function AddPath(const APath: string): TGitResult;
    function StatusPorcelain: TGitResult;
    function RevParse(const ARef: string): TGitResult;
    function Gc: TGitResult;
    function Stash: TGitResult;
    function StashPop: TGitResult;
    function ResetHard(const ARef: string): TGitResult;
    function SetRemote(const AName, AUrl: string): TGitResult;
    function CurrentBranch: string;

    // helpers built on the porcelain
    function HasUncommittedChanges: Boolean;
    function CountCommits: Integer; // number of commits on HEAD (-1 on error)
  end;

implementation

uses
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  gboxlog;

{ Writes (once) a tiny GIT_ASKPASS helper that echoes the token from the
  GOTBOX_ASKPASS_PW environment variable, and returns its path. The helper file
  itself contains no secret. }
function TGitRunner.EnsureAskPass: string;
var
  sl: TStringList;
begin
  {$IFDEF WINDOWS}
  Result := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-askpass.cmd';
  {$ELSE}
  Result := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-askpass.sh';
  {$ENDIF}
  if FileExists(Result) then Exit;
  sl := TStringList.Create;
  try
    {$IFDEF WINDOWS}
    sl.Add('@echo off');
    sl.Add('echo %GOTBOX_ASKPASS_PW%');
  {$ELSE}
    sl.Add('#!/bin/sh');
    sl.Add('printf ''%s'' "$GOTBOX_ASKPASS_PW"');
  {$ENDIF}
    sl.SaveToFile(Result);
  finally
    sl.Free;
  end;
  {$IFDEF UNIX}
  FpChmod(Result, &755);
  {$ENDIF}
end;

function TGitResult.Ok: Boolean;
begin
  Result := ExitCode = 0;
end;

{ ---- detection ---- }

class function TGitRunner.DetectGit: string;
var
  candidates: array of string;
  i: Integer;
  found: string;
begin
  Result := '';
  // 1) on PATH
  {$IFDEF WINDOWS}
  found := FileSearch('git.exe', GetEnvironmentVariable('PATH'));
  {$ELSE}
  found := FileSearch('git', GetEnvironmentVariable('PATH'));
  {$ENDIF}
  if found <> '' then Exit(found);

  // 2) common install locations
  {$IFDEF WINDOWS}
  candidates := [
    'C:\Program Files\Git\cmd\git.exe',
    'C:\Program Files (x86)\Git\cmd\git.exe',
    'C:\Program Files\TortoiseGit\bin\git.exe'
  ];
  {$ELSE}
  {$IFDEF DARWIN}
  candidates := ['/usr/bin/git', '/usr/local/bin/git', '/opt/homebrew/bin/git'];
  {$ELSE}
  candidates := ['/usr/bin/git', '/usr/local/bin/git', '/bin/git'];
  {$ENDIF}
  {$ENDIF}
  for i := 0 to High(candidates) do
    if FileExists(candidates[i]) then
      Exit(candidates[i]);
end;

class function TGitRunner.GitAvailable: Boolean;
begin
  Result := DetectGit <> '';
end;

{ ---- lifecycle ---- }

constructor TGitRunner.Create(const AWorkDir: string);
begin
  inherited Create;
  FWorkDir := AWorkDir;
  FGitExe := DetectGit;
end;

{ ---- core runner ---- }

function TGitRunner.Run(const AArgs: array of string): TGitResult;
var
  proc: TProcess;
  outStream, errStream: TStringStream;
  buf: array[0..4095] of Byte;
  n: LongInt;
  i: Integer;
  cmdline: string;
begin
  Result.ExitCode := -1;
  Result.StdOut := '';
  Result.StdErr := '';

  if FGitExe = '' then
  begin
    Result.StdErr := 'git executable not found';
    if Assigned(Log) then Log.Error('git', Result.StdErr);
    Exit;
  end;

  proc := TProcess.Create(nil);
  outStream := TStringStream.Create('');
  errStream := TStringStream.Create('');
  try
    proc.Executable := FGitExe;
    cmdline := 'git';
    for i := 0 to High(AArgs) do
    begin
      proc.Parameters.Add(AArgs[i]);
      cmdline := cmdline + ' ' + AArgs[i];
    end;
    if FWorkDir <> '' then
      proc.CurrentDirectory := FWorkDir;
    // inherit the current environment, then override so git never blocks on an
    // interactive credential / known-hosts prompt and emits parseable English.
    for i := 1 to GetEnvironmentVariableCount do
      proc.Environment.Add(GetEnvironmentString(i));
    proc.Environment.Values['GIT_TERMINAL_PROMPT'] := '0';
    proc.Environment.Values['LC_ALL'] := 'C';
    if FAuthToken <> '' then
    begin
      proc.Environment.Values['GIT_ASKPASS'] := EnsureAskPass;
      proc.Environment.Values['GOTBOX_ASKPASS_PW'] := FAuthToken;
      proc.Environment.Values['GIT_SSH_COMMAND'] := 'ssh -oBatchMode=yes';
    end;
    proc.Options := [poUsePipes, poNoConsole];

    if Assigned(Log) then Log.Debug('git', cmdline + ' [' + FWorkDir + ']');

    proc.Execute;
    // drain both pipes until the process exits and no bytes remain
    repeat
      n := proc.Output.NumBytesAvailable;
      if n > 0 then
      begin
        if n > SizeOf(buf) then n := SizeOf(buf);
        n := proc.Output.Read(buf, n);
        if n > 0 then outStream.Write(buf, n);
      end;
      n := proc.Stderr.NumBytesAvailable;
      if n > 0 then
      begin
        if n > SizeOf(buf) then n := SizeOf(buf);
        n := proc.Stderr.Read(buf, n);
        if n > 0 then errStream.Write(buf, n);
      end;
      if (not proc.Running) and (proc.Output.NumBytesAvailable = 0) and
        (proc.Stderr.NumBytesAvailable = 0) then
        Break;
      Sleep(5);
    until False;

    Result.ExitCode := proc.ExitStatus;
    Result.StdOut := outStream.DataString;
    Result.StdErr := errStream.DataString;
    if (not Result.Ok) and Assigned(Log) then
      Log.Warn('git', Format('exit %d: %s', [Result.ExitCode, Trim(Result.StdErr)]));
  finally
    outStream.Free;
    errStream.Free;
    proc.Free;
  end;
end;

{ ---- porcelain ---- }

function TGitRunner.Git(const AArgs: array of string): TGitResult;
begin
  Result := Run(AArgs);
end;

function TGitRunner.Version: TGitResult;
begin
  Result := Run(['--version']);
end;

function TGitRunner.InitRepo: TGitResult;
begin
  Result := Run(['init', '-b', 'main']);
end;

function TGitRunner.Clone(const AUrl, ADest: string): TGitResult;
begin
  Result := Run(['clone', AUrl, ADest]);
end;

function TGitRunner.AddAll: TGitResult;
begin
  Result := Run(['add', '-A']);
end;

function TGitRunner.CommitAll(const AMessage: string): TGitResult;
begin
  Result := Run(['commit', '-m', AMessage]);
end;

function TGitRunner.Push(AForce: Boolean): TGitResult;
begin
  if AForce then
    Result := Run(['push', '--force-with-lease', 'origin', 'HEAD'])
  else
    Result := Run(['push', 'origin', 'HEAD']);
end;

function TGitRunner.Fetch: TGitResult;
begin
  Result := Run(['fetch', '--prune', 'origin']);
end;

function TGitRunner.PullRebase: TGitResult;
begin
  Result := Run(['pull', '--rebase', 'origin']);
end;

function TGitRunner.Merge(const ARef: string): TGitResult;
begin
  Result := Run(['merge', '--no-edit', ARef]);
end;

function TGitRunner.CountRange(const ARange: string): Integer;
var
  r: TGitResult;
begin
  r := Run(['rev-list', '--count', ARange]);
  if r.Ok then Result := StrToIntDef(Trim(r.StdOut), -1)
  else
    Result := -1;
end;

function TGitRunner.ShowStage(AStage: Integer; const APath: string): TGitResult;
begin
  Result := Run(['show', Format(':%d:%s', [AStage, APath])]);
end;

function TGitRunner.CheckoutTheirs(const APath: string): TGitResult;
begin
  Result := Run(['checkout', '--theirs', '--', APath]);
end;

function TGitRunner.AddPath(const APath: string): TGitResult;
begin
  Result := Run(['add', '--', APath]);
end;

function TGitRunner.StatusPorcelain: TGitResult;
begin
  Result := Run(['status', '--porcelain']);
end;

function TGitRunner.RevParse(const ARef: string): TGitResult;
begin
  Result := Run(['rev-parse', ARef]);
end;

function TGitRunner.Gc: TGitResult;
begin
  Result := Run(['gc', '--prune=now', '--aggressive']);
end;

function TGitRunner.Stash: TGitResult;
begin
  Result := Run(['stash', 'push', '--include-untracked', '-m', 'gotbox-autostash']);
end;

function TGitRunner.StashPop: TGitResult;
begin
  Result := Run(['stash', 'pop']);
end;

function TGitRunner.ResetHard(const ARef: string): TGitResult;
begin
  Result := Run(['reset', '--hard', ARef]);
end;

function TGitRunner.SetRemote(const AName, AUrl: string): TGitResult;
begin
  // try set-url first; if no such remote, add it
  Result := Run(['remote', 'set-url', AName, AUrl]);
  if not Result.Ok then
    Result := Run(['remote', 'add', AName, AUrl]);
end;

function TGitRunner.CurrentBranch: string;
var
  r: TGitResult;
begin
  r := Run(['rev-parse', '--abbrev-ref', 'HEAD']);
  if r.Ok then Result := Trim(r.StdOut)
  else
    Result := '';
end;

function TGitRunner.HasUncommittedChanges: Boolean;
var
  r: TGitResult;
begin
  r := StatusPorcelain;
  Result := r.Ok and (Trim(r.StdOut) <> '');
end;

function TGitRunner.CountCommits: Integer;
var
  r: TGitResult;
begin
  r := Run(['rev-list', '--count', 'HEAD']);
  if r.Ok then
    Result := StrToIntDef(Trim(r.StdOut), -1)
  else
    Result := -1;
end;

end.
