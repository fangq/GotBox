{
  GotBox -- Dropbox-like file sync over your own private git repositories.
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

unit gboxhistory;

{ Rolling history cap. To keep repos lean, everything older than the most recent
  ACap commits is collapsed into a single snapshot commit, the recent commits are
  rebased onto it, the rewritten history is force-pushed, and `git gc` reclaims
  space. Because this rewrites history, other machines pick up the change via the
  rewrite-safe reset path in gboxsync.

  ShouldTrim applies hysteresis (only trim once history grows well past the cap)
  so force-pushes happen in batches rather than on every commit. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, gboxgitrunner;

type
  { One annotated tag, for the Status window's tag list. }
  TTagInfo = record
    Label_: string;    // tag name
    Date: string;      // creation date (yyyy-mm-dd)
    ShortSha: string;  // short object name
    Subject: string;   // first line of the tag message
  end;
  TTagInfoArray = array of TTagInfo;

{ True if the repo has any user tag. }
function HasUserTags(AGit: TGitRunner): Boolean;

{ Annotated tags, newest first. }
function ListTags(AGit: TGitRunner): TTagInfoArray;

{ Create an annotated tag ALabel (with AMessage) at HEAD and push it. Returns
  False with ADetail on invalid/duplicate label or push failure. }
function AddTag(AGit: TGitRunner; const ALabel, AMessage: string;
  out ADetail: string): Boolean;

{ Collapse the auto-commits between consecutive tags so only the tagged commits
  (each an exact snapshot, tag label+message preserved) remain, plus the commits
  after the newest tag; then force-push the branch and moved tags. Rewrites
  history -- other machines pick it up via gboxsync's rewrite-safe reset. }
function SquashBetweenTags(AGit: TGitRunner; out ADetail: string): Boolean;

{ True if the repo has grown enough past ACap to be worth trimming. }
function ShouldTrim(AGit: TGitRunner; ACap: Integer): Boolean;

{ Squashes history to the most recent ACap commits (+1 snapshot) and force-pushes.
  Returns True if a trim happened; ADetail explains failures. The working tree
  must be clean and on the branch being trimmed. }
function TrimHistory(AGit: TGitRunner; ACap: Integer; out ADetail: string): Boolean;

implementation

uses
  gboxlog;

function HasUserTags(AGit: TGitRunner): Boolean;
begin
  Result := Trim(AGit.GitQuiet(['tag', '-l']).StdOut) <> '';
end;

function ShouldTrim(AGit: TGitRunner; ACap: Integer): Boolean;
var
  n: Integer;
begin
  Result := False;
  if ACap <= 0 then Exit;
  // Once the user keeps tags, never auto-rewrite history: the blind trim would
  // delete tagged milestones. Space is then managed on demand via SquashBetweenTags.
  if HasUserTags(AGit) then Exit;
  n := AGit.CountCommits;
  // hysteresis: let it grow to ~2x the cap before squashing back down
  Result := (n > 0) and (n > 2 * ACap);
end;

function TrimHistory(AGit: TGitRunner; ACap: Integer; out ADetail: string): Boolean;
var
  n: Integer;
  base, tree, snap, ts: string;
  r: TGitResult;
begin
  Result := False;
  ADetail := '';
  if ACap <= 0 then Exit;

  n := AGit.CountCommits;
  if n <= ACap then Exit;   // already within the cap

  // Safety: never squash + force-push while the remote has commits we have not
  // merged yet. --force-with-lease only guards against the remote moving since
  // our last fetch; it does NOT stop us from force-pushing a squash of a HEAD
  // that is behind a fetched-but-unmerged origin/main -- which would overwrite
  // those commits (e.g. resurrect a file another machine deleted). Defer: the
  // next cycle merges origin/main first, then trims the up-to-date history.
  if AGit.GitQuiet(['rev-parse', '--verify', 'origin/main']).Ok then
    if AGit.CountRange('HEAD..origin/main') > 0 then
    begin
      ADetail := 'remote has unmerged commits; deferring trim';
      Exit;
    end;

  // boundary commit: the one just before the window of the last ACap commits
  base := Trim(AGit.RevParse('HEAD~' + IntToStr(ACap)).StdOut);
  if base = '' then
  begin
    ADetail := 'could not resolve history boundary';
    Exit;
  end;

  tree := Trim(AGit.Git(['rev-parse', base + '^{tree}']).StdOut);
  if tree = '' then
  begin
    ADetail := 'could not resolve boundary tree';
    Exit;
  end;

  // a parentless snapshot commit holding the boundary tree
  ts := FormatDateTime('yyyy-mm-dd', Now);
  snap := Trim(AGit.Git(['commit-tree', tree, '-m', 'GotBox history snapshot ' +
    ts]).StdOut);
  if snap = '' then
  begin
    ADetail := 'snapshot (commit-tree) failed';
    Exit;
  end;

  // replay the most recent ACap commits onto the snapshot
  r := AGit.Git(['rebase', '--onto', snap, base]);
  if not r.Ok then
  begin
    AGit.Git(['rebase', '--abort']);
    ADetail := 'rebase failed: ' + Trim(r.StdErr);
    Exit;
  end;

  // publish the rewritten history
  r := AGit.Push(True);   // --force-with-lease
  if not r.Ok then
  begin
    ADetail := 'force-push failed: ' + Trim(r.StdErr);
    Exit;   // local history is trimmed; remote will catch up next cycle
  end;

  AGit.Gc;
  if Assigned(Log) then
    Log.Info('history', Format('trimmed to last %d commits (+snapshot)', [ACap]));
  Result := True;
end;

{ Give commit-tree/rebase/tag a committer identity when the repo has none (e.g.
  a managed submodule the user never configured). Only sets a fallback if empty,
  so a configured identity is left untouched. }
procedure EnsureIdentity(AGit: TGitRunner);
begin
  if Trim(AGit.GitQuiet(['config', 'user.name']).StdOut) = '' then
    AGit.Git(['config', 'user.name', 'GotBox']);
  if Trim(AGit.GitQuiet(['config', 'user.email']).StdOut) = '' then
    AGit.Git(['config', 'user.email', 'gotbox@gotbox.local']);
end;

function ListTags(AGit: TGitRunner): TTagInfoArray;
var
  r: TGitResult;
  sl: TStringList;
  i: Integer;
  line, rest: string;
  ti: TTagInfo;

  function NextField: string;   // consume up to the next TAB in `rest`
  var
    t: Integer;
  begin
    t := Pos(#9, rest);
    if t > 0 then
    begin
      Result := Copy(rest, 1, t - 1);
      rest := Copy(rest, t + 1, MaxInt);
    end
    else
    begin
      Result := rest;
      rest := '';
    end;
  end;

begin
  SetLength(Result, 0);
  // %09 (git expands it to a TAB in the OUTPUT) -- NOT a literal #9 in the arg:
  // FPC's TProcess doesn't quote a tab, so a literal tab would be split into
  // separate args by the Windows command-line parser and break the format.
  r := AGit.GitQuiet(['tag', '-l', '--sort=-creatordate',
    '--format=%(refname:short)%09%(creatordate:short)%09' +
    '%(objectname:short)%09%(contents:subject)']);
  if not r.Ok then Exit;
  sl := TStringList.Create;
  try
    sl.Text := r.StdOut;
    for i := 0 to sl.Count - 1 do
    begin
      line := sl[i];
      if Trim(line) = '' then Continue;
      rest := line;
      ti.Label_ := NextField;
      ti.Date := NextField;
      ti.ShortSha := NextField;
      ti.Subject := rest;   // remainder (may be empty / contain no tabs)
      if ti.Label_ = '' then Continue;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := ti;
    end;
  finally
    sl.Free;
  end;
end;

function AddTag(AGit: TGitRunner; const ALabel, AMessage: string;
  out ADetail: string): Boolean;
var
  r: TGitResult;
begin
  Result := False;
  ADetail := '';
  if Trim(ALabel) = '' then
  begin
    ADetail := 'tag label is empty';
    Exit;
  end;
  if not AGit.GitQuiet(['check-ref-format', 'refs/tags/' + ALabel]).Ok then
  begin
    ADetail := 'invalid tag name: ' + ALabel;
    Exit;
  end;
  if AGit.GitQuiet(['rev-parse', '--verify', '--quiet',
    'refs/tags/' + ALabel]).Ok then
  begin
    ADetail := 'a tag named "' + ALabel + '" already exists';
    Exit;
  end;
  EnsureIdentity(AGit);
  r := AGit.Git(['tag', '-a', ALabel, '-m', AMessage]);   // annotated, at HEAD
  if not r.Ok then
  begin
    ADetail := 'creating the tag failed: ' + Trim(r.StdErr);
    Exit;
  end;
  r := AGit.Git(['push', 'origin', 'refs/tags/' + ALabel]);
  if not r.Ok then
  begin
    ADetail := 'tag created locally but push failed: ' + Trim(r.StdErr);
    Exit;
  end;
  Result := True;
end;

function SquashBetweenTags(AGit: TGitRunner; out ADetail: string): Boolean;
var
  r: TGitResult;
  labels, raw: TStringList;
  i, d: Integer;
  tree, msg, ci, prev, tkOrig: string;
begin
  Result := False;
  ADetail := '';
  // never rewrite while behind unmerged remote commits (would clobber them)
  if AGit.GitQuiet(['rev-parse', '--verify', 'origin/main']).Ok then
    if AGit.CountRange('HEAD..origin/main') > 0 then
    begin
      ADetail := 'remote has unmerged commits; sync first, then squash';
      Exit;
    end;

  labels := TStringList.Create;
  try
    // tags reachable from HEAD, ordered oldest->newest by ancestry (ancestor
    // count). Robust for GotBox's linear history even when rapid auto-commits
    // share a timestamp, where sorting by date would be ambiguous.
    raw := TStringList.Create;
    try
      raw.Text := AGit.GitQuiet(['tag', '--merged', 'HEAD']).StdOut;
      for i := 0 to raw.Count - 1 do
        if Trim(raw[i]) <> '' then
        begin
          d := StrToIntDef(Trim(AGit.GitQuiet(['rev-list', '--count',
            raw[i] + '^{commit}']).StdOut), 0);
          labels.Add(Format('%.10d'#9'%s', [d, Trim(raw[i])]));   // depth<TAB>label
        end;
    finally
      raw.Free;
    end;
    if labels.Count = 0 then
    begin
      ADetail := 'no tags to squash between';
      Exit;
    end;
    labels.Sort;   // ascending ancestor count = oldest tag first
    for i := 0 to labels.Count - 1 do
      labels[i] := Copy(labels[i], Pos(#9, labels[i]) + 1, MaxInt);   // strip depth

    EnsureIdentity(AGit);
    tkOrig := Trim(AGit.RevParse(labels[labels.Count - 1] + '^{commit}').StdOut);
    if tkOrig = '' then
    begin
      ADetail := 'could not resolve the newest tag';
      Exit;
    end;

    // rebuild oldest->newest: one commit per tag holding that tag's exact tree
    prev := '';
    for i := 0 to labels.Count - 1 do
    begin
      tree := Trim(AGit.Git(['rev-parse', labels[i] + '^{tree}']).StdOut);
      if tree = '' then
      begin
        ADetail := 'could not resolve tree for tag ' + labels[i];
        Exit;
      end;
      msg := AGit.GitQuiet(['tag', '-l', labels[i], '--format=%(contents)']).StdOut;
      while (msg <> '') and (msg[Length(msg)] in [#10, #13]) do
        SetLength(msg, Length(msg) - 1);
      if msg = '' then msg := 'checkpoint ' + labels[i];
      if prev = '' then
        ci := Trim(AGit.Git(['commit-tree', tree, '-m',
          'GotBox checkpoint: ' + labels[i]]).StdOut)
      else
        ci := Trim(AGit.Git(['commit-tree', tree, '-p', prev, '-m',
          'GotBox checkpoint: ' + labels[i]]).StdOut);
      if ci = '' then
      begin
        ADetail := 'commit-tree failed at tag ' + labels[i];
        Exit;
      end;
      // move the annotated tag onto the new commit, keeping its message
      AGit.Git(['tag', '-f', '-a', labels[i], '-m', msg, ci]);
      prev := ci;
    end;

    // replay the commits after the newest tag onto the squashed chain
    r := AGit.Git(['rebase', '--onto', prev, tkOrig]);
    if not r.Ok then
    begin
      AGit.Git(['rebase', '--abort']);
      ADetail := 'rebase failed: ' + Trim(r.StdErr);
      Exit;
    end;

    r := AGit.Push(True);   // force-with-lease the rewritten branch
    if not r.Ok then
    begin
      ADetail := 'force-push failed: ' + Trim(r.StdErr);
      Exit;
    end;
    AGit.Git(['push', '--force', 'origin', '--tags']);   // publish moved tags
    AGit.Gc;
    if Assigned(Log) then
      Log.Info('history', Format('squashed between %d tag(s)', [labels.Count]));
    Result := True;
  finally
    labels.Free;
  end;
end;

end.
