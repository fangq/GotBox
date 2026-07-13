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

unit gboxoverlayhandler;

{ Windows shell icon-overlay COM handlers (TortoiseGit-style), hosted by the
  GotBoxOverlay.dll that explorer.exe loads in-process. Three classes -- one per
  status (synced / modified / conflict), each with its own CLSID and badge icon.
  IsMemberOf just asks the running GotBox process (via gboxoverlayipc.OverlayQuery)
  for the path's state and returns S_OK when it matches this class's state. The
  query is timeout-bounded and fully guarded, so a missing or slow service can
  never hang or crash Explorer -- it simply yields no overlay.

  COM interfaces + IUnknown are declared and implemented by hand (no ComObj /
  type library) to keep the DLL tiny and independent of RTL version drift. Only
  builds on Windows. }

{$mode objfpc}{$H+}

interface

uses
  Windows;

{ The four standard in-proc COM server entry points, wrapped by gboxshellext.lpr's
  exports. All are self-contained (no COM library init needed). }
function HandlerGetClassObject(constref rclsid, riid: TGUID; out ppv): HRESULT;
function HandlerCanUnloadNow: HRESULT;
function RegisterOverlays: HRESULT;     // writes HKLM/HKCR (needs elevation)
function UnregisterOverlays: HRESULT;

implementation

uses
  SysUtils, gboxfilestatus, gboxoverlayipc;

const
  S_OK = HRESULT(0);
  S_FALSE = HRESULT(1);
  E_NOINTERFACE = HRESULT($80004002);
  E_FAIL = HRESULT($80004005);
  CLASS_E_CLASSNOTAVAILABLE = HRESULT($80040111);

  ISIOI_ICONFILE = $00000001;
  ISIOI_ICONINDEX = $00000002;

  GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = $00000002;
  GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = $00000004;

  // registry: overlay identifiers live under HKLM; the class under HKCR
  SHELLOVERLAY_KEY =
    'Software\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers';

  IID_IUnknown: TGUID = '{00000000-0000-0000-C000-000000000046}';
  IID_IClassFactory: TGUID = '{00000001-0000-0000-C000-000000000046}';
  IID_IShellIconOverlayIdentifier: TGUID =
    '{0C6C4200-C589-11D0-999A-00C04FD655E1}';

  // GotBox's own class ids (generated once; stable forever)
  CLSID_Synced: TGUID = '{EA0FC31D-0317-4B05-9F34-860E80856270}';
  CLSID_Modified: TGUID = '{4B579425-7486-4343-8EAA-2AB307C38FCB}';
  CLSID_Conflict: TGUID = '{224887E8-2FF5-4CE4-97FD-78E97B754800}';

type
  IShellIconOverlayIdentifier = interface(IUnknown)
    ['{0C6C4200-C589-11D0-999A-00C04FD655E1}']
    function GetOverlayInfo(pwszIconFile: PWideChar; cchMax: Integer;
      out pIndex: Integer; out pdwFlags: DWORD): HRESULT; stdcall;
    function GetPriority(out pIPriority: Integer): HRESULT; stdcall;
    function IsMemberOf(pwszPath: PWideChar; dwAttrib: DWORD): HRESULT; stdcall;
  end;

  { A private clone of IClassFactory (same GUID + vtable layout); named to avoid
    clashing with any RTL declaration. }
  IGboxClassFactory = interface(IUnknown)
    ['{00000001-0000-0000-C000-000000000046}']
    function CreateInstance(const unkOuter: IUnknown; constref iid: TGUID;
      out obj): HRESULT; stdcall;
    function LockServer(fLock: LongBool): HRESULT; stdcall;
  end;

  { One overlay handler instance, bound to the state it badges. }
  TOverlayHandler = class(TObject, IUnknown, IShellIconOverlayIdentifier)
  private
    FRef: LongInt;
    FState: TFileState;
    FIconIndex: Integer;
  public
    constructor Create(AState: TFileState; AIconIndex: Integer);
    destructor Destroy; override;
    function QueryInterface(constref iid: TGUID; out obj): LongInt; stdcall;
    function _AddRef: LongInt; stdcall;
    function _Release: LongInt; stdcall;
    function GetOverlayInfo(pwszIconFile: PWideChar; cchMax: Integer;
      out pIndex: Integer; out pdwFlags: DWORD): HRESULT; stdcall;
    function GetPriority(out pIPriority: Integer): HRESULT; stdcall;
    function IsMemberOf(pwszPath: PWideChar; dwAttrib: DWORD): HRESULT; stdcall;
  end;

  TOverlayFactory = class(TObject, IUnknown, IGboxClassFactory)
  private
    FRef: LongInt;
    FState: TFileState;
    FIconIndex: Integer;
  public
    constructor Create(AState: TFileState; AIconIndex: Integer);
    function QueryInterface(constref iid: TGUID; out obj): LongInt; stdcall;
    function _AddRef: LongInt; stdcall;
    function _Release: LongInt; stdcall;
    function CreateInstance(const unkOuter: IUnknown; constref iid: TGUID;
      out obj): HRESULT; stdcall;
    function LockServer(fLock: LongBool): HRESULT; stdcall;
  end;

