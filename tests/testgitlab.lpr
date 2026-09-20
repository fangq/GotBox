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

program testgitlab;

{ Offline coverage of the GitLab REST helpers (gboxgitlabapi): project-path
  encoding, host normalization for self-managed instances, and the response
  parsers. The live calls need a server and a real token, so they are exercised
  manually; here we pin everything that can be checked without a network. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  gboxgitlabapi;

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

const
  USER_JSON = '{"id":42,"username":"octocat","name":"Octo Cat",' +
    '"state":"active"}';
  PROJECT_JSON = '{"id":7,"path":"photos","visibility":"private",' +
    '"http_url_to_repo":"https://gitlab.com/octocat/photos.git",' +
    '"web_url":"https://gitlab.com/octocat/photos"}';
  TAKEN_JSON = '{"message":{"path":["has already been taken"],' +
    '"name":["has already been taken"]}}';
  SCOPE_JSON = '{"error":"insufficient_scope"}';

var
  s: string;
begin
  // ---- percent-encoding ----
  Check(UrlEncodeComponent('photos') = 'photos', 'plain text is untouched');
  Check(UrlEncodeComponent('a/b') = 'a%2Fb', 'slash is encoded');
  Check(UrlEncodeComponent('my repo') = 'my%20repo', 'space is encoded');
  Check(UrlEncodeComponent('-._~') = '-._~', 'unreserved marks survive');
  Check(UrlEncodeComponent('caf' + #$C3#$A9) = 'caf%C3%A9', 'UTF-8 goes byte-wise');

  // ---- the project id GitLab wants in a path ----
  Check(EncodeProjectPath('octocat', 'photos') = 'octocat%2Fphotos',
    'user namespace encodes');
  Check(EncodeProjectPath('team/sub', 'photos') = 'team%2Fsub%2Fphotos',
    'a nested group encodes');
  Check(EncodeProjectPath('', 'photos') = 'photos', 'an empty namespace is skipped');

  // ---- host normalization (self-managed instances) ----
  Check(GitLabApiBase('https://gitlab.com') = 'https://gitlab.com/api/v4',
    'gitlab.com base');
  Check(GitLabApiBase('') = 'https://gitlab.com/api/v4', 'an empty host defaults');
  Check(GitLabApiBase('gitlab.example.edu') = 'https://gitlab.example.edu/api/v4',
    'a bare host gets https');
  Check(GitLabApiBase('https://gitlab.example.edu/') =
    'https://gitlab.example.edu/api/v4', 'a trailing slash is dropped');
  Check(GitLabApiBase('https://example.edu:8443/gitlab') =
    'https://example.edu:8443/gitlab/api/v4', 'port and path prefix survive');

  // ---- response parsing ----
  Check(ParseUserLogin(USER_JSON, s) and (s = 'octocat'),
    'username is read from /user');
  Check(not ParseUserLogin('{}', s), 'an empty object is not a user');
  Check(not ParseUserLogin('<html>login</html>', s),
    'an HTML login page is not a user');
  Check(ParseProjectUrl(PROJECT_JSON, s) and
    (s = 'https://gitlab.com/octocat/photos.git'), 'clone url is read');
  Check(not ParseProjectUrl('{"id":7}', s), 'a project with no url fails');

  // ---- the race another machine wins ----
  Check(IsAlreadyTakenError(TAKEN_JSON), '"already been taken" is recognized');
  Check(not IsAlreadyTakenError(PROJECT_JSON), 'a good project is not "taken"');

  // ---- error text a user can act on ----
  Check(Pos('api', LowerCase(GitLabErrorText(401, ''))) > 0,
    '401 mentions the api scope');
  Check(Pos('server url', LowerCase(GitLabErrorText(404, ''))) > 0,
    '404 points at the server URL');
  Check(Pos('insufficient_scope', GitLabErrorText(400, SCOPE_JSON)) > 0,
    'the server message is passed through');
  Check(Pos('500', GitLabErrorText(500, 'boom')) > 0,
    'an unparseable body still reports the status');

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
