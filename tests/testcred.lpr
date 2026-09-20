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

program testcred;

{ Credential-store FILE fallback hardening (gboxcredstore). Forces the file
  backend (GOTBOX_FORCE_CRED_FALLBACK) and isolates the config dir, then checks:
    - a token round-trips through the fallback;
    - the on-disk cred.dat is the new "user<TAB>scheme<TAB>base64" format with a
      real scheme (mkey/dpapi), NOT the legacy fixed-XOR;
    - the plaintext token never appears in the file (protected at rest);
    - delete removes it;
    - several backends' accounts coexist in one file: saving one does not evict
      another, and deleting one leaves the rest readable.

  The environment must be set BEFORE the process starts (FPC captures it at
  startup), so on first launch we re-exec ourselves as a child with an explicit
  environment -- portable, and avoids the libc-setenv-not-seen-by-FPC gotcha. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Process,
  gboxlog,
  gboxconfigstore,
  gboxbackend,
  gboxcredstore;

const
  CHILD_MARK = 'GOTBOX_TESTCRED_CHILD';

{ Re-launch this binary with the fallback forced and the config dir isolated to
  ABase; returns the child's exit code. }
  function RunChild(const ABase: string): Integer;
  var
    p: TProcess;
    i: Integer;
  begin
    p := TProcess.Create(nil);
    try
      p.Executable := ParamStr(0);
      for i := 1 to GetEnvironmentVariableCount do
        p.Environment.Add(GetEnvironmentString(i));
      p.Environment.Values['GOTBOX_FORCE_CRED_FALLBACK'] := '1';
      {$IFDEF LINUX}
    p.Environment.Values['XDG_CONFIG_HOME'] := ABase;
      {$ENDIF}
      {$IFDEF DARWIN}
    p.Environment.Values['HOME'] := ABase;   // GotConfigDir uses HOME on macOS
      {$ENDIF}
      {$IFDEF WINDOWS}
    p.Environment.Values['APPDATA'] := ABase; // GotConfigDir uses APPDATA on Windows
      {$ENDIF}
      p.Environment.Values[CHILD_MARK] := '1';
      p.Options := [poWaitOnExit];   // inherit console so the child's output shows
      p.Execute;
      Result := p.ExitStatus;
    finally
      p.Free;
    end;
  end;

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

  procedure ReadCred(const APath: string; out AFirst, AWhole: string);
  var
    f: TStringList;
  begin
    AFirst := '';
    AWhole := '';
    f := TStringList.Create;
    try
      f.LoadFromFile(APath);
      AWhole := f.Text;
      if f.Count > 0 then AFirst := f[0];
    finally
      f.Free;
    end;
  end;

  function CountChar(const S: string; C: Char): Integer;
  var
    i: Integer;
  begin
    Result := 0;
    for i := 1 to Length(S) do
      if S[i] = C then Inc(Result);
  end;

var
  cred: TCredStore;
  tok, cfgDir, credFile, firstLine, whole, scheme, rest, base: string;
  p: Integer;
const
  SECRET = 'ghp_SECRETtokenVALUE_1234567890';
  SECRET2 = 'glpat_OTHERtokenVALUE_0987654321';
begin
  // first launch: set up an isolated env and re-exec ourselves into it
  if GetEnvironmentVariable(CHILD_MARK) = '' then
  begin
    Randomize;
    base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-cred-' +
      FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
    ForceDirectories(base);
    Halt(RunChild(base));
  end;

  // child: the forced-fallback env is now in effect
  cfgDir := GotConfigDir;
  credFile := IncludeTrailingPathDelimiter(cfgDir) + 'cred.dat';
  WriteLn('config dir: ', cfgDir);

  cred := TCredStore.Create;
  try
    Check(cred.SaveToken('octocat', SECRET), 'save token (forced fallback)');
    Check(FileExists(credFile), 'cred.dat written');

    Check(cred.LoadToken('octocat', tok) and (tok = SECRET),
      'token round-trips through the fallback');

    ReadCred(credFile, firstLine, whole);
    Check(Pos(SECRET, whole) = 0, 'plaintext token is NOT in cred.dat');

    // new format: user<TAB>scheme<TAB>base64 -> exactly two tabs
    Check(CountChar(firstLine, #9) = 2,
      'cred.dat uses the user<TAB>scheme<TAB>data format');
    p := Pos(#9, firstLine);
    rest := Copy(firstLine, p + 1, MaxInt);   // scheme<TAB>data
    scheme := Copy(rest, 1, Pos(#9, rest) - 1);
    Check((scheme = 'mkey') or (scheme = 'dpapi'),
      'scheme is machine-bound/dpapi, not legacy xor (' + scheme + ')');

    Check(cred.DeleteToken('octocat'), 'delete token');
    Check(not cred.LoadToken('octocat', tok), 'token gone after delete');

    // ---- several backends' accounts share one fallback file ----
    // Saving used to rewrite the file with a single line, so a second backend's
    // token silently evicted the first one.
    Check(cred.SaveToken(CredKey(bkGitHub, '', 'octocat'), SECRET),
      'save the github account');
    Check(cred.SaveToken(CredKey(bkGitLab, 'https://gitlab.com', 'octocat'),
      SECRET2), 'save a gitlab account with the same login');
    Check(cred.LoadToken(CredKey(bkGitHub, '', 'octocat'), tok) and (tok = SECRET),
      'the github token survived the gitlab save');
    Check(cred.LoadToken(CredKey(bkGitLab, 'https://gitlab.com', 'octocat'), tok) and
      (tok = SECRET2), 'the gitlab token round-trips');
    Check(not cred.LoadToken(CredKey(bkGitLab, 'https://git.ex.com', 'octocat'), tok),
      'a different gitlab host is a different account');

    // deleting one account must leave the other readable (it used to delete
    // the whole file)
    Check(cred.DeleteToken(CredKey(bkGitLab, 'https://gitlab.com', 'octocat')),
      'delete just the gitlab account');
    Check(cred.LoadToken(CredKey(bkGitHub, '', 'octocat'), tok) and (tok = SECRET),
      'the github token is still there after deleting gitlab');

    ReadCred(credFile, firstLine, whole);
    Check(Pos(SECRET, whole) = 0, 'no plaintext token with several accounts');
    Check(Pos(SECRET2, whole) = 0, 'no plaintext second token either');
    Check(cred.DeleteToken(CredKey(bkGitHub, '', 'octocat')), 'delete the last account');
  finally
    cred.Free;
  end;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
