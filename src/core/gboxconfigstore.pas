unit gboxconfigstore;

{ JSON-backed application configuration. The GitHub PAT is intentionally NOT
  stored here -- it lives only in the OS credential store (see gboxcredstore). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser;

type
  { Cached state for one mapped repo (root subfolder <-> GitHub repo). }
  TRepoEntry = record
    LocalName: string;   // subfolder name under RootDir (also the repo name)
    RemoteUrl: string;   // https remote (without embedded credentials)
    Paused: Boolean;     // user paused syncing for this repo
  end;
  TRepoEntryArray = array of TRepoEntry;

  TGotConfig = class
  public
    RootDir: string;
    GithubUser: string;
    MachineName: string;
    HistoryCap: Integer;        // 20..50
    CommitDebounceMs: Integer;  // coalesce save bursts
    PullIntervalSec: Integer;   // periodic sync-down
    GcEveryNCommits: Integer;   // maintenance cadence
    RepoVisibility: string;     // "private"
    IgnoreGlobs: TStringList;
    Repos: TRepoEntryArray;
    constructor Create;
    destructor Destroy; override;
    procedure SetDefaults;
    function FindRepo(const ALocalName: string; out AEntry: TRepoEntry): Boolean;
    procedure UpsertRepo(const AEntry: TRepoEntry);
  end;

  TConfigStore = class
  private
    FPath: string;
  public
    constructor Create(const APath: string);
    property Path: string read FPath;
    function Load: TGotConfig;
    procedure Save(ACfg: TGotConfig);
  end;

{ Returns the per-user config directory for gotbox (created if missing). }
function GotConfigDir: string;
{ Returns the per-user data directory (logs, etc.). }
function GotDataDir: string;

implementation

{$IFDEF WINDOWS}
uses Windows;
{$ENDIF}

function GotConfigDir: string;
begin
  {$IFDEF WINDOWS}
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('APPDATA')) + 'gotbox';
  {$ELSE}
  {$IFDEF DARWIN}
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME'))
    + 'Library/Application Support/gotbox';
  {$ELSE}
  Result := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if Result = '' then
    Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.config';
  Result := IncludeTrailingPathDelimiter(Result) + 'gotbox';
  {$ENDIF}
  {$ENDIF}
  ForceDirectories(Result);
end;

function GotDataDir: string;
begin
  {$IFDEF WINDOWS}
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('LOCALAPPDATA')) + 'gotbox';
  {$ELSE}
  {$IFDEF DARWIN}
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME'))
    + 'Library/Logs/gotbox';
  {$ELSE}
  Result := GetEnvironmentVariable('XDG_DATA_HOME');
  if Result = '' then
    Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) +
      '.local/share';
  Result := IncludeTrailingPathDelimiter(Result) + 'gotbox';
  {$ENDIF}
  {$ENDIF}
  ForceDirectories(Result);
end;

{ ---- TGotConfig ---- }

constructor TGotConfig.Create;
begin
  inherited Create;
  IgnoreGlobs := TStringList.Create;
  SetDefaults;
end;

destructor TGotConfig.Destroy;
begin
  IgnoreGlobs.Free;
  inherited Destroy;
end;

procedure TGotConfig.SetDefaults;
begin
  RootDir := '';
  GithubUser := '';
  MachineName := GetEnvironmentVariable(
    {$IFDEF WINDOWS}
'COMPUTERNAME'
    {$ELSE}
    'HOSTNAME'
    {$ENDIF}
    );
  if MachineName = '' then
    MachineName := 'machine';
  HistoryCap := 30;
  CommitDebounceMs := 5000;
  PullIntervalSec := 60;
  GcEveryNCommits := 25;
  RepoVisibility := 'private';
  IgnoreGlobs.Clear;
  IgnoreGlobs.Add('.git');
  IgnoreGlobs.Add('*.tmp');
  IgnoreGlobs.Add('*~');
  SetLength(Repos, 0);
end;

function TGotConfig.FindRepo(const ALocalName: string; out AEntry: TRepoEntry): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Repos) do
    if SameText(Repos[i].LocalName, ALocalName) then
    begin
      AEntry := Repos[i];
      Exit(True);
    end;
end;

procedure TGotConfig.UpsertRepo(const AEntry: TRepoEntry);
var
  i: Integer;
