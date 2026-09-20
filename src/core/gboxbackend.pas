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

unit gboxbackend;

{ What each storage backend is like: the push size limit, whether Git LFS can
  work there, how a size rejection reads, how fast it is sane to poll, and how
  its token is keyed in the credential store.

  This is deliberately a *policy* unit with no dependencies beyond SysUtils. The
  sync engine (gboxsync, gboxlfs, gboxrecover, gboxrepoworker) needs these
  answers but must not gain an HTTP/OpenSSL dependency to get them -- which is
  what asking gboxremote would cost, since that unit reaches the REST clients.

  LCL-free. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  { The storage backends GotBox can put a repo on. }
  TBackendKind = (bkGitHub, bkGitLab, bkGit, bkS3);

const
  { GitHub rejects a plain `git push` carrying any file over this size; nothing
    GotBox can do transports such a file without Git LFS. }
  GITHUB_FILE_LIMIT = Int64(100) * 1024 * 1024;

  { Installed by pip/pipx; git resolves remote helpers from PATH only. }
  S3_HELPER_EXE = 'git-remote-s3';
  S3_HELPER_MISSING_MSG =
    'The S3 backend needs the git-remote-s3 helper, which is not installed.' +
    LineEnding + 'Install it with:  pipx install git-remote-s3' + LineEnding +
    '(or: python3 -m pip install --user git-remote-s3)';

{ Config string -> kind. Unknown or empty reads as GitHub, which is what every
  pre-backend config meant. }
function ParseBackendKind(const AKind: string): TBackendKind;
{ Kind -> the string stored in config.json. }
function BackendKindName(AKind: TBackendKind): string;
{ Kind -> a name to show a user. }
function BackendLabel(AKind: TBackendKind): string;

{ True when this backend authenticates with a token GotBox has to hold (as
  opposed to ssh keys or the ambient AWS credential chain). }
function BackendNeedsToken(AKind: TBackendKind): Boolean;

{ Largest file this backend accepts in a plain push; 0 means "no known limit",
  which tells the engine to skip the oversize machinery entirely. }
function PushFileLimitBytes(AKind: TBackendKind): Int64;
{ True if AText is this backend's "your file is too big" push rejection. Kept
  narrow on purpose: mislabelling an auth or network failure as an oversize
  rejection would send the repo into the wrong recovery path. }
function IsSizeRejection(AKind: TBackendKind; const AText: string): Boolean;

{ The LFS threshold actually usable on this backend, in MB (0 = do not track).
  S3 has no LFS endpoint, so tracking there would commit a pointer whose bytes
  can never be uploaded -- the file would arrive empty on every other machine. }
function EffectiveLfsThresholdMB(AKind: TBackendKind; AConfigMB: Integer): Integer;

{ Floor for the periodic ls-remote probe. Going through the S3 remote helper
  starts a Python interpreter per probe per repo, so a 15 s poll would burn a
  process every few seconds forever. }
function MinPollIntervalSec(AKind: TBackendKind): Integer;

{ Credential-store account key. GitHub keeps the bare login it has always used
  -- prefixing it would sign every existing user out -- while the newer kinds
  are scoped, since the same login on gitlab.com and on a company instance are
  different accounts with different tokens. Returns '' for the keyless kinds. }
function CredKey(AKind: TBackendKind; const AHost, AUser: string): string;

{ 'https://git.ex.com:8443/gl' -> 'git.ex.com:8443' (lowercased, no path). }
function HostPortOf(const AUrl: string): string;
{ 'https://host/p' + 'alice' -> 'https://alice@host/p'. Leaves a URL that
  already carries userinfo, and anything without '://', untouched. }
function InsertUrlUser(const AUrl, AUser: string): string;

implementation

function ParseBackendKind(const AKind: string): TBackendKind;
begin
  if SameText(AKind, 'gitlab') then Result := bkGitLab
  else if SameText(AKind, 'git') then Result := bkGit
  else if SameText(AKind, 's3') then Result := bkS3
  else
    Result := bkGitHub;
end;

function BackendKindName(AKind: TBackendKind): string;
begin
  case AKind of
    bkGitLab: Result := 'gitlab';
    bkGit: Result := 'git';
    bkS3: Result := 's3';
    else
      Result := 'github';
  end;
end;

function BackendLabel(AKind: TBackendKind): string;
begin
  case AKind of
    bkGitLab: Result := 'GitLab';
    bkGit: Result := 'Self-hosted git';
    bkS3: Result := 'S3';
    else
      Result := 'GitHub';
  end;
end;

function BackendNeedsToken(AKind: TBackendKind): Boolean;
begin
  Result := AKind in [bkGitHub, bkGitLab];
end;

function PushFileLimitBytes(AKind: TBackendKind): Int64;
begin
  case AKind of
    bkGitHub: Result := GITHUB_FILE_LIMIT;
    // GitLab's cap is per-instance (receive_max_input_size); self-managed
    // servers routinely raise or drop it, so assume none and let the push
    // rejection itself be the signal.
    else
      Result := 0;
  end;
end;

function IsSizeRejection(AKind: TBackendKind; const AText: string): Boolean;
var
  s: string;
begin
  s := LowerCase(AText);
  case AKind of
    bkGitHub:
      Result := (Pos('gh001', s) > 0) or (Pos('file size limit', s) > 0) or
        (Pos('exceeds github', s) > 0);
    bkGitLab:
      Result := (Pos('maximum allowed size', s) > 0) or
        (Pos('request entity too large', s) > 0) or
        (Pos('http 413', s) > 0);
    else
      Result := False;
  end;
end;

function EffectiveLfsThresholdMB(AKind: TBackendKind; AConfigMB: Integer): Integer;
begin
  if AKind = bkS3 then Result := 0      // no LFS endpoint -- see the header note
  else
    Result := AConfigMB;
end;

function MinPollIntervalSec(AKind: TBackendKind): Integer;
begin
  if AKind = bkS3 then Result := 60
  else
    Result := 1;
end;

function CredKey(AKind: TBackendKind; const AHost, AUser: string): string;
var
  host: string;
begin
  Result := '';
  if AUser = '' then Exit;
  case AKind of
    bkGitHub: Result := AUser;          // unchanged since the first release
    bkGitLab:
    begin
      host := HostPortOf(AHost);
      if host = '' then host := 'gitlab.com';
      Result := 'gitlab:' + host + ':' + AUser;
    end;
    else
      Result := '';                     // ssh keys / the AWS chain: nothing to store
  end;
end;

function HostPortOf(const AUrl: string): string;
var
  s: string;
  p: Integer;
begin
  s := Trim(AUrl);
  p := Pos('://', s);
  if p > 0 then s := Copy(s, p + 3, MaxInt);
  p := Pos('@', s);                     // drop any userinfo
  if p > 0 then s := Copy(s, p + 1, MaxInt);
  p := Pos('/', s);
  if p > 0 then s := Copy(s, 1, p - 1);
  Result := LowerCase(s);
end;

function InsertUrlUser(const AUrl, AUser: string): string;
var
  p: Integer;
  rest: string;
begin
  Result := AUrl;
  if (AUser = '') or (AUrl = '') then Exit;
  p := Pos('://', AUrl);
  if p <= 0 then Exit;
  rest := Copy(AUrl, p + 3, MaxInt);
  if Pos('@', rest) > 0 then Exit;      // already carries userinfo
  Result := Copy(AUrl, 1, p + 2) + AUser + '@' + rest;
end;

end.
