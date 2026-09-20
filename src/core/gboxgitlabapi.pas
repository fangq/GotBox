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

unit gboxgitlabapi;

{ Minimal GitLab REST v4 client: validate a token, check whether a project
  exists, and create a private one. The GitHub twin of this unit is
  gboxgithubapi -- same shape, same blocking/off-the-GUI-thread contract, same
  bounded rate-limit retry -- because the callers only swap a class.

  Works against gitlab.com and any self-managed instance: the host (and an
  optional path prefix, as in https://example.edu/gitlab) comes from config.

  A Personal Access Token goes in the PRIVATE-TOKEN header; an OAuth token
  (device flow, later) goes in Authorization: Bearer. That is the only thing
  that differs between the two, hence TGitLabTokenKind.

  The response parsing is split out into pure functions so it can be unit-tested
  offline -- the network half needs a live server and a real token. LCL-free. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TGitLabTokenKind = (tkPat, tkOAuth);

  TGitLabApi = class
  private
    FToken, FApiBase: string;
    FTokenKind: TGitLabTokenKind;
    function Request(const AMethod, AUrl, ABody: string;
      out AStatus: Integer; out AResponse: string): Boolean;
  public
    { AHostBase is the server root, e.g. https://gitlab.com. }
    constructor Create(const AToken: string; const AHostBase: string = '';
      ATokenKind: TGitLabTokenKind = tkPat);
    property Token: string read FToken write FToken;
    property TokenKind: TGitLabTokenKind read FTokenKind write FTokenKind;
    property ApiBase: string read FApiBase;

    { GET /user -- confirms the token and learns the canonical username. }
    function ValidateToken(out ALogin: string; out AError: string): Boolean;
    { GET /projects/<ns%2Fname> -- False also when the server errors (never
      guess "missing", or the caller would try to create an existing project). }
    function RepoExists(const AOwner, ARepo: string): Boolean;
    { POST /projects -- creates <AOwner>/<ARepo> private. True also when GitLab
      says the path is already taken (another machine won the race), with
      AExisted set so the caller does not seed a repo that may already have
      commits. }
    function CreatePrivateRepo(const AOwner, ARepo: string;
      out AHttpUrl: string; out AError: string; out AExisted: Boolean): Boolean;
  end;

{ ---- pure helpers (unit-testable, no network) ---- }

{ Percent-encodes one URL path segment per RFC 3986: everything but
  A-Za-z0-9-._~ is encoded byte-wise, so '/' becomes %2F and UTF-8 goes out one
  byte at a time. }
function UrlEncodeComponent(const S: string): string;
{ 'grp/sub' + 'photos' -> 'grp%2Fsub%2Fphotos', the id GitLab wants in a path. }
function EncodeProjectPath(const ANamespace, AProject: string): string;
{ Normalizes a typed host into '<scheme>://host[:port][/base]/api/v4'; assumes
  https when no scheme is given and drops any trailing slash. }
function GitLabApiBase(const AHostBase: string): string;
{ Reads "username" out of a /user response. }
function ParseUserLogin(const AJson: string; out ALogin: string): Boolean;
{ Reads "http_url_to_repo" out of a project response. }
function ParseProjectUrl(const AJson: string; out AHttpUrl: string): Boolean;
{ True for the 400/422 body GitLab returns when the project already exists. }
function IsAlreadyTakenError(const AJson: string): Boolean;
{ Turns a status + body into something a user can act on. }
function GitLabErrorText(AStatus: Integer; const ABody: string): string;

implementation

uses
  fphttpclient,
  {$IF FPC_FULLVERSION >= 30200}
  opensslsockets,
  {$ELSE}
  fpopenssl, openssl,
  {$ENDIF}
  fpjson, jsonparser, DateUtils, gboxconfigstore, gboxlog;

function UrlEncodeComponent(const S: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if (c in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~']) then
      Result := Result + c
    else
      Result := Result + '%' + HexStr(Ord(c), 2);
  end;
end;

function EncodeProjectPath(const ANamespace, AProject: string): string;
var
  ns: TStringArray;
  i: Integer;
begin
  Result := '';
  // a namespace may itself be nested (group/subgroup); each part is encoded
  // separately and the separators become %2F
  ns := ANamespace.Split(['/']);
  for i := 0 to High(ns) do
    if ns[i] <> '' then
    begin
      if Result <> '' then Result := Result + '%2F';
      Result := Result + UrlEncodeComponent(ns[i]);
    end;
  if AProject = '' then Exit;
  if Result <> '' then Result := Result + '%2F';
  Result := Result + UrlEncodeComponent(AProject);
end;

function GitLabApiBase(const AHostBase: string): string;
var
  s: string;
begin
  s := Trim(AHostBase);
  if s = '' then s := GITLAB_DEFAULT_HOST;
  if Pos('://', s) = 0 then s := 'https://' + s;
  while (s <> '') and (s[Length(s)] = '/') do
    SetLength(s, Length(s) - 1);
  Result := s + '/api/v4';
end;

{ Reads a top-level string field, tolerating a non-JSON body. }
function JsonField(const AJson, AName: string): string;
var
  j: TJSONData;
begin
  Result := '';
  try
    j := GetJSON(AJson);
    try
      if j is TJSONObject then Result := TJSONObject(j).Get(AName, '');
    finally
      j.Free;
    end;
  except
    // a reverse proxy's HTML login page, a truncated body, ...
  end;
end;

function ParseUserLogin(const AJson: string; out ALogin: string): Boolean;
begin
  ALogin := JsonField(AJson, 'username');   // GitLab's field; GitHub says "login"
  Result := ALogin <> '';
end;

function ParseProjectUrl(const AJson: string; out AHttpUrl: string): Boolean;
begin
  AHttpUrl := JsonField(AJson, 'http_url_to_repo');
  Result := AHttpUrl <> '';
end;

function IsAlreadyTakenError(const AJson: string): Boolean;
var
  s: string;
begin
  // {"message":{"path":["has already been taken"],"name":[...]}}
  s := LowerCase(AJson);
  Result := (Pos('has already been taken', s) > 0) or
    (Pos('already exists', s) > 0);
end;

function GitLabErrorText(AStatus: Integer; const ABody: string): string;
var
  msg: string;
begin
  case AStatus of
    401: Result := 'Token rejected (401). The token needs the "api" scope.';
    403: Result := 'GitLab refused the request (403). Check the token scope ' +
        'and your permission on that namespace.';
    404: Result := 'No GitLab API at that address (404). Check the server URL.';
    else
    begin
      msg := JsonField(ABody, 'message');
      if msg = '' then msg := JsonField(ABody, 'error');
      if msg <> '' then
        Result := Format('GitLab returned status %d: %s', [AStatus, msg])
      else
        Result := Format('GitLab returned status %d', [AStatus]);
    end;
  end;
end;

constructor TGitLabApi.Create(const AToken: string; const AHostBase: string;
  ATokenKind: TGitLabTokenKind);
begin
  inherited Create;
  FToken := AToken;
  FApiBase := GitLabApiBase(AHostBase);
  FTokenKind := ATokenKind;
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

{ Seconds to wait after a rate-limit refusal (0 = not rate-limited). GitLab
  spells the headers without GitHub's X- prefix but means the same thing. }
function RateLimitWaitSec(AClient: TFPHTTPClient): Integer;
var
  ra, rem, reset: string;
  d: Int64;
begin
  Result := 0;
  ra := HeaderValue(AClient.ResponseHeaders, 'Retry-After');
  if ra <> '' then Result := StrToIntDef(Trim(ra), 0);
  rem := HeaderValue(AClient.ResponseHeaders, 'RateLimit-Remaining');
  reset := HeaderValue(AClient.ResponseHeaders, 'RateLimit-Reset');
  if (Trim(rem) = '0') and (reset <> '') then
  begin
    d := StrToInt64Def(Trim(reset), 0) - DateTimeToUnix(Now);
    if d > Result then Result := d;
  end;
  if Result < 0 then Result := 0;
end;

function TGitLabApi.Request(const AMethod, AUrl, ABody: string;
  out AStatus: Integer; out AResponse: string): Boolean;
const
  MAX_RL_RETRIES = 2;    // bounded: at most this many rate-limit waits
  RL_WAIT_CAP = 45;      // ...each capped so a call can't block a worker too long
var
  client: TFPHTTPClient;
  reqBody, respStream: TStringStream;
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
    client.AddHeader('Accept', 'application/json');
    if FToken <> '' then
      if FTokenKind = tkOAuth then
        client.AddHeader('Authorization', 'Bearer ' + FToken)
      else
        client.AddHeader('PRIVATE-TOKEN', FToken);
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
            Log.Error('gitlab', AMethod + ' ' + AUrl + ': ' + E.Message);
          AResponse := E.Message;
          Result := False;
          Break;
        end;
      end;
      if ((AStatus = 429) or (AStatus = 403)) and (attempt < MAX_RL_RETRIES) then
      begin
        waitSec := RateLimitWaitSec(client);
        if waitSec > 0 then
        begin
          if waitSec > RL_WAIT_CAP then waitSec := RL_WAIT_CAP;
          if Assigned(Log) then
            Log.Warn('gitlab', Format('rate limited; waiting %ds then retrying %s',
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

function TGitLabApi.ValidateToken(out ALogin: string; out AError: string): Boolean;
var
  status: Integer;
  resp: string;
begin
  Result := False;
  ALogin := '';
  AError := '';
  if not Request('GET', FApiBase + '/user', '', status, resp) then
  begin
    AError := resp;
    Exit;
  end;
  if status = 200 then
  begin
    Result := ParseUserLogin(resp, ALogin);
    if not Result then
      AError := 'Unexpected response from ' + FApiBase +
        ' -- is this a GitLab server?';
  end
  else
    AError := GitLabErrorText(status, resp);
end;

function TGitLabApi.RepoExists(const AOwner, ARepo: string): Boolean;
var
  status: Integer;
  resp: string;
begin
  Result := False;
  if not Request('GET', FApiBase + '/projects/' +
    EncodeProjectPath(AOwner, ARepo), '', status, resp) then Exit;
  if status = 200 then Exit(True);
  if status = 404 then Exit(False);
  // 401/403/500/...: we do not know. Say "no" but leave a trail, so a create
  // that then fails is explainable.
  if Assigned(Log) then
    Log.Warn('gitlab', Format('project lookup %s/%s returned %d',
      [AOwner, ARepo, status]));
end;

function TGitLabApi.CreatePrivateRepo(const AOwner, ARepo: string;
  out AHttpUrl: string; out AError: string; out AExisted: Boolean): Boolean;
var
  status, nsId: Integer;
  resp, body, nsResp: string;
  obj: TJSONObject;
begin
  Result := False;
  AHttpUrl := '';
  AError := '';
  AExisted := False;
  obj := TJSONObject.Create;
  try
    obj.Add('path', ARepo);
    obj.Add('name', ARepo);
    obj.Add('visibility', 'private');
    obj.Add('initialize_with_readme', False);
    // A group namespace has to be named by id; the personal one is implied by
    // the token, so only look it up when the owner is not the token's user.
    if (AOwner <> '') and Request('GET', FApiBase + '/namespaces/' +
      UrlEncodeComponent(AOwner), '', status, nsResp) and (status = 200) then
    begin
      nsId := StrToIntDef(JsonField(nsResp, 'id'), 0);
      if nsId > 0 then obj.Add('namespace_id', nsId);
    end;
    body := obj.AsJSON;
  finally
    obj.Free;
  end;

  if not Request('POST', FApiBase + '/projects', body, status, resp) then
  begin
    AError := resp;
    Exit;
  end;

  if status = 201 then
  begin
    Result := ParseProjectUrl(resp, AHttpUrl);
    if Result and Assigned(Log) then
      Log.Info('gitlab', 'created private project ' + AOwner + '/' + ARepo);
    if not Result then AError := 'Project created but http_url_to_repo missing';
    Exit;
  end;

  // another machine created it a moment ago -- that is a success for us, but
  // the project is NOT ours to seed
  if IsAlreadyTakenError(resp) then
  begin
    if Assigned(Log) then
      Log.Info('gitlab', 'project ' + AOwner + '/' + ARepo + ' already exists');
    AExisted := True;
    Exit(True);
  end;
  AError := GitLabErrorText(status, resp);
end;

end.