function GetModuleHandleExW(dwFlags: DWORD; lpModuleName: PWideChar;
  var phModule: HMODULE): BOOL; stdcall; external 'kernel32'
  name 'GetModuleHandleExW';

var
  gObjCount: LongInt = 0;
  gLockCount: LongInt = 0;
  gSelfModule: HMODULE = 0;

function SameGuid(constref a, b: TGUID): Boolean;
begin
  Result := (a.D1 = b.D1) and (a.D2 = b.D2) and (a.D3 = b.D3) and
    (CompareByte(a.D4, b.D4, 8) = 0);
end;

{ This DLL's own file path (for InprocServer32 and the overlay icon source). }
function GetSelfPathW: WideString;
var
  buf: array[0..1023] of WideChar;
  n: DWORD;
begin
  if gSelfModule = 0 then
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS or
      GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
      PWideChar(@GetSelfPathW), gSelfModule);
  n := GetModuleFileNameW(gSelfModule, @buf[0], Length(buf));
  SetString(Result, PWideChar(@buf[0]), n);
end;

{ ---- TOverlayHandler ---- }

constructor TOverlayHandler.Create(AState: TFileState; AIconIndex: Integer);
begin
  inherited Create;
  FState := AState;
  FIconIndex := AIconIndex;
  InterlockedIncrement(gObjCount);
end;

destructor TOverlayHandler.Destroy;
begin
  InterlockedDecrement(gObjCount);
  inherited Destroy;
end;

function TOverlayHandler.QueryInterface(constref iid: TGUID; out obj): LongInt;
  stdcall;
begin
  if SameGuid(iid, IID_IUnknown) or SameGuid(iid,
    IID_IShellIconOverlayIdentifier) then
  begin
    if GetInterface(iid, obj) then Exit(S_OK);
  end;
  Pointer(obj) := nil;
  Result := E_NOINTERFACE;
end;

function TOverlayHandler._AddRef: LongInt; stdcall;
begin
  Result := InterlockedIncrement(FRef);
end;

function TOverlayHandler._Release: LongInt; stdcall;
begin
  Result := InterlockedDecrement(FRef);
  if Result = 0 then Destroy;
end;

function TOverlayHandler.GetOverlayInfo(pwszIconFile: PWideChar;
  cchMax: Integer; out pIndex: Integer; out pdwFlags: DWORD): HRESULT; stdcall;
var
  w: WideString;
begin
  w := GetSelfPathW;
  if (pwszIconFile <> nil) and (cchMax > 0) then
    lstrcpynW(pwszIconFile, PWideChar(w), cchMax);
  pIndex := FIconIndex;
  pdwFlags := ISIOI_ICONFILE or ISIOI_ICONINDEX;
  Result := S_OK;
end;

function TOverlayHandler.GetPriority(out pIPriority: Integer): HRESULT; stdcall;
begin
  pIPriority := 0;    // 0 = highest
  Result := S_OK;
end;

function TOverlayHandler.IsMemberOf(pwszPath: PWideChar;
  dwAttrib: DWORD): HRESULT; stdcall;
var
  path: string;
begin
  Result := S_FALSE;
  try
    if pwszPath = nil then Exit;
    // ASCII-correct; non-ASCII paths use the ANSI codepage (rare, best effort)
    path := string(WideString(pwszPath));
    if OverlayQuery(path, '', 400) = FState then Result := S_OK;
  except
    Result := S_FALSE;   // never let an exception escape into Explorer
  end;
end;

{ ---- TOverlayFactory ---- }

constructor TOverlayFactory.Create(AState: TFileState; AIconIndex: Integer);
begin
  inherited Create;
  FState := AState;
  FIconIndex := AIconIndex;
end;

function TOverlayFactory.QueryInterface(constref iid: TGUID; out obj): LongInt;
  stdcall;
begin
  if SameGuid(iid, IID_IUnknown) or SameGuid(iid, IID_IClassFactory) then
  begin
    if GetInterface(iid, obj) then Exit(S_OK);
  end;
  Pointer(obj) := nil;
  Result := E_NOINTERFACE;
end;

function TOverlayFactory._AddRef: LongInt; stdcall;
begin
  Result := InterlockedIncrement(FRef);
end;

function TOverlayFactory._Release: LongInt; stdcall;
begin
  Result := InterlockedDecrement(FRef);
  if Result = 0 then Destroy;
