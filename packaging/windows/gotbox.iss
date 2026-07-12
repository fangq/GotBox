; Inno Setup script for GotBox.
;
; Built in CI with:
;   ISCC /DAppVersion=<ver> /DAppVerNumeric=<a.b.c.d> /DSrcDir=<repo root> \
;        packaging\windows\gotbox.iss
; SrcDir is the folder holding gotbox.exe / README.md; the installer is written
; to <SrcDir>\dist. All defines fall back to sensible values for local runs.
; AppVersion is the display/filename version (keep it clean -- no '~', which is
; an odd char on Windows); AppVerNumeric is the a.b.c.d form the PE VersionInfo
; requires. Embedding VersionInfo below makes the installer a named, attributed
; binary instead of an anonymous one, which Defender/SmartScreen reputation
; heuristics treat far more kindly than a metadata-less exe.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef AppVerNumeric
  #define AppVerNumeric "1.0.0.0"
#endif
#ifndef SrcDir
  #define SrcDir SourcePath + "..\.."
#endif

#define AppName "GotBox"
#define AppExe "gotbox.exe"

[Setup]
AppId={{B7E5B0A2-1C3D-4E6F-9A8B-2C4D6E8F0A12}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Qianqian Fang
AppPublisherURL=https://github.com/fangq/GotBox
DefaultDirName={autopf}\GotBox
DefaultGroupName=GotBox
DisableProgramGroupPage=yes
; per-user install, no administrator rights required
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesInstallIn64BitMode=x64
OutputDir={#SrcDir}\dist
OutputBaseFilename=gotbox-setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#AppName}
; embedded PE VersionInfo (VersionInfoVersion must be numeric a.b.c.d)
VersionInfoVersion={#AppVerNumeric}
VersionInfoProductVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoCompany=Qianqian Fang
VersionInfoDescription=GotBox Setup
VersionInfoCopyright=(C) 2026 Qianqian Fang <fangqq at gmail.com>. GPLv3-or-later.

[Tasks]
Name: "autostart"; Description: "Start GotBox automatically at login (background)"; GroupDescription: "Startup:"
; Explorer icon overlays are an opt-in, elevated step: ticking this runs
; gotbox --register-overlays after install, which raises its own UAC prompt
; (the installer itself stays per-user / no-admin). Unchecked by default.
Name: "overlays"; Description: "Enable Windows Explorer status icon overlays (requires administrator)"; GroupDescription: "File manager integration:"; Flags: unchecked

[Files]
Source: "{#SrcDir}\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
; the COM shell-extension DLL for the Explorer overlays (registered on demand)
Source: "{#SrcDir}\GotBoxOverlay.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SrcDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion isreadme

[Icons]
Name: "{group}\GotBox"; Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall GotBox"; Filename: "{uninstallexe}"
; daemon-mode autostart shortcut (uses the new -d flag)
Name: "{userstartup}\GotBox"; Filename: "{app}\{#AppExe}"; Parameters: "-d"; Tasks: autostart

[Run]
; register the Explorer overlays if the user opted in (self-elevates via UAC).
; runascurrentuser keeps the elevation inside gotbox.exe's own runas prompt.
Filename: "{app}\{#AppExe}"; Parameters: "--register-overlays"; Tasks: overlays; Flags: runhidden runascurrentuser waituntilterminated
Filename: "{app}\{#AppExe}"; Description: "Launch GotBox now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; best-effort removal of the overlay registration before files are deleted
Filename: "{app}\{#AppExe}"; Parameters: "--unregister-overlays"; RunOnceId: "UnregOverlays"; Flags: runhidden runascurrentuser waituntilterminated