begin
  for i := 0 to High(Repos) do
    if SameText(Repos[i].LocalName, AEntry.LocalName) then
    begin
      Repos[i] := AEntry;
      Exit;
    end;
  SetLength(Repos, Length(Repos) + 1);
  Repos[High(Repos)] := AEntry;
end;

{ ---- TConfigStore ---- }

constructor TConfigStore.Create(const APath: string);
begin
  inherited Create;
  FPath := APath;
end;

function TConfigStore.Load: TGotConfig;
var
  txt: TStringList;
  root, jrepos, jrepo: TJSONData;
  obj, repoObj: TJSONObject;
  arr: TJSONArray;
  i: Integer;
  e: TRepoEntry;
begin
  Result := TGotConfig.Create;
  if not FileExists(FPath) then
    Exit;
  txt := TStringList.Create;
  try
    txt.LoadFromFile(FPath);
    root := GetJSON(txt.Text);
    try
      if not (root is TJSONObject) then Exit;
      obj := TJSONObject(root);
      Result.RootDir := obj.Get('rootDir', Result.RootDir);
      Result.GithubUser := obj.Get('githubUser', Result.GithubUser);
      Result.MachineName := obj.Get('machineName', Result.MachineName);
      Result.HistoryCap := obj.Get('historyCap', Result.HistoryCap);
      Result.CommitDebounceMs := obj.Get('commitDebounceMs', Result.CommitDebounceMs);
      Result.PullIntervalSec := obj.Get('pullIntervalSec', Result.PullIntervalSec);
      Result.GcEveryNCommits := obj.Get('gcEveryNCommits', Result.GcEveryNCommits);
      Result.RepoVisibility := obj.Get('repoVisibility', Result.RepoVisibility);

      jrepos := obj.Find('ignoreGlobs');
      if jrepos is TJSONArray then
      begin
        Result.IgnoreGlobs.Clear;
        arr := TJSONArray(jrepos);
        for i := 0 to arr.Count - 1 do
          Result.IgnoreGlobs.Add(arr.Strings[i]);
      end;

      jrepos := obj.Find('repos');
      if jrepos is TJSONArray then
      begin
        arr := TJSONArray(jrepos);
        for i := 0 to arr.Count - 1 do
        begin
          jrepo := arr.Items[i];
          if jrepo is TJSONObject then
          begin
            repoObj := TJSONObject(jrepo);
            e.LocalName := repoObj.Get('localName', '');
            e.RemoteUrl := repoObj.Get('remoteUrl', '');
            e.Paused := repoObj.Get('paused', False);
            if e.LocalName <> '' then
              Result.UpsertRepo(e);
          end;
        end;
      end;
    finally
      root.Free;
    end;
  finally
    txt.Free;
  end;
end;

procedure TConfigStore.Save(ACfg: TGotConfig);
var
  obj, repoObj: TJSONObject;
  globs, repos: TJSONArray;
  i: Integer;
  txt: TStringList;
begin
  obj := TJSONObject.Create;
  try
    obj.Add('rootDir', ACfg.RootDir);
    obj.Add('githubUser', ACfg.GithubUser);
    obj.Add('machineName', ACfg.MachineName);
    obj.Add('historyCap', ACfg.HistoryCap);
    obj.Add('commitDebounceMs', ACfg.CommitDebounceMs);
    obj.Add('pullIntervalSec', ACfg.PullIntervalSec);
    obj.Add('gcEveryNCommits', ACfg.GcEveryNCommits);
    obj.Add('repoVisibility', ACfg.RepoVisibility);

    globs := TJSONArray.Create;
    for i := 0 to ACfg.IgnoreGlobs.Count - 1 do
      globs.Add(ACfg.IgnoreGlobs[i]);
    obj.Add('ignoreGlobs', globs);

    repos := TJSONArray.Create;
    for i := 0 to High(ACfg.Repos) do
    begin
      repoObj := TJSONObject.Create;
      repoObj.Add('localName', ACfg.Repos[i].LocalName);
      repoObj.Add('remoteUrl', ACfg.Repos[i].RemoteUrl);
      repoObj.Add('paused', ACfg.Repos[i].Paused);
      repos.Add(repoObj);
    end;
    obj.Add('repos', repos);

    ForceDirectories(ExtractFileDir(FPath));
    txt := TStringList.Create;
    try
      txt.Text := obj.FormatJSON;
      txt.SaveToFile(FPath);
    finally
      txt.Free;
    end;
  finally
    obj.Free;
  end;
end;

end.
