{
  GotBox -- Dropbox-like file sync over your own private git repositories.
  Copyright (C) 2026 Qianqian Fang <q.fang@northeastern.edu> and contributors.

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

program testrootlock;

{ Unit test for the cooperative root lock: acquire when free, refuse when held
  by another live owner, take over on request, self-detect a takeover, reclaim a
  stale lock, and release. No git/network -- just a fake .git directory. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, gboxrootlock;

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

  { Rewrite the on-disk heartbeat to a long-ago value so the lock reads stale. }
  procedure AgeLock(const ARoot: string);
  var
    sl: TStringList;
  begin
    sl := TStringList.Create;
    try
      sl.LoadFromFile(RootLockPath(ARoot));
      sl.Values['heartbeat'] := '1';   // 1970 -> definitely older than STALE_SEC
      sl.SaveToFile(RootLockPath(ARoot));
    finally
      sl.Free;
    end;
  end;

var
  base, root, tokA, tokB: string;
  owner: TLockOwner;
  res: TAcquireResult;
begin
  Randomize;
  base := IncludeTrailingPathDelimiter(GetTempDir) + 'gotbox-lock-' +
    FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToStr(Random(99999));
  root := IncludeTrailingPathDelimiter(base) + 'root';
  ForceDirectories(root + PathDelim + '.git');   // fake a set-up root
  WriteLn('workspace: ', base);

  tokA := NewLockToken;
  tokB := NewLockToken;
  Check(tokA <> tokB, 'tokens are unique per acquisition');

  // free root -> A acquires
  res := AcquireRootLock(root, 'machineA', tokA, False, owner);
  Check(res = arAcquired, 'A acquires a free root');
  Check(StillRootOwner(root, tokA), 'A is the owner');

  // B tries without takeover -> refused, A still owns
  res := AcquireRootLock(root, 'machineB', tokB, False, owner);
  Check(res = arHeldByOther, 'B is refused while A holds a fresh lock');
  Check((owner.Token = tokA) and (owner.Machine = 'machineA'),
    'refusal reports the current owner (A)');
  Check(StillRootOwner(root, tokA), 'A still owns after B is refused');
  Check(not StillRootOwner(root, tokB), 'B does not own after refusal');

  // B takes over -> B owns, A detects it lost ownership
  res := AcquireRootLock(root, 'machineB', tokB, True, owner);
  Check(res = arAcquired, 'B takes over with takeover=true');
  Check(StillRootOwner(root, tokB), 'B is now the owner');
  Check(not StillRootOwner(root, tokA),
    'A detects the takeover (no longer owner) -> would self-pause');

  // stale lock is reclaimable without takeover
  AgeLock(root);
  owner := ReadRootOwner(root);
  Check(OwnerIsStale(owner), 'an old lock reads as stale');
  res := AcquireRootLock(root, 'machineA', tokA, False, owner);
  Check(res = arAcquired, 'a stale lock is reclaimed without takeover');
  Check(StillRootOwner(root, tokA), 'A reclaimed the stale lock');

  // refresh keeps ownership; release clears it
  Check(RefreshRootLock(root, 'machineA', tokA), 'refresh succeeds');
  Check(StillRootOwner(root, tokA), 'still owner after refresh');
  ReleaseRootLock(root, tokA);
  owner := ReadRootOwner(root);
  Check(not owner.Valid, 'release removes the lock');

  // no .git -> no coordination (never blocks)
  res := AcquireRootLock(base, 'machineA', tokA, False, owner);
  Check(res = arNoRoot, 'a root with no .git reports arNoRoot');

  if failures = 0 then
  begin
    DeleteFile(RootLockPath(root));
    RemoveDir(root + PathDelim + '.git');
    RemoveDir(root);
    RemoveDir(ExcludeTrailingPathDelimiter(base));
  end;

  WriteLn;
  if failures = 0 then WriteLn('ALL TESTS PASSED')
  else
    WriteLn(failures, ' TEST(S) FAILED');
  Halt(failures);
end.
