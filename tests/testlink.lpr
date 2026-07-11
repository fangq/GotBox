{
  GotBox -- Dropbox-like file sync over your own private git repositories.
  Copyright (C) 2026 Qianqian Fang <q.fang@northeastern.edu> and contributors.

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

program testlink;

{ Tests the git-side repo wiring (TRepoLinker.EnsureLocalRepo) against a local
  bare repo standing in for GitHub -- no network or token required. Verifies
  init + remote + initial commit + push, and that linking an existing checkout
  is idempotent. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Process,
  gboxlog,
  gboxconfigstore,
  gboxgitrunner,
  gboxrepolink;

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

  function RunGit(const AWorkDir: string; const AArgs: array of string;
    out AOut: string): Boolean;
  var
    git: TGitRunner;
    r: TGitResult;
  begin
    git := TGitRunner.Create(AWorkDir);
    try
      r := git.Git(AArgs);
      AOut := r.StdOut;
      Result := r.Ok;
    finally
      git.Free;
    end;
  end;

var
  base, root, projDir, bareRepo, detail, outp: string;
  emptyDir, emptyBare: string;
  cfg: TGotConfig;
  linker: TRepoLinker;
  ok: Boolean;
begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-link-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  root := IncludeTrailingPathDelimiter(base) + 'root';
  projDir := IncludeTrailingPathDelimiter(root) + 'proj';
  bareRepo := IncludeTrailingPathDelimiter(base) + 'remote.git';
  ForceDirectories(projDir);
  ForceDirectories(bareRepo);
  WriteLn('workspace: ', base);

  // a bare repo to act as the "GitHub" remote
  Check(RunGit(bareRepo, ['init', '--bare', '-b', 'main'], outp), 'create bare remote');

  // a file to be committed
  with TStringList.Create do
  try
    Add('hello from gotbox');
    SaveToFile(IncludeTrailingPathDelimiter(projDir) + 'notes.txt');
  finally
    Free;
  end;

  cfg := TGotConfig.Create;
  try
    cfg.RootDir := root;
    cfg.GithubUser := 'tester';
    linker := TRepoLinker.Create(cfg, '');  // empty token: local file remote
    try
      // first link: init + remote + commit + push (created=True)
      ok := linker.EnsureLocalRepo(projDir, bareRepo, True, detail);
      Check(ok, 'EnsureLocalRepo (new) succeeds: ' + detail);
      Check(DirectoryExists(IncludeTrailingPathDelimiter(projDir) + '.git'),
        'local .git created');

      // remote now has the commit on main
      Check(RunGit(projDir, ['ls-remote', 'origin', 'refs/heads/main'], outp) and
        (Trim(outp) <> ''), 'pushed main to remote');

      // committer identity was set
      RunGit(projDir, ['config', 'user.name'], outp);
      Check(Trim(outp) = 'tester', 'committer identity set');

      // second call is idempotent (already a repo, has commits, nothing to push)
      ok := linker.EnsureLocalRepo(projDir, bareRepo, False, detail);
      Check(ok, 'EnsureLocalRepo (existing) idempotent: ' + detail);

      // a brand-new EMPTY folder must still get an initial commit + main pushed
      emptyDir := IncludeTrailingPathDelimiter(root) + 'empty';
      emptyBare := IncludeTrailingPathDelimiter(base) + 'empty.git';
      ForceDirectories(emptyDir);
      ForceDirectories(emptyBare);
      RunGit(emptyBare, ['init', '--bare', '-b', 'main'], outp);
      ok := linker.EnsureLocalRepo(emptyDir, emptyBare, True, detail);
      Check(ok, 'EnsureLocalRepo (empty folder) succeeds: ' + detail);
      Check(RunGit(emptyDir, ['ls-remote', 'origin', 'refs/heads/main'], outp) and
        (Trim(outp) <> ''), 'empty folder pushed main to remote');
    finally
      linker.Free;
    end;
  finally
    cfg.Free;
  end;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
