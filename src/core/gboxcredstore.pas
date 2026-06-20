unit gboxcredstore;

{ Cross-platform storage for the GitHub Personal Access Token.

  Primary backend is the OS secret store, accessed via its CLI:
    Linux  -> secret-tool (libsecret)
    macOS  -> security (Keychain)
    Windows-> (DPAPI-encrypted file; see note below)

  If the native store is unavailable, falls back to an obfuscated file in the
  config dir. NOTE: the file fallback is light obfuscation, not strong
  encryption -- on Windows a DPAPI (CryptProtectData) backend should replace it
  before release. The token is never written to config.json. }

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
  Classes, SysUtils, Process, base64, gboxconfigstore, gboxlog;

{ Run a process, optionally feeding AInput to stdin, capturing stdout.
  Returns exit code; AOut receives stdout. }
function RunCapture(const AExe: string; const AArgs: array of string;
  const AInput: string; out AOut: string): Integer;
var
  proc: TProcess;
  outStream: TStringStream;
  buf: array[0..2047] of Byte;
  n: Integer;
  i: Integer;
begin
  Result := -1;
  AOut := '';
  proc := TProcess.Create(nil);
  outStream := TStringStream.Create('');
  try
    proc.Executable := AExe;
    for i := 0 to High(AArgs) do
      proc.Parameters.Add(AArgs[i]);
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

function WhichExe(const AName: string): string;
begin
  Result := FileSearch(AName, GetEnvironmentVariable('PATH'));
end;

{ ---- TCredStore ---- }

function TCredStore.HasNativeStore: Boolean;
begin
  {$IFDEF LINUX}
  Result := WhichExe('secret-tool') <> '';
  {$ELSE}
  {$IFDEF DARWIN}
  Result := WhichExe('security') <> '';
  {$ELSE}
  Result := False; // Windows: DPAPI backend TBD; use fallback for now
  {$ENDIF}
  {$ENDIF}
end;

function TCredStore.SaveToken(const AUser, AToken: string): Boolean;
var
  outp: string;
  rc: Integer;
begin
  {$IFDEF LINUX}
  if WhichExe('secret-tool') <> '' then
  begin
    rc := RunCapture('secret-tool',
      ['store', '--label=GotBox', 'service', ServiceName, 'account', AUser],
      AToken, outp);
    Result := rc = 0;
    if Result then begin if Assigned(Log) then Log.Info('cred', 'token saved (libsecret)'); Exit; end;
  end;
  {$ENDIF}
  {$IFDEF DARWIN}
  if WhichExe('security') <> '' then
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
  if WhichExe('secret-tool') <> '' then
  begin
    rc := RunCapture('secret-tool',
      ['lookup', 'service', ServiceName, 'account', AUser], '', outp);
    if (rc = 0) and (outp <> '') then
    begin
      AToken := TrimRight(outp); // secret-tool does not append a newline, but be safe
      Exit(True);
    end;
  end;
  {$ENDIF}
  {$IFDEF DARWIN}
  if WhichExe('security') <> '' then
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
  if WhichExe('secret-tool') <> '' then
    RunCapture('secret-tool', ['clear', 'service', ServiceName, 'account', AUser], '', outp);
  {$ENDIF}
  {$IFDEF DARWIN}
  if WhichExe('security') <> '' then
    RunCapture('security', ['delete-generic-password', '-a', AUser, '-s', ServiceName], '', outp);
  {$ENDIF}
  Result := DeleteFallback;
end;

{ ---- file fallback (obfuscated; not strong crypto) ---- }

function TCredStore.FallbackFile: string;
begin
  Result := IncludeTrailingPathDelimiter(GotConfigDir) + 'cred.dat';
end;

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

function TCredStore.SaveFallback(const AUser, AToken: string): Boolean;
var
  f: TStringList;
begin
  Result := False;
  try
    f := TStringList.Create;
    try
      // store as user<TAB>base64(xor(token))
      f.Add(AUser + #9 + EncodeStringBase64(XorObfuscate(AToken)));
      f.SaveToFile(FallbackFile);
      Result := True;
      if Assigned(Log) then
        Log.Warn('cred', 'token saved to obfuscated fallback file (no native store)');
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
  line, u, enc: string;
  p, i: Integer;
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
      enc := Copy(line, p + 1, MaxInt);
      if SameText(u, AUser) then
      begin
        AToken := XorObfuscate(DecodeStringBase64(enc));
        Exit(AToken <> '');
      end;
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
