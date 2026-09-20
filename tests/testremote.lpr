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

program testremote;

{ Tests the remote providers: URL joining, ssh-target parsing, local bare-repo
  auto-creation (the path the SSH backend also uses, minus the ssh hop which
  needs a real server), the GitLab/S3 URL shapes, the config-driven factory,
  and the shared auth resolver. The GitLab REST calls and any real S3 traffic
  need a live server, so only their offline halves are pinned here. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  gboxlog,
  gboxgitlabapi,
  gboxbackend,
  gboxconfigstore,
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
  gprov: TGitProvider;
  prov: TRemoteProvider;
  glprov: TGitLabProvider;
  s3prov: TS3Provider;
  cfg: TGotConfig;
  env: TStringList;
  base, detail, tok, err: string;
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
  gprov := TGitProvider.Create(base);
  try
    // JoinRemote always uses '/' (a remote URL separator), regardless of the
    // host path separator -- so compare against that, not the OS delimiter.
    Check(gprov.PushUrl('foo') = base + '/foo.git', 'push url for local base');
    Check(gprov.EnsureRemote('foo', detail) = erCreated, 'creates local bare repo (' +
      detail + ')');
    Check(DirectoryExists(IncludeTrailingPathDelimiter(base) + 'foo.git'),
      'bare repo exists on disk');
    Check(gprov.EnsureRemote('foo', detail) = erExists, 'second call sees existing repo');
  finally
    gprov.Free;
  end;


  // ---- TGitLabProvider: URL shapes (no network) ----
  WriteLn('-- TGitLabProvider urls --');
  glprov := TGitLabProvider.Create('https://gitlab.com', '', 'alice', 'glpat-x');
  try
    Check(glprov.DisplayUrl('photos') = 'https://gitlab.com/alice/photos.git',
      'gitlab.com display url uses the personal namespace');
    Check(glprov.PushUrl('photos') = 'https://alice@gitlab.com/alice/photos.git',
      'push url carries the user, never the token');
    Check(Pos('glpat-x', glprov.PushUrl('photos')) = 0,
      'the token never appears in a URL');
    Check(glprov.AuthUser = 'alice', 'auth user is the login');
    Check(glprov.AuthToken = 'glpat-x', 'auth token is the PAT');
  finally
    glprov.Free;
  end;

  glprov := TGitLabProvider.Create('https://git.ex.edu:8443/gl', 'team/sub',
    'alice', 'glpat-x');
  try
    Check(glprov.DisplayUrl('photos') =
      'https://git.ex.edu:8443/gl/team/sub/photos.git',
      'self-managed host, port, path prefix and group namespace');
    Check(glprov.PushUrl('photos') =
      'https://alice@git.ex.edu:8443/gl/team/sub/photos.git',
      'push url inserts the user after the scheme');
  finally
    glprov.Free;
  end;

  glprov := TGitLabProvider.Create('https://gitlab.com/', '', 'alice', 'x', tkOAuth);
  try
    Check(glprov.AuthUser = 'oauth2', 'an OAuth token authenticates as oauth2');
    Check(glprov.DisplayUrl('p') = 'https://gitlab.com/alice/p.git',
      'a trailing slash on the host does not double up');
  finally
    glprov.Free;
  end;

  // ---- TS3Provider: URL shape + the missing-helper path ----
  WriteLn('-- TS3Provider --');
  s3prov := TS3Provider.Create('s3://my-bucket/gotbox/', 'work', 'us-east-1');
  try
    Check(s3prov.PushUrl('photos') = 's3://my-bucket/gotbox/photos',
      's3 url is a key prefix, with no .git suffix');
    Check(s3prov.DisplayUrl('photos') = s3prov.PushUrl('photos'),
      's3 display url carries no secret, so it matches the push url');
    env := TStringList.Create;
    try
      s3prov.GetRunnerEnv(env);
      Check(env.Values['AWS_PROFILE'] = 'work', 'the AWS profile is passed through');
      Check(env.Values['AWS_REGION'] = 'us-east-1', 'the region is passed through');
      Check(env.IndexOfName('AWS_SECRET_ACCESS_KEY') < 0,
        'GotBox never puts an AWS secret in the environment');
    finally
      env.Free;
    end;
  finally
    s3prov.Free;
  end;

  // With the helper absent, every S3 path must fail loudly rather than look
  // like "the repo just does not exist yet" -- that would send the engine into
  // a push that cannot work. FPC reads the environment captured at startup, so
  // this cannot be forced from inside the process; run the checks when the
  // machine genuinely lacks the helper (the usual case, including CI) and set
  // GOTBOX_S3_HELPER to a nonexistent path to exercise it where it is present.
  if S3HelperPath <> '' then
    WriteLn('  skip - git-remote-s3 is installed here; missing-helper path not checked')
  else
  begin
    Check(S3HelperPath = '', 'a missing helper is reported as absent');
    s3prov := TS3Provider.Create('s3://my-bucket/gotbox', '', '');
    try
      Check(s3prov.EnsureRemote('photos', detail) = erError,
        'EnsureRemote fails without the helper');
      Check(Pos('git-remote-s3', detail) > 0, 'and says what to install');
      Check(not s3prov.RemoteExists('photos'),
        'RemoteExists is False without the helper');
    finally
      s3prov.Free;
    end;
  end;

  // ---- the factory picks by configured kind ----
  WriteLn('-- MakeProvider --');
  cfg := TGotConfig.Create;
  try
    cfg.SetDefaults;
    cfg.RemoteUser := 'alice';

    cfg.RemoteKind := 'github';
    prov := MakeProvider(cfg, 'tok');
    Check(prov is TGitHubProvider, 'github -> TGitHubProvider');
    prov.Free;

    cfg.RemoteKind := 'gitlab';
    prov := MakeProvider(cfg, 'tok');
    Check(prov is TGitLabProvider, 'gitlab -> TGitLabProvider');
    prov.Free;

    cfg.RemoteKind := 'git';
    cfg.SshBase := '/srv/git';
    prov := MakeProvider(cfg, '');
    Check(prov is TGitProvider, 'git -> TGitProvider');
    prov.Free;

    cfg.RemoteKind := 's3';
    cfg.S3Base := 's3://b/p';
    prov := MakeProvider(cfg, '');
    Check(prov is TS3Provider, 's3 -> TS3Provider');
    prov.Free;

    cfg.RemoteKind := 'nonsense';
    prov := MakeProvider(cfg, 'tok');
    Check(prov is TGitHubProvider, 'an unknown kind falls back to github');
    prov.Free;

    // ---- the shared auth resolver ----
    WriteLn('-- ResolveRemoteAuth --');
    cfg.RemoteKind := 'git';
    cfg.SshBase := '';
    Check(not ResolveRemoteAuth(cfg, tok, err), 'ssh backend needs a base URL');
    cfg.SshBase := '/srv/git';
    Check(ResolveRemoteAuth(cfg, tok, err) and (tok = ''),
      'ssh backend resolves with no token');

    cfg.RemoteKind := 's3';
    cfg.S3Base := '';
    Check(not ResolveRemoteAuth(cfg, tok, err), 's3 needs a bucket');
    cfg.S3Base := 's3://b/p';
    if S3HelperPath = '' then
    begin
      Check(not ResolveRemoteAuth(cfg, tok, err), 's3 needs the helper installed');
      Check(Pos('git-remote-s3', err) > 0, 'and names it');
    end
    else
      Check(ResolveRemoteAuth(cfg, tok, err) and (tok = ''),
        's3 resolves with no token when the helper is installed');

    cfg.RemoteKind := 'gitlab';
    cfg.RemoteUser := '';
    Check(not ResolveRemoteAuth(cfg, tok, err), 'gitlab needs a signed-in user');
    Check(Pos('GitLab', err) > 0, 'and the message names GitLab, not GitHub');

    // ---- summaries ----
    cfg.RemoteKind := 'gitlab';
    cfg.RemoteUser := 'alice';
    cfg.GitLabHost := 'https://git.ex.edu';
    Check(Pos('git.ex.edu', BackendSummary(cfg)) > 0, 'summary names the host');
    Check(Pos('alice', BackendSummary(cfg)) > 0, 'summary names the account');
    cfg.RemoteKind := 's3';
    Check(Pos('s3://b/p', BackendSummary(cfg)) > 0, 'summary names the bucket');

    // ---- credential keys come from the backend policy ----
    cfg.RemoteKind := 'github';
    Check(CredAccount(cfg) = 'alice', 'github keeps the bare login as its key');
    cfg.RemoteKind := 'gitlab';
    Check(CredAccount(cfg) = 'gitlab:git.ex.edu:alice', 'gitlab scopes its key by host');
    cfg.RemoteKind := 'git';
    Check(CredAccount(cfg) = '', 'the ssh backend has no key');
    Check(RemoteAuthUser(cfg) = '', 'the ssh backend authenticates as nobody');
    cfg.RemoteKind := 'github';
    Check(RemoteAuthUser(cfg) = 'alice', 'github authenticates as the login');
  finally
    cfg.Free;
  end;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
