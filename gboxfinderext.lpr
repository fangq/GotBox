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

program gboxfinderext;

{ Executable of GotBoxFinder.appex -- the macOS Finder Sync extension. The real
  logic lives in gboxfindersync (the FIFinderSync subclass); this entry point
  just hands control to NSExtensionMain, which reads the bundle Info.plist's
  NSExtensionPrincipalClass (= GotBoxFinderSync), instantiates it, and runs the
  extension host run loop. NSExtensionMain does not return. macOS-only. }

{$mode objfpc}{$H+}
{$linkframework Foundation}
{$linkframework AppKit}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  ctypes,
  gboxfindersync;   // pulls in + registers the GotBoxFinderSync objcclass

{ Provided by Foundation.framework (macOS 10.10+). }
function NSExtensionMain(argc: cint; argv: PPChar): cint; cdecl; external;

begin
  NSExtensionMain(argc, argv);
end.
