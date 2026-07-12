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

library gboxshellext;

{ GotBoxOverlay.dll -- the in-process COM server explorer.exe loads to draw
  TortoiseGit-style per-file status badges. All the logic lives in
  gboxoverlayhandler (three IShellIconOverlayIdentifier classes); this file is
  only the four standard COM DLL entry points + the exports table + the embedded
  badge icons. Windows-only; built for win64 (Explorer on x64 is 64-bit). See
  the Makefile `overlay` target and packaging/windows notes. }

{$mode objfpc}{$H+}

uses
  Windows, gboxoverlayhandler;

{$R gboxoverlay.res}

function DllGetClassObject(constref rclsid, riid: TGUID; out ppv): HRESULT; stdcall;
begin
  Result := HandlerGetClassObject(rclsid, riid, ppv);
end;

function DllCanUnloadNow: HRESULT; stdcall;
begin
  Result := HandlerCanUnloadNow;
end;

function DllRegisterServer: HRESULT; stdcall;
begin
  Result := RegisterOverlays;
end;

function DllUnregisterServer: HRESULT; stdcall;
begin
  Result := UnregisterOverlays;
end;

exports
  DllGetClassObject,
  DllCanUnloadNow,
  DllRegisterServer,
  DllUnregisterServer;

begin
end.
