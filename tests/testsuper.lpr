program testsuper;

{ Tests the .gotbox superproject model against local bare repos (git backend,
  no network): ensure the .gotbox root, add a submodule from an existing repo
  and from a newly-created upstream, and list them. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  gboxlog,
  gboxconfigstore,
  gboxgitrunner,
  gboxsuper;

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
            {$IFDEF WINDOWS}
            FileSetAttr(full, faNormal);   // git pack/object files are read-only on Windows
            {$ENDIF}
            DeleteFile(full);
          end;
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
    end;
    {$IFDEF WINDOWS}
    FileSetAttr(ADir, faNormal);
    {$ENDIF}
    RemoveDir(ADir);
  end;

  function Git(const ADir: string; const AArgs: array of string;
    out AOut: string): Boolean;
  var
    g: TGitRunner;
    r: TGitResult;
  begin
    g := TGitRunner.Create(ADir);
    try
      r := g.Git(AArgs);
      AOut := r.StdOut;
      Result := r.Ok;
    finally
      g.Free;
    end;
  end;

  procedure MakeSeededBare(const ABare, AWork: string);  // bare with one commit on main
  var
    outp: string;
    f: TStringList;
  begin
    ForceDirectories(ABare);
    Git(ABare, ['init', '--bare', '-b', 'main'], outp);
    ForceDirectories(AWork);
    Git('', ['clone', ABare, AWork], outp);
    Git(AWork, ['config', 'user.name', 'seed'], outp);
    Git(AWork, ['config', 'user.email', 'seed@test.local'], outp);
    f := TStringList.Create;
    try
      f.Add('seed');
      f.SaveToFile(IncludeTrailingPathDelimiter(AWork) + 'seed.txt');
    finally
      f.Free;
    end;
    Git(AWork, ['add', '-A'], outp);
    Git(AWork, ['commit', '-m', 'seed'], outp);
    Git(AWork, ['push', 'origin', 'HEAD:main'], outp);
  end;

var
  base, root, detail, outp, np: string;
  cfg, cfg2: TGotConfig;
  subs: TSubmoduleArray;
begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-super-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  root := IncludeTrailingPathDelimiter(base) + 'root';
  ForceDirectories(root);
  WriteLn('workspace: ', base);

  cfg := TGotConfig.Create;
  cfg.RootDir := root;
  cfg.MachineName := 'testbox';
  cfg.RemoteKind := 'git';            // local/path backend
  cfg.SshBase := ExcludeTrailingPathDelimiter(base);  // repos live at <base>/<name>.git

  // 0) RootHasContent: empty root is empty; a dropped file counts as content
  Check(not RootHasContent(root), 'empty root has no content');
  with TStringList.Create do
  try
    Add('hi');
    SaveToFile(IncludeTrailingPathDelimiter(root) + 'loose.txt');
  finally
    Free;
  end;
  Check(RootHasContent(root), 'root with a file has content');

  // 1) ensure the .gotbox root
  Check(not GotboxRemoteReady(cfg, ''), 'remote .gotbox not ready before create');
  Check(EnsureGotboxRoot(cfg, '', detail), 'EnsureGotboxRoot (' + detail + ')');
  Check(DirectoryExists(IncludeTrailingPathDelimiter(root) + '.git'),
    'root is a git repo');
  Check(DirectoryExists(IncludeTrailingPathDelimiter(base) + '.gotbox.git'),
    '.gotbox bare created');
  Check(GotboxRemoteReady(cfg, ''),
    'remote .gotbox ready after create (fresh machine would clone)');

  // 2) add a submodule from an existing (seeded) upstream
  MakeSeededBare(IncludeTrailingPathDelimiter(base) + 'ext.git',
    IncludeTrailingPathDelimiter(base) + 'extseed');
  Check(AddSubmodule(cfg, '', 'docs', '', IncludeTrailingPathDelimiter(base) +
    'ext.git', False, detail),
    'add submodule from existing url (' + detail + ')');
  Check(DirectoryExists(IncludeTrailingPathDelimiter(root) + 'docs'),
    'submodule dir exists');
  Check(FileExists(IncludeTrailingPathDelimiter(root) + '.gitmodules'),
    '.gitmodules created');
  Git(root, ['config', '-f', '.gitmodules', 'submodule.docs.ignore'], outp);
  Check(Trim(outp) = 'all', 'submodule ignore=all set');

  // 3) add a submodule from a newly-created upstream (custom local name != repo name)
  Check(AddSubmodule(cfg, '', 'myproj', 'projectupstream', '', True, detail),
    'add submodule from new upstream (' + detail + ')');
  Check(DirectoryExists(IncludeTrailingPathDelimiter(root) + 'myproj'),
    'new submodule dir exists');
  Check(DirectoryExists(IncludeTrailingPathDelimiter(base) + 'projectupstream.git'),
    'new upstream bare created');

  // 3b) NormalizeSubmodulePath: accepts relative paths, rejects unsafe input
  Check(NormalizeSubmodulePath('a\b\c', np, detail) and (np = 'a/b/c'),
    'normalize backslashes -> a/b/c (' + np + ')');
  Check(NormalizeSubmodulePath('a//b/./c', np, detail) and (np = 'a/b/c'),
    'normalize collapses // and . -> a/b/c (' + np + ')');
  Check(not NormalizeSubmodulePath('/abs', np, detail), 'reject absolute path');
  Check(not NormalizeSubmodulePath('a/../b', np, detail), 'reject .. traversal');

  // 3c) add a submodule at a NESTED relative path (sub-folder of the root)
  Check(AddSubmodule(cfg, '', 'projects/notes', 'notesupstream', '', True, detail),
    'add nested submodule projects/notes (' + detail + ')');
  Check(DirectoryExists(IncludeTrailingPathDelimiter(root) + 'projects' +
    PathDelim + 'notes'), 'nested submodule dir exists at projects/notes');
  Git(root, ['config', '-f', '.gitmodules', 'submodule.projects/notes.ignore'], outp);
  Check(Trim(outp) = 'all', 'nested submodule ignore=all set under its path');

  // 4) list submodules (docs, myproj, projects/notes)
  subs := ListSubmodules(root);
  Check(Length(subs) = 3, 'lists 3 submodules (got ' + IntToStr(Length(subs)) + ')');

  // 5) second machine: EnsureGotboxRoot on an empty root clones --recursive
  cfg2 := TGotConfig.Create;
  cfg2.RootDir := IncludeTrailingPathDelimiter(base) + 'root2';
  cfg2.MachineName := 'box2';
  cfg2.RemoteKind := 'git';
  cfg2.SshBase := ExcludeTrailingPathDelimiter(base);
  Check(EnsureGotboxRoot(cfg2, '', detail), 'second machine clones .gotbox (' +
    detail + ')');
  Check(IsGitWorkTree(cfg2.RootDir), 'root2 is a git work tree');
  Check(DirectoryExists(IncludeTrailingPathDelimiter(cfg2.RootDir) + 'docs'),
    'submodule "docs" checked out on root2');
  Check(FileExists(IncludeTrailingPathDelimiter(cfg2.RootDir) + 'docs' +
    PathDelim + 'seed.txt'), 'submodule content present on root2 (recursive clone)');
  Check(IsGitWorkTree(IncludeTrailingPathDelimiter(cfg2.RootDir) +
    'projects' + PathDelim + 'notes'),
    'nested submodule checked out on root2 (recursive clone)');
  cfg2.Free;

  // 6) resurrect: remote .gotbox deleted but local tree exists -> EnsureGotboxRoot
  //    recreates the remote and pushes the local content back
  RmRf(IncludeTrailingPathDelimiter(base) + '.gotbox.git');
  Check(not DirectoryExists(IncludeTrailingPathDelimiter(base) + '.gotbox.git'),
    'remote .gotbox deleted');
  Check(EnsureGotboxRoot(cfg, '', detail), 'resurrect recreates .gotbox (' +
    detail + ')');
  Check(DirectoryExists(IncludeTrailingPathDelimiter(base) + '.gotbox.git'),
    'remote .gotbox bare recreated');
  Git(root, ['ls-remote', 'origin', 'refs/heads/main'], outp);
  Check(Trim(outp) <> '', 'local content repushed to recreated remote');

  cfg.Free;
  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
