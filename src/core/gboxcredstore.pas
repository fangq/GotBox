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

unit gboxcredstore;

{ Cross-platform storage for the GitHub Personal Access Token.

  Per-platform backend:
    Linux  -> secret-tool (libsecret)
    macOS  -> security (Keychain)
    Windows-> DPAPI (CryptProtectData) ciphertext in a per-user file

  The token blob is stored in a small file in the config dir
  (user<TAB>scheme<TAB>base64). On Windows the blob is DPAPI-encrypted to the
  current user, so only that user on that machine can decrypt it. On platforms
  without a secret-tool/Keychain CLI, the file is encrypted with a keystream
  derived from a stable machine secret (e.g. /etc/machine-id) plus the username,
  so a copied/backed-up cred.dat is useless on another machine or to another
  user; the file is also locked to 0600. This is not a substitute for a real OS
  keychain (an attacker running as the same user on the same box can re-derive the
  key), so GotBox still warns and recommends installing libsecret/gnome-keyring.
  The token is never written to config.json.

  Set GOTBOX_FORCE_CRED_FALLBACK=1 to bypass the OS keychain and always use the
  file backend (useful on headless boxes and for tests). }

{$mode objfpc}{$H+}

interface

type
  TCredStore = class
  private
    function FallbackFile: string;
    function SaveFallback(const AUser, AToken: string): Boolean;
    function LoadFallback(const AUser: string; out AToken: string): Boolean;
    function DeleteFallback: Boolean;
  public
  const
    ServiceName = 'gotbox';
    { Stores AToken for AUser. Returns True on success. }
    function SaveToken(const AUser, AToken: string): Boolean;
    { Loads the token for AUser. Returns False if none stored. }
    function LoadToken(const AUser: string; out AToken: string): Boolean;
    { Removes any stored token for AUser. }
    function DeleteToken(const AUser: string): Boolean;
    { True if a native OS secret store CLI is present. }
    function HasNativeStore: Boolean;
  end;

implementation

uses
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  {$IFDEF DARWIN}StrUtils,{$ENDIF}
  Classes, SysUtils, Process, base64, sha1, gboxconfigstore, gboxlog;

type
  TStringArray = array of string;   // secret-tool env override list

{ Run a process, optionally feeding AInput to stdin, capturing stdout. When
  AEnvOverride is non-empty (each 'NAME=VALUE'), the child gets the current
  environment with those names overridden/added; otherwise it inherits ours.
  Returns exit code; AOut receives stdout. }
function RunCaptureEnv(const AExe: string; const AArgs: array of string;
  const AInput: string; out AOut: string; const AEnvOverride: array of string): Integer;
var
  proc: TProcess;
  outStream: TStringStream;
  buf: array[0..2047] of Byte;
  n: Integer;
  i, j: Integer;
  envName, cur, curName: string;
  taken: array of Boolean;
begin
  Result := -1;
  AOut := '';
  proc := TProcess.Create(nil);
  outStream := TStringStream.Create('');
  try
    proc.Executable := AExe;
    for i := 0 to High(AArgs) do
      proc.Parameters.Add(AArgs[i]);
    // Build a full environment (TProcess.Environment REPLACES, not merges) when
    // overrides are requested: copy ours, then apply each override.
    if Length(AEnvOverride) > 0 then
    begin
      SetLength(taken, Length(AEnvOverride));
      for i := 0 to High(taken) do taken[i] := False;
      for i := 1 to GetEnvironmentVariableCount do
      begin
        cur := GetEnvironmentString(i);
        curName := Copy(cur, 1, Pos('=', cur) - 1);
        for j := 0 to High(AEnvOverride) do
        begin
          envName := Copy(AEnvOverride[j], 1, Pos('=', AEnvOverride[j]) - 1);
          if (envName <> '') and SameText(curName, envName) then
          begin
            cur := AEnvOverride[j];   // override this one
            taken[j] := True;
            Break;
          end;
        end;
        proc.Environment.Add(cur);
      end;
      for j := 0 to High(AEnvOverride) do
        if not taken[j] then proc.Environment.Add(AEnvOverride[j]);   // add new
    end;
    proc.Options := [poUsePipes, poNoConsole];
    try
      proc.Execute;
    except
      on E: Exception do
      begin
        Result := -2; // exe not found / failed to start
        Exit;
      end;
    end;
    if AInput <> '' then
      proc.Input.Write(AInput[1], Length(AInput));
    proc.CloseInput;
    repeat
      n := proc.Output.NumBytesAvailable;
      if n > 0 then
      begin
        if n > SizeOf(buf) then n := SizeOf(buf);
        n := proc.Output.Read(buf, n);
        if n > 0 then outStream.Write(buf, n);
      end
      else if not proc.Running then
        Break
      else
        Sleep(5);
    until False;
    Result := proc.ExitStatus;
    AOut := outStream.DataString;
  finally
    outStream.Free;
    proc.Free;
  end;
