{
  GotBox -- Dropbox-like file sync over your own private git repositories.
  Copyright (C) 2026 Qianqian Fang <fangqq at gmail.com>. GPLv3-or-later.
}

program testoverlayipc;

{ Round-trip test for gboxoverlayipc: start the status server over a private
  endpoint, query it as a client (as the overlay DLL would), and assert the
  path->state answers match the cache. Also checks the fail-safe path (no
  server -> fsNone). Runs on Linux CI over a Unix-domain socket; the Windows
  named-pipe path mirrors it. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, gboxgitrunner, gboxfilestatus, gboxoverlayipc;

var
  failures: Integer = 0;
  root, endpoint: string;

  procedure Check(ACond: Boolean; const AName: string);
  begin
    if ACond then WriteLn('  ok   - ', AName)
    else
    begin
      WriteLn('  FAIL - ', AName);
      Inc(failures);
    end;
  end;

  procedure RmRf(const ADir: string);
  var
    sr: TSearchRec;
    full: string;
  begin
    if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, sr) = 0 then
    begin
      try
        repeat
          if (sr.Name = '.') or (sr.Name = '..') then Continue;
          full := IncludeTrailingPathDelimiter(ADir) + sr.Name;
          if (sr.Attr and faDirectory) <> 0 then RmRf(full)
          else DeleteFile(full);
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
    end;
    RemoveDir(ADir);
  end;

  procedure WriteFile(const APath, AContent: string);
  var
    f: TStringList;
  begin
    ForceDirectories(ExtractFileDir(APath));
    f := TStringList.Create;
    try
      f.Text := AContent;
      f.SaveToFile(APath);
    finally
      f.Free;
    end;
  end;

  procedure Git(const ADir: string; const AArgs: array of string);
  var
    g: TGitRunner;
  begin
    g := TGitRunner.Create(ADir);
    try
      g.Git(AArgs);
    finally
      g.Free;
    end;
  end;

  function P(const ARel: string): string;
  begin
    Result := IncludeTrailingPathDelimiter(root) + SetDirSeparators(ARel);
  end;

var
  cache: TStatusCache;
  server: TOverlayServer;
begin
  root := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-ipc-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now);
  ForceDirectories(root);
  // a private endpoint so we never disturb a running GotBox daemon
  {$IFDEF WINDOWS}
  endpoint := '\\.\pipe\GotBox-Overlay-test-' + IntToStr(GetProcessID);
  {$ELSE}
  endpoint := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-ipc-' +
    IntToStr(GetProcessID) + '.sock';
  {$ENDIF}
  WriteLn('workspace: ', root);
  WriteLn('endpoint:  ', endpoint);
  try
    Git(root, ['init', '-b', 'main']);
    Git(root, ['config', 'user.name', 't']);
    Git(root, ['config', 'user.email', 't@t']);
    WriteFile(P('clean.txt'), 'clean');
    WriteFile(P('mod.txt'), 'orig');
    Git(root, ['add', '-A']);
    Git(root, ['commit', '-m', 'base']);
    WriteFile(P('mod.txt'), 'changed');       // tracked + modified
    WriteFile(P('new.txt'), 'brand new');      // untracked

    // fail-safe: no server on this endpoint yet -> fsNone, no hang
    Check(OverlayQuery(P('clean.txt'), endpoint, 300) = fsNone,
      'query with no server -> none (fail-safe)');

    cache := TStatusCache.Create(root);
    server := TOverlayServer.Create(cache, endpoint);
    try
      cache.TtlMs := 0;                        // always fresh in the test
      server.Start;
      Sleep(200);                              // let the listener bind

      Check(OverlayQuery(P('clean.txt'), endpoint, 2000) = fsSynced,
        'clean file over IPC -> synced');
      Check(OverlayQuery(P('mod.txt'), endpoint, 2000) = fsModified,
        'modified file over IPC -> modified');
      Check(OverlayQuery(P('new.txt'), endpoint, 2000) = fsModified,
        'untracked file over IPC -> modified');
      Check(OverlayQuery(P('nope.txt'), endpoint, 2000) = fsNone,
        'unknown path over IPC -> none');
      // path outside the tree -> none
      Check(OverlayQuery(GetTempDir, endpoint, 2000) = fsNone,
        'path outside the root -> none');
    finally
      server.Free;                             // stops + joins the listener
      cache.Free;
    end;

    // after the server stops, queries fail safe again
    Check(OverlayQuery(P('clean.txt'), endpoint, 300) = fsNone,
      'query after server stopped -> none (fail-safe)');
  finally
    if failures = 0 then RmRf(root);
    {$IFDEF UNIX}DeleteFile(endpoint);{$ENDIF}
  end;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
