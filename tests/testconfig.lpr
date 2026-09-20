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

program testconfig;

{ config.json schema handling (gboxconfigstore): that a pre-multi-backend file
  (schema 1, "githubUser", no backend fields) still loads with its account
  intact, that saving writes the new keys plus the legacy mirror a downgrade
  needs, and that the new backend fields round-trip. Pure file I/O in a temp
  dir -- no network, no git. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  gboxconfigstore;

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

  procedure WriteText(const APath, AText: string);
  var
    f: TStringList;
  begin
    f := TStringList.Create;
    try
      f.Text := AText;
      f.SaveToFile(APath);
    finally
      f.Free;
    end;
  end;

  function ReadText(const APath: string): string;
  var
    f: TStringList;
  begin
    f := TStringList.Create;
    try
      f.LoadFromFile(APath);
      Result := f.Text;
    finally
      f.Free;
    end;
  end;

const
  { What GotBox 0.5 and earlier wrote. }
  LEGACY_JSON =
    '{"rootDir":"/tmp/gb","remoteKind":"github","githubUser":"octocat",' +
    '"sshBase":"","machineName":"desk","historyCap":30}';

var
  dir, path, txt: string;
  store: TConfigStore;
  cfg: TGotConfig;
begin
  Randomize;
  dir := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-cfg-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  ForceDirectories(dir);
  path := IncludeTrailingPathDelimiter(dir) + 'config.json';

  // ---- a schema-1 file still signs the user in ----
  WriteText(path, LEGACY_JSON);
  store := TConfigStore.Create(path);
  try
    cfg := store.Load;
    try
      Check(cfg.RemoteUser = 'octocat', 'legacy githubUser loads as RemoteUser');
      Check(cfg.SchemaVersion = 1, 'a file with no schemaVersion reads as 1');
      Check(cfg.RemoteKind = 'github', 'remoteKind survives');
      Check(cfg.GitLabHost = GITLAB_DEFAULT_HOST,
        'a missing gitlabHost takes the default');
      Check(cfg.S3Base = '', 'a missing s3Base is empty');

      // ---- saving upgrades the file but keeps the legacy mirror ----
      cfg.RemoteKind := 'gitlab';
      cfg.GitLabHost := 'https://git.ex.com';
      cfg.GitLabNamespace := 'team/sub';
      cfg.S3Base := 's3://bucket/pre';
      cfg.AwsProfile := 'work';
      cfg.AwsRegion := 'us-east-1';
      store.Save(cfg);
    finally
      cfg.Free;
    end;
  finally
    store.Free;
  end;

  txt := ReadText(path);
  Check(Pos('"remoteUser"', txt) > 0, 'save writes remoteUser');
  Check(Pos('"githubUser"', txt) > 0,
    'save still mirrors githubUser (an older build must keep working)');
  Check(Pos('"schemaVersion"', txt) > 0, 'save stamps the schema version');

  // ---- everything round-trips ----
  store := TConfigStore.Create(path);
  try
    cfg := store.Load;
    try
      Check(cfg.SchemaVersion = CONFIG_SCHEMA_VERSION, 'schema version round-trips');
      Check(cfg.RemoteUser = 'octocat', 'remoteUser round-trips');
      Check(cfg.RemoteKind = 'gitlab', 'a non-github backend round-trips');
      Check(cfg.GitLabHost = 'https://git.ex.com', 'gitlabHost round-trips');
      Check(cfg.GitLabNamespace = 'team/sub', 'gitlabNamespace round-trips');
      Check(cfg.S3Base = 's3://bucket/pre', 's3Base round-trips');
      Check(cfg.AwsProfile = 'work', 'awsProfile round-trips');
      Check(cfg.AwsRegion = 'us-east-1', 'awsRegion round-trips');
    finally
      cfg.Free;
    end;
  finally
    store.Free;
  end;

  // ---- an unknown kind is preserved, not silently rewritten ----
  WriteText(path, '{"remoteKind":"future","remoteUser":"a"}');
  store := TConfigStore.Create(path);
  try
    cfg := store.Load;
    try
      Check(cfg.RemoteKind = 'future', 'an unknown remoteKind is kept verbatim');
      store.Save(cfg);
    finally
      cfg.Free;
    end;
  finally
    store.Free;
  end;
  Check(Pos('"future"', ReadText(path)) > 0, 'and survives a save');

  DeleteFile(path);
  RemoveDir(dir);

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
