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
  Classes, SysUtils, DateUtils, Process;

const
  { STALL cap for network git ops (fetch/push/pull/clone/ls-remote): abort only
    after the op has gone this long WITHOUT emitting any output. These ops pass
    --progress, so an active transfer keeps writing byte-progress on stderr and
    can legitimately run for minutes; only a genuinely stalled connection goes
    silent this long and is killed. (Not a total-duration cap -- that killed
    healthy large fetches, pinning the repo "offline" and leaking a partial pack
    on every retry.) }
  GIT_NET_TIMEOUT_MS = 30000;
  { Backstop stall cap for ANY git op that doesn't pass its own timeout. Applied
    by the TGitRunner constructor, so every op is bounded unless a caller opts
    out (DefaultTimeoutMs := 0). An op silent this long is stuck (e.g. a Windows
    file-lock deadlock on a shared repo); killing it lets a worker's cycle -- or
    a main-thread reconcile -- end instead of hanging forever. Higher than the
    network cap since local ops emit less incremental output. }
  GIT_DEFAULT_TIMEOUT_MS = 60000;

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
    FQuiet: Boolean;   // suppress warn-logging for expected-to-fail probes
    FDefaultTimeoutMs: Integer;
    // applied to ops that don't pass their own (0 = untimed)
    { When AOutStream is given, stdout bytes are streamed to it verbatim (binary
      safe) and Result.StdOut is left empty; otherwise stdout is captured into
      Result.StdOut as before. stderr is always captured to a string. }
    function Run(const AArgs: array of string; ATimeoutMs: Integer = 0;
      AOutStream: TStream = nil): TGitResult;
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
    { Timeout (ms) applied to any op that doesn't specify one; 0 = untimed.
      Set by long-lived callers (the sync worker) so a stuck local git op can't
      block the worker thread -- and thus engine.Stop's join -- indefinitely. }
    property DefaultTimeoutMs: Integer read FDefaultTimeoutMs write FDefaultTimeoutMs;

    // raw passthrough
    function Git(const AArgs: array of string): TGitResult;
    // like Git but does not log a warning on non-zero exit (for probes whose
    // failure is expected/normal, e.g. rev-parse/merge-base/--get-regexp)
    function GitQuiet(const AArgs: array of string): TGitResult;

    // common porcelain helpers
    function Version: TGitResult;
    function InitRepo: TGitResult;
    function Clone(const AUrl, ADest: string): TGitResult;
    function AddAll: TGitResult;
    function CommitAll(const AMessage: string): TGitResult;
    function Push(AForce: Boolean = False): TGitResult;
    function Fetch: TGitResult;
    function PullRebase: TGitResult;
    { Delete stale partial packs (tmp_pack_*) left in this repo's object store by
      fetches killed mid-transfer. Skips any file modified within the last
      AMinAgeSec seconds, so an actively-downloading pack (its mtime advances as
      bytes land) is never touched. Safe no-op if there are none. }
    procedure PrunePartialPacks(AMinAgeSec: Integer = 60);
    { Remove a stale .git/index.lock left behind by a git op that was killed
      (e.g. by the stall timeout) mid add/commit/merge -- otherwise every later
      index write in this repo fails with "Unable to create '.../index.lock'".
      Only deletes a lock older than AMinAgeSec so a genuinely in-flight op (this
      worker serializes its own git, but the user might run git by hand) is never
      disturbed. Safe no-op if there is none. }
    procedure SweepStaleIndexLock(AMinAgeSec: Integer = 60);
    function Merge(const ARef: string): TGitResult;
    function CountRange(const ARange: string): Integer; // commits in ARange (-1 err)
    function ShowStage(AStage: Integer; const APath: string): TGitResult;
    { Write the raw bytes of a staged blob (stage 1/2/3 of a conflicted path)
      straight to ADestFile, streaming through a file handle rather than a Pascal
      string, so binary content with embedded NULs is copied byte-for-byte.
      Returns True and the byte count on success. }
    function ShowStageToFile(AStage: Integer; const APath, ADestFile: string;
      out ABytes: Int64): Boolean;
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
  // Universal backstop: EVERY op is bounded unless a caller opts out by setting
  // DefaultTimeoutMs := 0. Previously only three call sites set this, leaving the
  // submodule/reconcile paths (gboxsuper, repolink, remote) unbounded -- and
  // because reconcile runs on the main thread (TThread.Queue -> CheckSynchronize),
  // one stuck git op there froze the engine's main thread indefinitely (the
  // intermittent Windows-CI hang in testmultisync's phase-8 catch-up).
  FDefaultTimeoutMs := GIT_DEFAULT_TIMEOUT_MS;
end;

{ ---- core runner ---- }

{ Opt-in git-op trace (set GOTBOX_GIT_TRACE=1). Prints one line to stderr when an
  op starts and one when it ends, with the thread id, elapsed ms and a TIMEOUT
  flag. A hung op leaves a dangling "GIT>" with no matching "GIT<", so the tail
  of a captured log names the exact stalling command + repo. Cached so we read
  the env once. Diagnostic only -- off by default, no I/O in normal runs. }
var
  gGitTrace: Integer = -1;   // -1 unknown, 0 off, 1 on

function GitTraceOn: Boolean;
begin
  if gGitTrace < 0 then
    if GetEnvironmentVariable('GOTBOX_GIT_TRACE') <> '' then gGitTrace := 1
    else
      gGitTrace := 0;
  Result := gGitTrace = 1;
end;

function TGitRunner.Run(const AArgs: array of string; ATimeoutMs: Integer;
  AOutStream: TStream): TGitResult;
var
  proc: TProcess;
  outStream, errStream: TStringStream;
  outTarget: TStream;   // where stdout bytes go: AOutStream (verbatim) or outStream
  buf: array[0..4095] of Byte;
  i, idle: Integer;
  cmdline, trace: string;
  started, lastData: TDateTime;
  timedOut: Boolean;

{ Read whatever is currently available on both pipes; return bytes read. }
  function DrainAvail: LongInt;
  var
    m: LongInt;
  begin
    Result := 0;
    m := proc.Output.NumBytesAvailable;
    if m > 0 then
    begin
      if m > SizeOf(buf) then m := SizeOf(buf);
      m := proc.Output.Read(buf, m);
      if m > 0 then begin
        outTarget.Write(buf, m);
        Inc(Result, m);
      end;
    end;
    m := proc.Stderr.NumBytesAvailable;
    if m > 0 then
    begin
      if m > SizeOf(buf) then m := SizeOf(buf);
      m := proc.Stderr.Read(buf, m);
      if m > 0 then begin
        errStream.Write(buf, m);
        Inc(Result, m);
      end;
    end;
  end;

begin
  Result.ExitCode := -1;
  Result.StdOut := '';
  Result.StdErr := '';

  // fall back to the runner's default cap for ops that didn't pass their own
  if (ATimeoutMs <= 0) and (FDefaultTimeoutMs > 0) then
    ATimeoutMs := FDefaultTimeoutMs;

  if FGitExe = '' then
  begin
    Result.StdErr := 'git executable not found';
    if Assigned(Log) then Log.Error('git', Result.StdErr);
    Exit;
  end;

  proc := TProcess.Create(nil);
  outStream := TStringStream.Create('');
  errStream := TStringStream.Create('');
  // stream stdout straight to the caller's stream when one is supplied
  // (binary-safe copies), else accumulate it for Result.StdOut
  if AOutStream <> nil then outTarget := AOutStream
  else
    outTarget := outStream;
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
    // ssh must never block on a password or an unknown-host prompt (key auth)
    proc.Environment.Values['GIT_SSH_COMMAND'] :=
      'ssh -oBatchMode=yes -oStrictHostKeyChecking=accept-new';
    if FAuthToken <> '' then
    begin
      proc.Environment.Values['GIT_ASKPASS'] := EnsureAskPass;
      proc.Environment.Values['GOTBOX_ASKPASS_PW'] := FAuthToken;
    end;
    proc.Options := [poUsePipes, poNoConsole];

    if Assigned(Log) then Log.Debug('git', cmdline + ' [' + FWorkDir + ']');

    proc.Execute;
    started := Now;
    lastData := started;   // stall clock: reset whenever the child emits bytes
    timedOut := False;
    if GitTraceOn then
    begin
      trace := Format('GIT> [t%u] %s [%s]', [PtrUInt(GetThreadID), cmdline, FWorkDir]);
      WriteLn(StdErr, trace);
      Flush(StdErr);
    end;
    // Pump both pipes while the process runs, then drain to EOF. On Windows,
    // NumBytesAvailable can briefly report 0 while the child's final write is
    // still landing in the pipe buffer, so once the process has exited we keep
    // polling until several consecutive reads come back empty -- otherwise the
    // last -z record (e.g. a trailing "?? file\0") is occasionally truncated,
    // which surfaced as a flaky "untracked file -> none" overlay result.
    idle := 0;
    repeat
      if DrainAvail > 0 then
      begin
        idle := 0;
        lastData := Now;        // progress: reset the stall clock
      end
      else if not proc.Running then
        Inc(idle);              // exited + nothing read: count quiet polls
      if idle >= 4 then Break;   // ~4ms of quiet after exit: pipes are drained

      // Abort only when the child has been SILENT for ATimeoutMs -- a genuine
      // stall, not a slow-but-progressing transfer. Network ops pass --progress,
      // so an active fetch/clone/push keeps emitting byte-progress on stderr and
      // never trips this even if it legitimately runs for minutes; a truly
      // stalled connection (or a hung/deadlocked local op) goes quiet and is
      // killed. (Previously this was a total-duration cap, which killed healthy
      // large fetches -- leaving the repo permanently "offline" and leaking a
      // partial pack each retry.)
      if proc.Running and (ATimeoutMs > 0) and
        (MilliSecondsBetween(Now, lastData) >= ATimeoutMs) then
      begin
        timedOut := True;
        proc.Terminate(124);   // SIGTERM-equivalent; conventional "timed out" code
        Break;
      end;
      if proc.Running then Sleep(5)
      else
        Sleep(1);
    until False;

    if timedOut then
    begin
      Result.ExitCode := 124;
      Result.StdOut := outStream.DataString;
      // contains "timed out" so callers classify it as an offline/network error
      Result.StdErr := Format('git timed out: no data for %d s (stalled)',
        [ATimeoutMs div 1000]);
    end
    else
    begin
      Result.ExitCode := proc.ExitStatus;
      Result.StdOut := outStream.DataString;
      Result.StdErr := errStream.DataString;
    end;
    if (not Result.Ok) and (not FQuiet) and Assigned(Log) then
      Log.Warn('git', Format('exit %d: %s', [Result.ExitCode, Trim(Result.StdErr)]));
    if GitTraceOn then
    begin
      trace := Format('GIT< [t%u] exit=%d %dms%s %s',
        [PtrUInt(GetThreadID), Result.ExitCode, MilliSecondsBetween(Now, started),
        BoolToStr(timedOut, ' TIMEOUT', ''), cmdline]);
      WriteLn(StdErr, trace);
      Flush(StdErr);
    end;
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

function TGitRunner.GitQuiet(const AArgs: array of string): TGitResult;
begin
  FQuiet := True;
  try
    Result := Run(AArgs);
  finally
    FQuiet := False;
  end;
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
  // --progress: force byte-progress on stderr (git suppresses it on a non-tty
  // pipe) so the stall cap sees an active transfer as "still moving"
  Result := Run(['clone', '--progress', AUrl, ADest], GIT_NET_TIMEOUT_MS);
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
  // --progress keeps the stall cap fed during the upload (see Clone)
  if AForce then
    Result := Run(['push', '--progress', '--force-with-lease', 'origin', 'HEAD'],
      GIT_NET_TIMEOUT_MS)
  else
    Result := Run(['push', '--progress', 'origin', 'HEAD'], GIT_NET_TIMEOUT_MS);
end;

{ Cross-platform absolute-path test (SysUtils has none; FileUtil is LCL, and this
  unit stays LCL-free). }
function PathIsAbsolute(const APath: string): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := ((Length(APath) >= 1) and ((APath[1] = '\') or (APath[1] = '/'))) or
    ((Length(APath) >= 2) and (APath[2] = ':'));   // drive-letter or UNC/root
  {$ELSE}
  Result := (Length(APath) >= 1) and (APath[1] = '/');
  {$ENDIF}
end;

procedure TGitRunner.PrunePartialPacks(AMinAgeSec: Integer);
var
  r: TGitResult;
  gitDir, packDir, full: string;
  sr: TSearchRec;
  ft: TDateTime;
begin
  // resolve the object store (handles a submodule's ".git" gitdir-file too)
  r := GitQuiet(['rev-parse', '--git-dir']);
  if not r.Ok then Exit;
  gitDir := Trim(r.StdOut);
  if gitDir = '' then Exit;
  if not PathIsAbsolute(gitDir) then
    gitDir := IncludeTrailingPathDelimiter(FWorkDir) + gitDir;
  packDir := IncludeTrailingPathDelimiter(gitDir) + 'objects' + PathDelim + 'pack';
  if not DirectoryExists(packDir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(packDir) + 'tmp_pack_*', faAnyFile, sr) <>
    0 then Exit;
  try
    repeat
      if (sr.Attr and faDirectory) <> 0 then Continue;
      full := IncludeTrailingPathDelimiter(packDir) + sr.Name;
      // leave anything still being written (recent mtime -> possibly in flight)
      if FileAge(full, ft) and ((Now - ft) * SecsPerDay < AMinAgeSec) then Continue;
      if DeleteFile(full) and Assigned(Log) then
        Log.Info('git', 'pruned stale partial pack: ' + sr.Name);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

procedure TGitRunner.SweepStaleIndexLock(AMinAgeSec: Integer);
var
  r: TGitResult;
  gitDir, lockPath: string;
  ft: TDateTime;
begin
  // resolve the object store (handles a submodule's ".git" gitdir-file too)
  r := GitQuiet(['rev-parse', '--git-dir']);
  if not r.Ok then Exit;
  gitDir := Trim(r.StdOut);
  if gitDir = '' then Exit;
  if not PathIsAbsolute(gitDir) then
    gitDir := IncludeTrailingPathDelimiter(FWorkDir) + gitDir;
  lockPath := IncludeTrailingPathDelimiter(gitDir) + 'index.lock';
  if not FileExists(lockPath) then Exit;
  // only reclaim a lock that has been sitting untouched: a fresh one may belong
  // to an op still starting up (ours are serialized, but a user's hand-run git
  // could hold it legitimately)
  if FileAge(lockPath, ft) and ((Now - ft) * SecsPerDay < AMinAgeSec) then Exit;
  if DeleteFile(lockPath) and Assigned(Log) then
    Log.Warn('git', 'removed stale index.lock (a git op was interrupted): ' +
      lockPath);
end;

function TGitRunner.Fetch: TGitResult;
begin
  // sweep partial packs left by any previously-killed fetch so they can't pile
  // up into gigabytes of .git garbage over many failed cycles
  PrunePartialPacks;
  // never recurse into submodules: GotBox syncs each submodule independently
  // (ignore=all), and a broken/inaccessible submodule must not fail the root's
  // fetch (git's default on-demand recursion would abort the whole fetch).
  // --tags so user checkpoint tags created on another machine arrive here.
  // --progress keeps the stall cap fed during a large download (see Clone).
  Result := Run(['fetch', '--progress', '--prune', '--tags',
    '--no-recurse-submodules', 'origin'], GIT_NET_TIMEOUT_MS);
end;

function TGitRunner.PullRebase: TGitResult;
begin
  Result := Run(['pull', '--progress', '--rebase', 'origin'], GIT_NET_TIMEOUT_MS);
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

function TGitRunner.ShowStageToFile(AStage: Integer; const APath, ADestFile: string;
  out ABytes: Int64): Boolean;
var
  fs: TFileStream;
  r: TGitResult;
begin
  Result := False;
  ABytes := 0;
  ForceDirectories(ExtractFilePath(ADestFile));
  fs := TFileStream.Create(ADestFile, fmCreate);
  try
    // cat-file blob emits the object's raw bytes with no filtering; streamed
    // straight to the file handle so embedded NULs survive intact
    r := Run(['cat-file', 'blob', Format(':%d:%s', [AStage, APath])], 0, fs);
    ABytes := fs.Size;
    Result := r.Ok;
  finally
    fs.Free;
  end;
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
  // plain (fast) gc; --aggressive is far too slow to run on every maintenance cycle
  Result := Run(['gc', '--prune=now']);
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
  // symbolic-ref resolves the branch even on an UNBORN branch (a fresh clone or
  // init with no commits yet), where rev-parse --abbrev-ref HEAD fails outright;
  // fall back to rev-parse for the (unusual, for GotBox) detached-HEAD case.
  r := GitQuiet(['symbolic-ref', '--short', 'HEAD']);
  if r.Ok and (Trim(r.StdOut) <> '') then Exit(Trim(r.StdOut));
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
