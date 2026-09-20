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

program testbackend;

{ Offline coverage of the per-backend policy table (gboxbackend): kind parsing,
  push limits, size-rejection matching, the LFS veto that keeps S3 from eating
  large files, and the credential-store key scheme. Pure functions only -- no
  network, no git, no filesystem. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  gboxbackend;

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
  { A real GH001 rejection, trimmed. }
  GH_OVERSIZE =
    'remote: error: GH001: Large files detected. You may want to try Git ' +
    'Large File Storage.' + LineEnding +
    'remote: error: File big.bin is 123.00 MB; this exceeds GitHub''s file ' +
    'size limit of 100.00 MB';
  GL_OVERSIZE =
    'remote: fatal: pack exceeds maximum allowed size' + LineEnding +
    'remote: GitLab: Your push was rejected: file exceeds the maximum ' +
    'allowed size';
  GL_TOO_LARGE = 'error: RPC failed; HTTP 413 curl 22 The requested URL ' +
    'returned error: 413 Request Entity Too Large';
  { Must never read as an oversize rejection on any backend. }
  AUTH_FAILURE = 'git@host: Permission denied (publickey).' + LineEnding +
    'fatal: Could not read from remote repository.';

var
  k: TBackendKind;
begin
  // ---- kind round-trip ----
  for k := Low(TBackendKind) to High(TBackendKind) do
    Check(ParseBackendKind(BackendKindName(k)) = k,
      'kind round-trips: ' + BackendKindName(k));
  Check(ParseBackendKind('') = bkGitHub, 'empty kind reads as github');
  Check(ParseBackendKind('GitHub') = bkGitHub, 'kind parsing is case-insensitive');
  Check(ParseBackendKind('GitLab') = bkGitLab, 'GitLab parses');
  Check(ParseBackendKind('dropbox') = bkGitHub, 'unknown kind falls back to github');

  // ---- who needs a token ----
  Check(BackendNeedsToken(bkGitHub), 'github needs a token');
  Check(BackendNeedsToken(bkGitLab), 'gitlab needs a token');
  Check(not BackendNeedsToken(bkGit), 'self-hosted git uses ssh keys');
  Check(not BackendNeedsToken(bkS3), 's3 uses the AWS credential chain');

  // ---- push limits ----
  Check(PushFileLimitBytes(bkGitHub) = Int64(100) * 1024 * 1024,
    'github limit is 100 MB');
  Check(PushFileLimitBytes(bkGitLab) = 0, 'gitlab has no assumed limit');
  Check(PushFileLimitBytes(bkGit) = 0, 'self-hosted git has no limit');
  Check(PushFileLimitBytes(bkS3) = 0, 's3 has no limit');

  // ---- size-rejection matching ----
  Check(IsSizeRejection(bkGitHub, GH_OVERSIZE), 'GH001 is an oversize rejection');
  Check(not IsSizeRejection(bkS3, GH_OVERSIZE), 'GH001 text is not an s3 rejection');
  Check(IsSizeRejection(bkGitLab, GL_OVERSIZE), 'GitLab size rejection matches');
  Check(IsSizeRejection(bkGitLab, GL_TOO_LARGE), 'HTTP 413 matches on gitlab');
  for k := Low(TBackendKind) to High(TBackendKind) do
    Check(not IsSizeRejection(k, AUTH_FAILURE),
      'an ssh auth failure is never oversize: ' + BackendKindName(k));

  // ---- LFS veto (a pointer on s3 would be an unrecoverable empty file) ----
  Check(EffectiveLfsThresholdMB(bkS3, 95) = 0, 's3 disables LFS tracking');
  Check(EffectiveLfsThresholdMB(bkGitHub, 95) = 95, 'github keeps the configured LFS threshold');
  Check(EffectiveLfsThresholdMB(bkGitLab, 0) = 0, 'LFS stays off when configured off');

  // ---- poll floor ----
  Check(MinPollIntervalSec(bkS3) >= 60, 's3 polling is clamped to >= 60s');
  Check(MinPollIntervalSec(bkGitHub) <= 15, 'github polling is not clamped up');

  // ---- credential keys ----
  Check(CredKey(bkGitHub, '', 'alice') = 'alice',
    'github keeps the bare login key (existing users stay signed in)');
  Check(CredKey(bkGitLab, 'https://gitlab.com', 'alice') = 'gitlab:gitlab.com:alice',
    'gitlab key is scoped by host');
  Check(CredKey(bkGitLab, 'https://Git.EX.com:8443/gl', 'alice') =
    'gitlab:git.ex.com:8443:alice', 'gitlab key keeps the port, drops scheme/path');
  Check(CredKey(bkGitLab, '', 'alice') = 'gitlab:gitlab.com:alice',
    'a blank gitlab host defaults to gitlab.com');
  Check(CredKey(bkGitHub, '', '') = '', 'no user means no key');
  Check(CredKey(bkGit, 'host', 'alice') = '', 'ssh backend stores no token');
  Check(CredKey(bkS3, '', 'alice') = '', 's3 stores no token');

  // ---- URL helpers ----
  Check(HostPortOf('https://gitlab.com/') = 'gitlab.com', 'host of a plain url');
  Check(HostPortOf('https://alice@git.ex.com:8443/gl') = 'git.ex.com:8443',
    'host drops userinfo, keeps port');
  Check(InsertUrlUser('https://gitlab.com/a/b.git', 'alice') =
    'https://alice@gitlab.com/a/b.git', 'user is inserted after the scheme');
  Check(InsertUrlUser('https://bob@gitlab.com/a/b.git', 'alice') =
    'https://bob@gitlab.com/a/b.git', 'an existing user is left alone');
  Check(InsertUrlUser('s3://bucket/prefix', 'alice') = 's3://alice@bucket/prefix',
    'insertion is scheme-agnostic');
  Check(InsertUrlUser('/srv/git', 'alice') = '/srv/git', 'a path is left alone');

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
