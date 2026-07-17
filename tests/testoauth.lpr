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

program testoauth;

{ Offline coverage of the device-flow JSON parsers (gboxoauth). The live network
  calls need a browser authorization, so they are exercised manually; here we
  pin the response parsing that classifies each poll outcome. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  gboxoauth;

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

  function StatusOf(const AJson: string): TPollStatus;
  var
    tok: string;
    st: TPollStatus;
  begin
    Check(ParseTokenResp(AJson, tok, st), 'token response parses: ' + AJson);
    Result := st;
  end;

var
  dev: TDeviceCode;
  tok: string;
  st: TPollStatus;
begin
  // ---- device code ----
  Check(ParseDeviceCode('{"device_code":"3584d83530557fdd1f46af8289938c8ef79f9dc5",' +
    '"user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device",' +
    '"expires_in":900,"interval":5}', dev), 'device code parses');
  Check(dev.UserCode = 'WDJB-MJHT', 'user_code extracted');
  Check(dev.DeviceCode = '3584d83530557fdd1f46af8289938c8ef79f9dc5',
    'device_code extracted');
  Check(dev.VerificationUri = 'https://github.com/login/device',
    'verification_uri extracted');
  Check(dev.Interval = 5, 'interval extracted');
  Check(dev.ExpiresIn = 900, 'expires_in extracted');
  Check(not ParseDeviceCode('{"error":"nope"}', dev),
    'a non-device-code JSON is rejected');
  Check(not ParseDeviceCode('not json', dev), 'garbage is rejected');

  // ---- token poll outcomes ----
  Check(StatusOf('{"error":"authorization_pending","error_description":"..."}') =
    psPending,
    'authorization_pending -> psPending');
  Check(StatusOf('{"error":"slow_down","interval":10}') = psSlowDown,
    'slow_down -> psSlowDown');
  Check(StatusOf('{"error":"expired_token"}') = psExpired, 'expired_token -> psExpired');
  Check(StatusOf('{"error":"access_denied"}') = psDenied, 'access_denied -> psDenied');
  Check(StatusOf('{"error":"unmapped_thing"}') = psError, 'unknown error -> psError');

  Check(ParseTokenResp('{"access_token":"ghu_abc123","token_type":"bearer","scope":""}',
    tok, st) and (st = psSuccess) and (tok = 'ghu_abc123'),
    'access_token -> psSuccess with the token');

  // ---- client id / availability ----
  Check(OAuthClientId <> '', 'a client id is configured');
  Check(OAuthAvailable, 'device-flow sign-in is available');

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
