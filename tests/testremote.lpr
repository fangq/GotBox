program testremote;

{ Tests the generic git remote provider: URL joining, ssh-target parsing, and
  local bare-repo auto-creation (the path the SSH backend also uses, minus the
  ssh hop which needs a real server). }

{$mode objfpc}{$H+}

uses
  SysUtils,
  gboxlog,
  gboxremote;

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

  procedure CheckParse(const AUrl: string; AExpect: Boolean;
  const AHost, APort, APath: string);
  var
    h, p, pa: string;
    ok: Boolean;
  begin
    ok := ParseSshTarget(AUrl, h, p, pa);
    if not AExpect then
      Check(not ok, 'parse "' + AUrl + '" -> not ssh')
    else
      Check(ok and (h = AHost) and (p = APort) and (pa = APath),
        Format('parse "%s" -> host=%s port=%s path=%s (got %s/%s/%s)',
        [AUrl, AHost, APort, APath, h, p, pa]));
  end;

var
  prov: TGitProvider;
  base, detail: string;
begin
  WriteLn('-- JoinRemote --');
  Check(JoinRemote('ssh://git@host/srv/git', 'foo.git') =
    'ssh://git@host/srv/git/foo.git', 'ssh base + leaf');
  Check(JoinRemote('git@host:', 'foo.git') = 'git@host:foo.git', 'scp-like, no path');
  Check(JoinRemote('git@host:dir', 'foo.git') = 'git@host:dir/foo.git',
    'scp-like with dir');
  Check(JoinRemote('/srv/git/', 'foo.git') = '/srv/git/foo.git', 'trailing slash path');

  WriteLn('-- ParseSshTarget --');
  CheckParse('ssh://git@host:2222/srv/git/foo.git', True, 'git@host',
    '2222', '/srv/git/foo.git');
  CheckParse('ssh://git@host/srv/foo.git', True, 'git@host', '', '/srv/foo.git');
  CheckParse('git@host:srv/foo.git', True, 'git@host', '', 'srv/foo.git');
  CheckParse('/srv/git/foo.git', False, '', '', '');
  CheckParse('file:///srv/foo.git', False, '', '', '');

  WriteLn('-- TGitProvider local create --');
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-remote-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  ForceDirectories(base);
  prov := TGitProvider.Create(base);
  try
    Check(prov.PushUrl('foo') = IncludeTrailingPathDelimiter(base) + 'foo.git',
      'push url for local base');
    Check(prov.EnsureRemote('foo', detail) = erCreated, 'creates local bare repo (' +
      detail + ')');
    Check(DirectoryExists(IncludeTrailingPathDelimiter(base) + 'foo.git'),
      'bare repo exists on disk');
    Check(prov.EnsureRemote('foo', detail) = erExists, 'second call sees existing repo');
  finally
    prov.Free;
  end;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