end;

function TOverlayFactory.CreateInstance(const unkOuter: IUnknown;
  constref iid: TGUID; out obj): HRESULT; stdcall;
var
  h: TOverlayHandler;
begin
  Pointer(obj) := nil;
  if unkOuter <> nil then Exit(HRESULT($80040110));   // CLASS_E_NOAGGREGATION
  h := TOverlayHandler.Create(FState, FIconIndex);
  h._AddRef;                       // creation reference
  Result := h.QueryInterface(iid, obj);
  h._Release;                      // frees h if QueryInterface did not keep it
end;

function TOverlayFactory.LockServer(fLock: LongBool): HRESULT; stdcall;
begin
  if fLock then InterlockedIncrement(gLockCount)
  else
    InterlockedDecrement(gLockCount);
  Result := S_OK;
end;

{ ---- server entry points ---- }

function HandlerGetClassObject(constref rclsid, riid: TGUID; out ppv): HRESULT;
var
  st: TFileState;
  idx: Integer;
  f: TOverlayFactory;
begin
  Pointer(ppv) := nil;
  if SameGuid(rclsid, CLSID_Synced) then begin
    st := fsSynced;
    idx := 0;
  end
  else if SameGuid(rclsid, CLSID_Modified) then
  begin
    st := fsModified;
    idx := 1;
  end
  else if SameGuid(rclsid, CLSID_Conflict) then
  begin
    st := fsConflict;
    idx := 2;
  end
  else
    Exit(CLASS_E_CLASSNOTAVAILABLE);
  f := TOverlayFactory.Create(st, idx);
  f._AddRef;
  Result := f.QueryInterface(riid, ppv);
  f._Release;
end;

function HandlerCanUnloadNow: HRESULT;
begin
  if (gObjCount = 0) and (gLockCount = 0) then Result := S_OK
  else
    Result := S_FALSE;
end;

{ ---- (un)registration (HKLM/HKCR; requires elevation) ---- }

function RegSetSz(root: HKEY; const subkey, valname, data: string): Boolean;
var
  k: HKEY;
  disp: DWORD;
begin
  Result := False;
  if RegCreateKeyExA(root, PChar(subkey), 0, nil, REG_OPTION_NON_VOLATILE,
    KEY_WRITE, nil, k, @disp) <> ERROR_SUCCESS then Exit;
  Result := RegSetValueExA(k, PChar(valname), 0, REG_SZ, PByte(PChar(data)),
    Length(data) + 1) = ERROR_SUCCESS;
  RegCloseKey(k);
end;

function RegisterOne(const AClsid: TGUID; const AName, AFriendly: string): Boolean;
var
  clsidStr, self: string;
begin
  clsidStr := GUIDToString(AClsid);
  self := string(GetSelfPathW);
  Result :=
    RegSetSz(HKEY_CLASSES_ROOT, 'CLSID\' + clsidStr, '', AFriendly) and
    RegSetSz(HKEY_CLASSES_ROOT, 'CLSID\' + clsidStr + '\InprocServer32', '', self) and
    RegSetSz(HKEY_CLASSES_ROOT, 'CLSID\' + clsidStr + '\InprocServer32',
    'ThreadingModel', 'Apartment') and
    // leading spaces raise our alphabetical priority against the ~15-slot limit
    RegSetSz(HKEY_LOCAL_MACHINE, SHELLOVERLAY_KEY + '\' + AName, '', clsidStr);
end;

function RegisterOverlays: HRESULT;
begin
  if RegisterOne(CLSID_Synced, '  GotBoxSynced', 'GotBox synced') and
    RegisterOne(CLSID_Modified, '  GotBoxModified', 'GotBox modified') and
    RegisterOne(CLSID_Conflict, '  GotBoxConflict', 'GotBox conflict') then
    Result := S_OK
  else
    Result := E_FAIL;
end;

procedure UnregisterOne(const AClsid: TGUID; const AName: string);
var
  clsidStr: string;
begin
  clsidStr := GUIDToString(AClsid);
  RegDeleteKeyA(HKEY_CLASSES_ROOT, PChar('CLSID\' + clsidStr + '\InprocServer32'));
  RegDeleteKeyA(HKEY_CLASSES_ROOT, PChar('CLSID\' + clsidStr));
  RegDeleteKeyA(HKEY_LOCAL_MACHINE, PChar(SHELLOVERLAY_KEY + '\' + AName));
end;

function UnregisterOverlays: HRESULT;
begin
  UnregisterOne(CLSID_Synced, '  GotBoxSynced');
  UnregisterOne(CLSID_Modified, '  GotBoxModified');
  UnregisterOne(CLSID_Conflict, '  GotBoxConflict');
  Result := S_OK;
end;

end.
