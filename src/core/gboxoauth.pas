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

unit gboxoauth;

{ GitHub OAuth 2.0 Device Authorization Grant (RFC 8628) sign-in.

  Instead of the user creating a Personal Access Token by hand, GotBox asks
  GitHub for a short user code, the user enters it at github.com/login/device and
  authorizes GotBox's registered app, and GotBox polls until GitHub hands back an
  access token (which is then stored/used exactly like a PAT). The client id is a
  PUBLIC identifier -- the device flow needs no client secret -- so it is safe to
  ship. Override it with GOTBOX_OAUTH_CLIENT_ID; an empty id disables the flow
  (the UI falls back to manual PAT entry).

  This unit is LCL-free (pure src/core) and network-facing; call it off the GUI
  thread. The JSON parsers are split out so they can be unit-tested offline. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

const
  { GotBox's registered GitHub App. The device flow authenticates against this
    app with only the public client id (no secret). }
  GOTBOX_CLIENT_ID = 'Iv23li0oC0ziljfgAUnD';
  DEVICE_CODE_URL = 'https://github.com/login/device/code';
  DEVICE_TOKEN_URL = 'https://github.com/login/oauth/access_token';

type
  { A pending device authorization, from RequestDeviceCode. }
  TDeviceCode = record
    DeviceCode: string;       // secret handle GotBox polls with
    UserCode: string;         // short code the user types (e.g. "WDJB-MJHT")
    VerificationUri: string;  // where the user enters it
    Interval: Integer;        // min seconds between polls
    ExpiresIn: Integer;       // seconds until DeviceCode expires
  end;

  { Outcome of one token poll. }
  TPollStatus = (psPending,   // user hasn't finished yet -- keep polling
    psSlowDown,               // polling too fast -- back off, then keep polling
    psSuccess,                // got the access token
    psDenied,                 // user (or an org) refused authorization
    psExpired,                // the device code timed out -- restart the flow
    psError);                 // any other/unexpected error

{ The effective client id (env override wins over the built-in default). }
function OAuthClientId: string;

{ True if device-flow sign-in is configured (a non-empty client id). }
function OAuthAvailable: Boolean;

{ ---- pure parsers (unit-testable, no network) ---- }

{ Parse a /login/device/code JSON response. }
function ParseDeviceCode(const AJson: string; out ADev: TDeviceCode): Boolean;
{ Classify a /login/oauth/access_token JSON response; on success AToken is set. }
function ParseTokenResp(const AJson: string; out AToken: string;
  out AStatus: TPollStatus): Boolean;

{ ---- network ---- }

{ Ask GitHub to start a device authorization. Returns False + AErr on failure. }
function RequestDeviceCode(const AClientId: string; out ADev: TDeviceCode;
  out AErr: string): Boolean;

{ One poll for the access token. Returns False + AErr only on a transport error
  (an HTTP-level failure); a normal pending/slow_down/denied/expired maps to
  AStatus with Result = True. }
function PollForToken(const AClientId, ADeviceCode: string; out AToken: string;
  out AStatus: TPollStatus; out AErr: string): Boolean;

implementation

uses
  fphttpclient,
  {$IF FPC_FULLVERSION >= 30200}
  opensslsockets,
  {$ELSE}
  fpopenssl, openssl,
  {$ENDIF}
  fpjson, jsonparser, gboxlog;

function OAuthClientId: string;
begin
  Result := GetEnvironmentVariable('GOTBOX_OAUTH_CLIENT_ID');
  if Result = '' then Result := GOTBOX_CLIENT_ID;
end;

function OAuthAvailable: Boolean;
begin
  Result := Trim(OAuthClientId) <> '';
end;

function ParseDeviceCode(const AJson: string; out ADev: TDeviceCode): Boolean;
var
  j: TJSONData;
  o: TJSONObject;
begin
  Result := False;
  ADev := Default(TDeviceCode);
  if AJson = '' then Exit;
  try
    j := GetJSON(AJson);
  except
    Exit;
  end;
  try
    if not (j is TJSONObject) then Exit;
    o := TJSONObject(j);
    ADev.DeviceCode := o.Get('device_code', '');
    ADev.UserCode := o.Get('user_code', '');
    ADev.VerificationUri := o.Get('verification_uri', '');
    ADev.Interval := o.Get('interval', 5);
    ADev.ExpiresIn := o.Get('expires_in', 900);
    if ADev.Interval < 1 then ADev.Interval := 5;
    Result := (ADev.DeviceCode <> '') and (ADev.UserCode <> '');
  finally
    j.Free;
  end;
end;

function ParseTokenResp(const AJson: string; out AToken: string;
  out AStatus: TPollStatus): Boolean;
var
  j: TJSONData;
  o: TJSONObject;
  err: string;
begin
  Result := False;
  AToken := '';
  AStatus := psError;
  if AJson = '' then Exit;
  try
    j := GetJSON(AJson);
  except
    Exit;
  end;
  try
    if not (j is TJSONObject) then Exit;
    o := TJSONObject(j);
    AToken := o.Get('access_token', '');
    if AToken <> '' then
    begin
      AStatus := psSuccess;
      Exit(True);
    end;
    err := LowerCase(o.Get('error', ''));
    if err = 'authorization_pending' then AStatus := psPending
    else if err = 'slow_down' then AStatus := psSlowDown
    else if err = 'expired_token' then AStatus := psExpired
    else if (err = 'access_denied') then AStatus := psDenied
    else
      AStatus := psError;
    Result := True;   // a well-formed error response is still a valid parse
  finally
    j.Free;
  end;
end;

{ POST an x-www-form-urlencoded body and return the response body (Accept: JSON).
  ASuccess is True on a 2xx status. }
function PostForm(const AUrl, ABody: string; out AResp: string;
  out AErr: string): Boolean;
var
  client: TFPHTTPClient;
  reqBody, respStream: TStringStream;
begin
  Result := False;
  AResp := '';
  AErr := '';
  client := TFPHTTPClient.Create(nil);
  reqBody := TStringStream.Create(ABody);
  respStream := TStringStream.Create('');
  try
    client.AddHeader('User-Agent', 'gotbox');
    client.AddHeader('Accept', 'application/json');
    client.AddHeader('Content-Type', 'application/x-www-form-urlencoded');
    client.RequestBody := reqBody;
    try
      client.HTTPMethod('POST', AUrl, respStream, []);
      AResp := respStream.DataString;
      // GitHub returns 200 even for authorization_pending (error is in the body),
      // so accept any 2xx and let the caller classify the JSON.
      Result := (client.ResponseStatusCode >= 200) and
        (client.ResponseStatusCode < 300);
      if not Result then
        AErr := Format('GitHub returned status %d', [client.ResponseStatusCode]);
    except
      on E: Exception do
      begin
        AErr := E.Message;
        if Assigned(Log) then Log.Error('oauth', 'POST ' + AUrl + ': ' + E.Message);
      end;
    end;
  finally
    respStream.Free;
    reqBody.Free;
    client.Free;
  end;
end;

function RequestDeviceCode(const AClientId: string; out ADev: TDeviceCode;
  out AErr: string): Boolean;
var
  resp: string;
begin
  ADev := Default(TDeviceCode);
  // GitHub Apps derive access from their configured permissions, so no scope is
  // sent here (an OAuth App would append &scope=repo).
  Result := PostForm(DEVICE_CODE_URL, 'client_id=' + AClientId, resp, AErr);
  if not Result then Exit;
  Result := ParseDeviceCode(resp, ADev);
  if not Result then AErr := 'unexpected device-code response from GitHub';
end;

function PollForToken(const AClientId, ADeviceCode: string; out AToken: string;
  out AStatus: TPollStatus; out AErr: string): Boolean;
var
  resp, body: string;
begin
  AToken := '';
  AStatus := psError;
  body := 'client_id=' + AClientId + '&device_code=' + ADeviceCode +
    '&grant_type=urn:ietf:params:oauth:grant-type:device_code';
  Result := PostForm(DEVICE_TOKEN_URL, body, resp, AErr);
  if not Result then Exit;
  Result := ParseTokenResp(resp, AToken, AStatus);
  if not Result then AErr := 'unexpected token response from GitHub';
end;

end.
