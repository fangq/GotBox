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

program testauth;

{ Console test for gboxcredstore (save/load/delete roundtrip) and a basic
  gboxgithubapi sanity check (a bogus token must NOT validate). The GitHub call
  needs network; if offline it is reported as skipped, not failed. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  gboxlog,
  gboxcredstore,
  gboxgithubapi;

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

var
  cred: TCredStore;
  api: TGitHubApi;
  tok, login, err: string;
  ok: Boolean;
begin
  WriteLn('-- credential store --');
  cred := TCredStore.Create;
  try
    WriteLn('using native store: ', BoolToStr(cred.HasNativeStore, 'yes', 'no'));
    Check(cred.SaveToken('octocat', 'ghp_TESTtoken123'), 'save token');
    Check(cred.LoadToken('octocat', tok) and (tok = 'ghp_TESTtoken123'),
      'load token roundtrip');
    Check(cred.DeleteToken('octocat'), 'delete token');
    Check(not cred.LoadToken('octocat', tok), 'token gone after delete');
  finally
    cred.Free;
  end;

  WriteLn('-- github api --');
  api := TGitHubApi.Create('ghp_obviouslyinvalidtoken000000000000000');
  try
    ok := api.ValidateToken(login, err);
    if (not ok) and (Pos('status', err) = 0) and (Pos('401', err) = 0) and
      (Pos('rejected', err) = 0) then
      WriteLn('  skip - github validate (likely offline): ', err)
    else
      Check(not ok, 'bogus token is rejected (' + err + ')');
  finally
    api.Free;
  end;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
