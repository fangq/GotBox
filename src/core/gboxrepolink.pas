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

unit gboxrepolink;

{ Maps the local root directory onto remote repos via a TRemoteProvider (GitHub
  or a self-maintained git server). For each immediate subfolder of RootDir it
  ensures the remote repo exists (creating it when possible), wires up the local
  git repo + remote, and records the mapping in the config. Brand-new repos get
  an initial commit + push; folders whose remote already has history are just
  linked, leaving reconciliation to the sync engine.

  EnsureLocalRepo (the git-side wiring) takes an explicit remote URL so it can be
  unit-tested against a local bare repo with no network or token. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxconfigstore, gboxgitrunner, gboxstatusmodel, gboxremote;

type
  TLinkAction = (laCreated, laLinked, laError);

  TLinkResult = record
    LocalName: string;
    Action: TLinkAction;
    Detail: string;
  end;
  TLinkResultArray = array of TLinkResult;

  TRepoLinker = class
  private
    FCfg: TGotConfig;
    FStatus: TStatusModel;
    FProvider: TRemoteProvider;
  public
    constructor Create(ACfg: TGotConfig; const AToken: string;
      AStatus: TStatusModel = nil);
    destructor Destroy; override;

    { Git-side wiring only (no remote-provider calls). Ensures ALocalPath is a
      git repo with origin = ARemoteUrl, makes an initial commit if there is
      content and no commit yet, and (when ACreatedRemote) pushes it. Returns
      False + ADetail on the first failing git step. }
    function EnsureLocalRepo(const ALocalPath, ARemoteUrl: string;
      ACreatedRemote: Boolean; out ADetail: string): Boolean;

    { Create/link a single subfolder (talks to the remote provider). }
    function LinkFolder(const AName: string; out ARes: TLinkResult): Boolean;

    { Scan immediate subfolders of RootDir and link/create each. }
    function ScanAndLink: TLinkResultArray;
  end;

implementation

uses
  gboxlog;

constructor TRepoLinker.Create(ACfg: TGotConfig; const AToken: string;
  AStatus: TStatusModel);
begin
  inherited Create;
  FCfg := ACfg;
  FStatus := AStatus;
  FProvider := MakeProvider(ACfg, AToken);
end;

destructor TRepoLinker.Destroy;
begin
  FProvider.Free;
  inherited Destroy;
end;

function TRepoLinker.EnsureLocalRepo(const ALocalPath, ARemoteUrl: string;
  ACreatedRemote: Boolean; out ADetail: string): Boolean;
var
  git: TGitRunner;
  r: TGitResult;
  isRepo: Boolean;
  committer: string;
begin
  Result := False;
  ADetail := '';
  ForceDirectories(ALocalPath);   // git init needs the working dir to exist
  git := TGitRunner.Create(ALocalPath);
  try
    git.AuthUser := FProvider.AuthUser;
    git.AuthToken := FProvider.AuthToken;

    isRepo := DirectoryExists(IncludeTrailingPathDelimiter(ALocalPath) + '.git');
    if not isRepo then
    begin
      r := git.InitRepo;
      if not r.Ok then
      begin
        ADetail := 'git init failed: ' + Trim(r.StdErr);
        Exit;
      end;
    end;

    r := git.SetRemote('origin', ARemoteUrl);
    if not r.Ok then
    begin
      ADetail := 'set remote failed: ' + Trim(r.StdErr);
      Exit;
    end;

    // committer identity so commits succeed without a global git config
    committer := FProvider.AuthUser;
    if committer = '' then committer := FCfg.MachineName;
    if committer = '' then committer := 'gotbox';
    git.Git(['config', 'user.name', committer]);
    git.Git(['config', 'user.email', committer + '@gotbox.local']);
    // record renames/moves rather than delete+add (content is already deduped
    // by blob hash, but this keeps history clean)
    git.Git(['config', 'diff.renames', 'copies']);

    // give a brand-new repo an initial commit so `main` exists -- use
    // --allow-empty so even an empty folder gets a valid branch to push
    if git.CountCommits <= 0 then
    begin
      git.AddAll;
      r := git.Git(['commit', '--allow-empty', '-m', 'initial commit']);
      if not r.Ok then
      begin
        ADetail := 'initial commit failed: ' + Trim(r.StdErr);
        Exit;
      end;
    end;

    if ACreatedRemote and (git.CountCommits > 0) then
    begin
      r := git.Push(False);
      if not r.Ok then
      begin
        ADetail := 'initial push failed: ' + Trim(r.StdErr);
        Exit;
      end;
    end;

    Result := True;
  finally
    git.Free;
  end;
end;

function TRepoLinker.LinkFolder(const AName: string; out ARes: TLinkResult): Boolean;
var
  localPath, detail: string;
  ensure: TEnsureRemote;
  entry: TRepoEntry;
begin
  ARes.LocalName := AName;
  ARes.Action := laError;
  ARes.Detail := '';
  Result := False;

  localPath := IncludeTrailingPathDelimiter(FCfg.RootDir) + AName;
  if Assigned(FStatus) then FStatus.SetState(AName, rsSyncing, 'linking');

  ensure := FProvider.EnsureRemote(AName, detail);
  if ensure = erError then
  begin
    ARes.Detail := detail;
    if Assigned(FStatus) then FStatus.SetState(AName, rsError, detail);
    Exit;
  end;

  if not EnsureLocalRepo(localPath, FProvider.PushUrl(AName), ensure =
    erCreated, ARes.Detail) then
  begin
    if Assigned(FStatus) then FStatus.SetState(AName, rsError, ARes.Detail);
    Exit;
  end;

  entry.LocalName := AName;
  entry.RemoteUrl := FProvider.DisplayUrl(AName);
  entry.Paused := False;
  FCfg.UpsertRepo(entry);

  if ensure = erCreated then ARes.Action := laCreated
  else
    ARes.Action := laLinked;
  ARes.Detail := entry.RemoteUrl;
  if Assigned(FStatus) then FStatus.SetState(AName, rsSynced, ARes.Detail);
  if Assigned(Log) then
    Log.Info('link', Format('%s -> %s (%s)', [AName, entry.RemoteUrl,
      BoolToStr(ensure = erCreated, 'created', 'linked')]));
  Result := True;
end;

function TRepoLinker.ScanAndLink: TLinkResultArray;
var
  sr: TSearchRec;
  names: TStringList;
  i: Integer;
  res: TLinkResult;
begin
  SetLength(Result, 0);
  if (FCfg.RootDir = '') or not DirectoryExists(FCfg.RootDir) then Exit;

  names := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(FCfg.RootDir) + AllFilesMask,
      faDirectory, sr) = 0 then
    begin
      repeat
        if (sr.Attr and faDirectory) <> 0 then
          if (sr.Name <> '.') and (sr.Name <> '..') and (sr.Name[1] <> '.') then
            names.Add(sr.Name);
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    names.Sort;

    for i := 0 to names.Count - 1 do
    begin
      LinkFolder(names[i], res);
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := res;
    end;
  finally
    names.Free;
  end;
end;

end.