end;

{ Inherit our environment unchanged. }
function RunCapture(const AExe: string; const AArgs: array of string;
  const AInput: string; out AOut: string): Integer;
begin
  Result := RunCaptureEnv(AExe, AArgs, AInput, AOut, []);
end;

function WhichExe(const AName: string): string;
begin
  Result := FileSearch(AName, GetEnvironmentVariable('PATH'));
end;

{ Bypass the OS keychain and use the file backend (headless boxes / tests). }
function CredFallbackForced: Boolean;
begin
  Result := GetEnvironmentVariable('GOTBOX_FORCE_CRED_FALLBACK') <> '';
end;

{$IFDEF LINUX}
{ The systemd per-user D-Bus session bus (unix:path=/run/user/<uid>/bus), where
  gnome-keyring / the Secret Service registers. Over x2go/NX (and other
  non-login sessions) DBUS_SESSION_BUS_ADDRESS points at a private bus with no
  secret-service, so secret-tool finds nothing there; retrying against this bus
  reaches the real keyring. Empty if that bus socket doesn't exist. }
function UserSecretBusEnv: TStringArray;
var
  rt: string;
begin
  Result := [];
  rt := '/run/user/' + IntToStr(FpGetuid);
  if FileExists(rt + '/bus') then
    Result := ['XDG_RUNTIME_DIR=' + rt,
               'DBUS_SESSION_BUS_ADDRESS=unix:path=' + rt + '/bus'];
end;

{ secret-tool, retried on the systemd user bus if the inherited session yields
  nothing. Returns the exit code; AOut has stdout. }
function SecretTool(const AArgs: array of string; const AInput: string;
  out AOut: string): Integer;
var
  env: TStringArray;
begin
  Result := RunCapture('secret-tool', AArgs, AInput, AOut);
  // rc 0 = success (a `lookup` that finds nothing exits non-zero), so only retry
  // on failure -- e.g. the session bus has no secret-service (x2go/NX).
  if Result = 0 then Exit;
  env := UserSecretBusEnv;
  if Length(env) > 0 then
    Result := RunCaptureEnv('secret-tool', AArgs, AInput, AOut, env);
end;
{$ENDIF}

{ ---- TCredStore ---- }

function TCredStore.HasNativeStore: Boolean;
begin
  {$IFDEF LINUX}
  Result := WhichExe('secret-tool') <> '';
  {$ELSE}
  {$IFDEF DARWIN}
  Result := WhichExe('security') <> '';
  {$ELSE}
  {$IFDEF WINDOWS}
  Result := True;   // DPAPI is always available
  {$ELSE}
  Result := False;
  {$ENDIF}
  {$ENDIF}
  {$ENDIF}
end;

function TCredStore.SaveToken(const AUser, AToken: string): Boolean;
var
  outp: string;
  rc: Integer;
begin
  {$IFDEF LINUX}
  if (not CredFallbackForced) and (WhichExe('secret-tool') <> '') then
  begin
    rc := SecretTool(
      ['store', '--label=GotBox', 'service', ServiceName, 'account', AUser],
      AToken, outp);
    Result := rc = 0;
    if Result then begin if Assigned(Log) then Log.Info('cred', 'token saved (libsecret)'); Exit; end;
  end;
  {$ENDIF}
  {$IFDEF DARWIN}
  if (not CredFallbackForced) and (WhichExe('security') <> '') then
  begin
    rc := RunCapture('security',
      ['add-generic-password', '-a', AUser, '-s', ServiceName, '-w', AToken, '-U'],
      '', outp);
    Result := rc = 0;
    if Result then begin if Assigned(Log) then Log.Info('cred', 'token saved (Keychain)'); Exit; end;
  end;
  {$ENDIF}
  Result := SaveFallback(AUser, AToken);
end;

function TCredStore.LoadToken(const AUser: string; out AToken: string): Boolean;
var
  outp: string;
  rc: Integer;
begin
  AToken := '';
  {$IFDEF LINUX}
  if (not CredFallbackForced) and (WhichExe('secret-tool') <> '') then
  begin
    rc := SecretTool(
      ['lookup', 'service', ServiceName, 'account', AUser], '', outp);
    if (rc = 0) and (outp <> '') then
    begin
      AToken := TrimRight(outp); // secret-tool does not append a newline, but be safe
      Exit(True);
    end;
  end;
  {$ENDIF}
  {$IFDEF DARWIN}
  if (not CredFallbackForced) and (WhichExe('security') <> '') then
  begin
    rc := RunCapture('security',
      ['find-generic-password', '-a', AUser, '-s', ServiceName, '-w'], '', outp);
    if (rc = 0) and (outp <> '') then
    begin
      AToken := TrimRight(outp);
      Exit(True);
    end;
  end;
  {$ENDIF}
  Result := LoadFallback(AUser, AToken);
end;

function TCredStore.DeleteToken(const AUser: string): Boolean;
var
  outp: string;
begin
  {$IFDEF LINUX}
  if (not CredFallbackForced) and (WhichExe('secret-tool') <> '') then
    SecretTool(['clear', 'service', ServiceName, 'account', AUser], '', outp);
  {$ENDIF}
  {$IFDEF DARWIN}
  if (not CredFallbackForced) and (WhichExe('security') <> '') then
    RunCapture('security', ['delete-generic-password', '-a', AUser, '-s', ServiceName], '', outp);
  {$ENDIF}
  Result := DeleteFallback;
end;

{ ---- file fallback (DPAPI on Windows; machine-bound keystream elsewhere) ---- }

function TCredStore.FallbackFile: string;
begin
  Result := IncludeTrailingPathDelimiter(GotConfigDir) + 'cred.dat';
end;

{ Legacy fixed-key obfuscation -- kept ONLY to read/upgrade old cred.dat files. }
function XorObfuscate(const S: string): string;
const
  KEY: array[0..7] of Byte = ($67, $6F, $74, $62, $6F, $78, $21, $5A); // 'gotbox!Z'
var
  i: Integer;
begin
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do
    Result[i] := Chr(Ord(S[i]) xor KEY[(i - 1) mod Length(KEY)]);
end;

function ReadFirstLine(const APath: string): string;
var
  sl: TStringList;
begin
  Result := '';
  if not FileExists(APath) then Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(APath);
      if sl.Count > 0 then Result := Trim(sl[0]);
    except
    end;
  finally
    sl.Free;
  end;
end;

{ A stable per-machine secret: /etc/machine-id (Linux), the hardware UUID
  (macOS), else a hostname+uid fallback. Binds the fallback key to this machine
  so a copied cred.dat can't be decrypted elsewhere. }
function MachineSecret: string;
  {$IFDEF DARWIN}
var
  outp: string;
  a, b, e: Integer;
  {$ENDIF}
begin
  Result := '';
  {$IFDEF LINUX}
  Result := ReadFirstLine('/etc/machine-id');
  if Result = '' then Result := ReadFirstLine('/var/lib/dbus/machine-id');
  {$ENDIF}
  {$IFDEF DARWIN}
  if RunCapture('ioreg', ['-rd1', '-c', 'IOPlatformExpertDevice'], '', outp) = 0 then
  begin
    a := Pos('IOPlatformUUID', outp);
    if a > 0 then
    begin
      b := PosEx('= "', outp, a);
      if b > 0 then
      begin
        b := b + 3;
        e := PosEx('"', outp, b);
        if e > b then Result := Copy(outp, b, e - b);
      end;
    end;
  end;
  {$ENDIF}
  if Result = '' then
  {$IFDEF UNIX}
    Result := 'host:' + GetEnvironmentVariable('HOSTNAME') + ':uid:' +
      IntToStr(FpGetuid);
    {$ELSE}
    Result := 'host:' + GetEnvironmentVariable('COMPUTERNAME');
  {$ENDIF}
end;

{ A keystream of ALen bytes from ASeed via chained SHA-1 blocks (enough to mask a
  PAT -- this is at-rest obfuscation keyed to the machine, not authenticated
  encryption). }
function KeyStream(const ASeed: string; ALen: Integer): TBytes;
var
  d: TSHA1Digest;
  blk, i, o: Integer;
begin
  SetLength(Result, ALen);
  o := 0;
  blk := 0;
  while o < ALen do
  begin
    d := SHA1String(ASeed + '#' + IntToStr(blk));
    for i := 0 to High(d) do
    begin
      if o >= ALen then Break;
      Result[o] := d[i];
      Inc(o);
    end;
    Inc(blk);
  end;
end;

{ XOR S with a machine+user keystream (symmetric). }
function MKeyXor(const S, ASeed: string): string;
var
  ks: TBytes;
  i: Integer;
begin
  ks := KeyStream(ASeed, Length(S));
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do
    Result[i] := Chr(Ord(S[i]) xor ks[i - 1]);
end;

{$IFDEF WINDOWS}
{ Windows DPAPI. Declared with self-contained types so we don't pull in the
  Windows unit (which would shadow SysUtils.GetEnvironmentVariable used above). }
type
  TDataBlob = record
    cbData: cardinal;
    pbData: PByte;
  end;
  PDataBlob = ^TDataBlob;

const
  CRYPTPROTECT_UI_FORBIDDEN = $1;
  DPAPI_ENTROPY = 'GotBox-DPAPI-v1';   // app-specific entropy

function CryptProtectData(pDataIn: PDataBlob; szDataDescr: PWideChar;
  pOptionalEntropy: PDataBlob; pvReserved, pPromptStruct: Pointer;
  dwFlags: cardinal; pDataOut: PDataBlob): LongBool; stdcall;
  external 'crypt32' name 'CryptProtectData';
function CryptUnprotectData(pDataIn: PDataBlob; ppszDataDescr: Pointer;
  pOptionalEntropy: PDataBlob; pvReserved, pPromptStruct: Pointer;
  dwFlags: cardinal; pDataOut: PDataBlob): LongBool; stdcall;
  external 'crypt32' name 'CryptUnprotectData';
function LocalFree(hMem: Pointer): Pointer; stdcall;
  external 'kernel32' name 'LocalFree';

function DpapiRun(const AData: string; AProtect: Boolean): string;
var
  inBlob, outBlob, entBlob: TDataBlob;
  ent: ansistring;
  ok: LongBool;
begin
  Result := '';
  ent := DPAPI_ENTROPY;
  inBlob.cbData := Length(AData);
  if Length(AData) > 0 then inBlob.pbData := PByte(@AData[1]) else inBlob.pbData := nil;
  entBlob.cbData := Length(ent);
  entBlob.pbData := PByte(@ent[1]);
  FillChar(outBlob, SizeOf(outBlob), 0);
  if AProtect then
    ok := CryptProtectData(@inBlob, nil, @entBlob, nil, nil,
      CRYPTPROTECT_UI_FORBIDDEN, @outBlob)
  else
    ok := CryptUnprotectData(@inBlob, nil, @entBlob, nil, nil,
      CRYPTPROTECT_UI_FORBIDDEN, @outBlob);
  if ok then
  begin
    SetLength(Result, outBlob.cbData);
    if outBlob.cbData > 0 then Move(outBlob.pbData^, Result[1], outBlob.cbData);
    LocalFree(outBlob.pbData);
  end;
end;
{$ENDIF}

{ Protect the token bytes for at-rest storage and report the scheme used:
  'dpapi' on Windows, else 'mkey' (machine+user keystream). ASeed binds the mkey
  scheme to this machine and user. }
function ProtectToken(const AToken, ASeed: string; out AScheme: string): string;
begin
  {$IFDEF WINDOWS}
  AScheme := 'dpapi';
  Result := DpapiRun(AToken, True);
  {$ELSE}
  AScheme := 'mkey';
  Result := MKeyXor(AToken, ASeed);
  {$ENDIF}
end;

{ Reverse ProtectToken for the recorded scheme; 'xor' is the legacy fixed-key
  format, decoded only so an old file can be read and upgraded. }
function UnprotectToken(const AData, ASeed, AScheme: string): string;
begin
  if AScheme = 'dpapi' then
  begin
    {$IFDEF WINDOWS}
    Result := DpapiRun(AData, False);
    {$ELSE}
    Result := '';   // a Windows-written file on a non-Windows host: unreadable
    {$ENDIF}
  end
  else if AScheme = 'mkey' then
    Result := MKeyXor(AData, ASeed)
  else
    Result := XorObfuscate(AData);   // legacy 'xor'
end;

function TCredStore.SaveFallback(const AUser, AToken: string): Boolean;
var
  f: TStringList;
  scheme, blob, path: string;
begin
  Result := False;
  try
    scheme := '';
    blob := ProtectToken(AToken, MachineSecret + '|' + AUser, scheme);
    f := TStringList.Create;
    try
      // user<TAB>scheme<TAB>base64(protected(token))
      f.Add(AUser + #9 + scheme + #9 + EncodeStringBase64(blob));
      path := FallbackFile;
      f.SaveToFile(path);
      {$IFDEF UNIX}
      FpChmod(path, &600);   // owner-only rw
      {$ENDIF}
      Result := True;
      if Assigned(Log) then
        if scheme = 'dpapi' then
          Log.Info('cred', 'token saved (DPAPI-encrypted file)')
        else
          Log.Warn('cred', 'no OS keychain; token saved to a machine-bound ' +
            'encrypted file (' + path + '). Install libsecret/gnome-keyring for ' +
            'stronger protection.');
    finally
      f.Free;
    end;
  except
    on E: Exception do
      if Assigned(Log) then Log.Error('cred', 'fallback save failed: ' + E.Message);
  end;
end;

function TCredStore.LoadFallback(const AUser: string; out AToken: string): Boolean;
var
  f: TStringList;
  line, u, scheme, enc, seed: string;
  p, i: Integer;
  legacy: Boolean;
begin
  Result := False;
  AToken := '';
  if not FileExists(FallbackFile) then Exit;
  f := TStringList.Create;
  try
    f.LoadFromFile(FallbackFile);
    for i := 0 to f.Count - 1 do
    begin
      line := f[i];
      p := Pos(#9, line);
      if p <= 0 then Continue;
      u := Copy(line, 1, p - 1);
      if not SameText(u, AUser) then Continue;
      line := Copy(line, p + 1, MaxInt);   // remainder after the user field
      p := Pos(#9, line);
      if p > 0 then                        // new format: scheme<TAB>base64
      begin
        scheme := Copy(line, 1, p - 1);
        enc := Copy(line, p + 1, MaxInt);
        legacy := False;
      end
      else                                 // legacy format: base64 (fixed-XOR)
      begin
        scheme := 'xor';
        enc := line;
        legacy := True;
      end;
      seed := MachineSecret + '|' + AUser;
      AToken := UnprotectToken(DecodeStringBase64(enc), seed, scheme);
      Result := AToken <> '';
      // transparently upgrade a legacy weak-XOR file to the machine-bound scheme
      if Result and legacy then SaveFallback(AUser, AToken);
      Exit;
    end;
  finally
    f.Free;
  end;
end;

function TCredStore.DeleteFallback: Boolean;
begin
  Result := True;
  if FileExists(FallbackFile) then
    Result := DeleteFile(FallbackFile);
end;

end.
