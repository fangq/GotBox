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

unit gboxgithubapi;

{ Minimal GitHub REST client used for token validation and auto-creating the
  private repos that back each synced folder. Uses fphttpclient over TLS
  (opensslsockets). All calls are blocking -- invoke from a worker thread. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TGitHubApi = class
  private
    FToken: string;
    function Request(const AMethod, AUrl, ABody: string; out AStatus: Integer;
      out AResponse: string): Boolean;
  public
    constructor Create(const AToken: string);
    property Token: string read FToken write FToken;

    { Validates the token (GET /user). On success returns True and the
      authenticated login name in ALogin. }
    function ValidateToken(out ALogin: string; out AError: string): Boolean;

    { True if owner/repo already exists (GET /repos/:owner/:repo). }
    function RepoExists(const AOwner, ARepo: string): Boolean;

    { Creates a private repo for the authenticated user (POST /user/repos).
      Returns the clone URL in ACloneUrl on success. }
    function CreatePrivateRepo(const ARepo: string; out ACloneUrl: string;
      out AError: string): Boolean;
  end;

implementation

uses
  fphttpclient,
  // TLS handler registration: opensslsockets exists on FPC 3.2+; on 3.0.x
  // (e.g. Ubuntu 20.04 / Lazarus 2.0) fall back to fpopenssl + openssl.
  {$IF FPC_FULLVERSION >= 30200}
  opensslsockets,
  {$ELSE}
  fpopenssl, openssl,
  {$ENDIF}
  fpjson, jsonparser, DateUtils, gboxlog;

const
  API_BASE = 'https://api.github.com';

constructor TGitHubApi.Create(const AToken: string);
begin
  inherited Create;
  FToken := AToken;
end;

{ Case-insensitive lookup of a response header value ("Name: Value" lines). }
function HeaderValue(AHeaders: TStrings; const AName: string): string;
var
  i, c: Integer;
  ln: string;
begin
  Result := '';
  if AHeaders = nil then Exit;
  for i := 0 to AHeaders.Count - 1 do
  begin
    ln := AHeaders[i];
    c := Pos(':', ln);
    if (c > 0) and SameText(Trim(Copy(ln, 1, c - 1)), AName) then
      Exit(Trim(Copy(ln, c + 1, MaxInt)));
  end;
end;

{ Seconds to wait if the client's last response was a GitHub rate-limit refusal
  (0 = not rate-limited). Honors Retry-After (secondary limit) and, when the
  primary quota is exhausted (X-RateLimit-Remaining: 0), X-RateLimit-Reset. }
function RateLimitWaitSec(AClient: TFPHTTPClient): Integer;
var
  ra, rem, reset: string;
  d: Int64;
begin
  Result := 0;
  ra := HeaderValue(AClient.ResponseHeaders, 'Retry-After');
  if ra <> '' then
    Result := StrToIntDef(Trim(ra), 0);
  rem := HeaderValue(AClient.ResponseHeaders, 'X-RateLimit-Remaining');
  reset := HeaderValue(AClient.ResponseHeaders, 'X-RateLimit-Reset');
  if (Trim(rem) = '0') and (reset <> '') then
  begin
    d := StrToInt64Def(Trim(reset), 0) - DateTimeToUnix(Now);
    if d > Result then Result := d;
  end;
  if Result < 0 then Result := 0;
end;

function TGitHubApi.Request(const AMethod, AUrl, ABody: string;
  out AStatus: Integer; out AResponse: string): Boolean;
const
  MAX_RL_RETRIES = 2;    // bounded: at most this many rate-limit waits
  RL_WAIT_CAP = 45;      // ...each capped so a call can't block a worker too long
var
  client: TFPHTTPClient;
  reqBody: TStringStream;
  respStream: TStringStream;
  attempt, waitSec: Integer;
begin
  Result := False;
  AStatus := 0;
  AResponse := '';
  client := TFPHTTPClient.Create(nil);
  respStream := TStringStream.Create('');
  reqBody := nil;
  try
    client.AddHeader('User-Agent', 'gotbox');
    client.AddHeader('Accept', 'application/vnd.github+json');
    client.AddHeader('X-GitHub-Api-Version', '2022-11-28');
    if FToken <> '' then
      client.AddHeader('Authorization', 'Bearer ' + FToken);
    client.AllowRedirect := True;

    if ABody <> '' then
    begin
      reqBody := TStringStream.Create(ABody);
      client.RequestBody := reqBody;
      client.AddHeader('Content-Type', 'application/json');
    end;

    for attempt := 0 to MAX_RL_RETRIES do
    begin
      try
        respStream.Size := 0;   // fresh buffer for each (re)try
        client.HTTPMethod(AMethod, AUrl, respStream, []);
        AStatus := client.ResponseStatusCode;
        AResponse := respStream.DataString;
        Result := True;
      except
        on E: Exception do
        begin
          if Assigned(Log) then
            Log.Error('github', AMethod + ' ' + AUrl + ': ' + E.Message);
          AResponse := E.Message;
          Result := False;
          Break;
        end;
      end;
      // GitHub signals rate limiting with 403/429; wait out the reset and retry
      // rather than surfacing a confusing failure. Bounded so we never hang.
      if ((AStatus = 403) or (AStatus = 429)) and (attempt < MAX_RL_RETRIES) then
      begin
        waitSec := RateLimitWaitSec(client);
        if waitSec > 0 then
        begin
          if waitSec > RL_WAIT_CAP then waitSec := RL_WAIT_CAP;
          if Assigned(Log) then
            Log.Warn('github', Format('rate limited; waiting %ds then retrying %s',
              [waitSec, AUrl]));
          Sleep(waitSec * 1000);
          Continue;
        end;
      end;
      Break;   // success, non-rate-limit status, or out of retries
    end;
  finally
    respStream.Free;
    reqBody.Free;
    client.Free;
  end;
end;

function TGitHubApi.ValidateToken(out ALogin: string; out AError: string): Boolean;
var
  status: Integer;
  resp: string;
  j: TJSONData;
begin
  Result := False;
  ALogin := '';
  AError := '';
  if not Request('GET', API_BASE + '/user', '', status, resp) then
  begin
    AError := resp;
    Exit;
  end;
  if status = 200 then
  begin
    try
      j := GetJSON(resp);
      try
        if j is TJSONObject then
          ALogin := TJSONObject(j).Get('login', '');
      finally
        j.Free;
      end;
    except
    end;
    Result := ALogin <> '';
    if not Result then AError := 'Unexpected response from GitHub';
  end
  else if status = 401 then
    AError := 'Token rejected (401). Check the token and the "repo" scope.'
  else
    AError := Format('GitHub returned status %d', [status]);
end;

function TGitHubApi.RepoExists(const AOwner, ARepo: string): Boolean;
var
  status: Integer;
  resp: string;
begin
  Result := False;
  if Request('GET', Format('%s/repos/%s/%s', [API_BASE, AOwner, ARepo]),
    '', status, resp) then
    Result := status = 200;
end;

function TGitHubApi.CreatePrivateRepo(const ARepo: string; out ACloneUrl: string;
  out AError: string): Boolean;
var
  status: Integer;
  resp, body: string;
  obj, j: TJSONData;
begin
  Result := False;
  ACloneUrl := '';
  AError := '';
  obj := TJSONObject.Create;
  try
    TJSONObject(obj).Add('name', ARepo);
    TJSONObject(obj).Add('private', True);
    TJSONObject(obj).Add('auto_init', False);
    body := obj.AsJSON;
  finally
    obj.Free;
  end;

  if not Request('POST', API_BASE + '/user/repos', body, status, resp) then
  begin
    AError := resp;
    Exit;
  end;

  if (status = 201) then
  begin
    try
      j := GetJSON(resp);
      try
        if j is TJSONObject then
          ACloneUrl := TJSONObject(j).Get('clone_url', '');
      finally
        j.Free;
      end;
    except
    end;
    Result := ACloneUrl <> '';
    if Result and Assigned(Log) then Log.Info('github', 'created private repo ' + ARepo);
    if not Result then AError := 'Repo created but clone_url missing';
  end
  else
    AError := Format('GitHub create repo failed (status %d): %s', [status, resp]);
end;

end.
