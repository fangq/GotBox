{
  GotBox -- Dropbox-like file sync over your own private git repositories.
  Copyright (C) 2026 Qianqian Fang <fangqq at gmail.com>. GPLv3-or-later.
}

program testfilestatus;

{ Unit test for gboxfilestatus: the per-file status classifier, folder roll-up,
  and absolute-path -> owning-repo (root vs submodule) mapping. LCL-free; runs
  on any OS (no Windows/COM needed). }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, gboxgitrunner, gboxfilestatus;

var
  failures: Integer = 0;
  root: string;

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
          else
          begin
            {$IFDEF WINDOWS}FileSetAttr(full, faNormal);{$ENDIF}
            DeleteFile(full);
          end;
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

  { Run a git command in ADir; assert success unless AMayFail. }
  procedure Git(const ADir: string; const AArgs: array of string;
    AMayFail: Boolean = False);
  var
    g: TGitRunner;
    r: TGitResult;
  begin
    g := TGitRunner.Create(ADir);
    try
      r := g.Git(AArgs);
      if (not r.Ok) and (not AMayFail) then
        WriteLn('  (git failed: ', Trim(r.StdErr), ')');
    finally
      g.Free;
    end;
  end;

  function P(const ARel: string): string;   // absolute path under root
  begin
    Result := IncludeTrailingPathDelimiter(root) + SetDirSeparators(ARel);
  end;

var
  cache: TStatusCache;
  subdir: string;
begin
  root := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-fstat-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now);
  ForceDirectories(root);
  WriteLn('workspace: ', root);
  try
    // ---- a repo with clean / modified / untracked / conflict + folders ------
    Git(root, ['init', '-b', 'main']);
    Git(root, ['config', 'user.name', 't']);
    Git(root, ['config', 'user.email', 't@t']);

    WriteFile(P('clean.txt'), 'clean');
    WriteFile(P('mod.txt'), 'orig');
    WriteFile(P('conflict.txt'), 'base');
    WriteFile(P('docs/a.txt'), 'doc');          // folder that stays clean
    Git(root, ['add', '-A']);
    Git(root, ['commit', '-m', 'base']);

    // real merge conflict on conflict.txt
    Git(root, ['checkout', '-b', 'other']);
    WriteFile(P('conflict.txt'), 'OTHER');
    Git(root, ['commit', '-am', 'other']);
    Git(root, ['checkout', 'main']);
    WriteFile(P('conflict.txt'), 'MAIN');
    Git(root, ['commit', '-am', 'main']);
    Git(root, ['merge', 'other'], True);        // expected: conflict

    WriteFile(P('mod.txt'), 'changed');         // tracked + modified
    WriteFile(P('new.txt'), 'brand new');       // untracked
    WriteFile(P('work/x.txt'), 'wip');          // untracked inside a folder

    cache := TStatusCache.Create(root);
    try
      cache.TtlMs := 0;   // always fresh in the test
      Check(cache.Lookup(P('clean.txt')) = fsSynced, 'clean tracked file -> synced');
      Check(cache.Lookup(P('mod.txt')) = fsModified, 'modified tracked file -> modified');
      Check(cache.Lookup(P('new.txt')) = fsModified, 'untracked file -> modified');
      Check(cache.Lookup(P('conflict.txt')) = fsConflict, 'unmerged file -> conflict');
      Check(cache.Lookup(P('docs/a.txt')) = fsSynced, 'file in a clean folder -> synced');
      // folder roll-up
      Check(cache.Lookup(P('docs')) = fsSynced, 'clean folder rolls up to synced');
      Check(cache.Lookup(P('work')) = fsModified, 'folder with an untracked file -> modified');
      // an ignored/unknown path (never created) -> none
      Check(cache.Lookup(P('nope.txt')) = fsNone, 'unknown path -> none');
    finally
      cache.Free;
    end;

    // ---- submodule mapping: a nested repo registered in .gitmodules ---------
    subdir := P('sub');
    ForceDirectories(subdir);
    Git(subdir, ['init', '-b', 'main']);
    Git(subdir, ['config', 'user.name', 's']);
    Git(subdir, ['config', 'user.email', 's@s']);
    WriteFile(IncludeTrailingPathDelimiter(subdir) + 'tracked.txt', 'x');
    Git(subdir, ['add', '-A']);
    Git(subdir, ['commit', '-m', 'sub base']);
    WriteFile(IncludeTrailingPathDelimiter(subdir) + 'dirty.txt', 'y');   // untracked in sub
    // register it as a submodule in the root's .gitmodules (path form)
    WriteFile(P('.gitmodules'),
      '[submodule "sub"]'#10 + #9'path = sub'#10 + #9'url = ./sub'#10);

    cache := TStatusCache.Create(root);
    try
      cache.TtlMs := 0;
      // a file inside the submodule must be classified by the SUBMODULE's git,
      // not the root's (proves absolute-path -> owning-repo mapping)
      Check(cache.Lookup(IncludeTrailingPathDelimiter(subdir) + 'tracked.txt') = fsSynced,
        'submodule: tracked file -> synced (mapped to submodule repo)');
      Check(cache.Lookup(IncludeTrailingPathDelimiter(subdir) + 'dirty.txt') = fsModified,
        'submodule: untracked file -> modified (mapped to submodule repo)');
    finally
      cache.Free;
    end;
  finally
    if failures = 0 then RmRf(root);
  end;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
