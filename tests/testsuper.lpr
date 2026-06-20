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
  base, root, detail, outp: string;
  cfg: TGotConfig;
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
  Check(EnsureGotboxRoot(cfg, '', detail), 'EnsureGotboxRoot (' + detail + ')');
  Check(DirectoryExists(IncludeTrailingPathDelimiter(root) + '.git'),
    'root is a git repo');
  Check(DirectoryExists(IncludeTrailingPathDelimiter(base) + '.gotbox.git'),
    '.gotbox bare created');

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

  // 4) list submodules
  subs := ListSubmodules(root);
  Check(Length(subs) = 2, 'lists 2 submodules (got ' + IntToStr(Length(subs)) + ')');

  cfg.Free;
  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
