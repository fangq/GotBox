; Inno Setup script for GotBox.
;
; Built in CI with:
;   ISCC /DAppVersion=<ver> /DSrcDir=<repo root> packaging\windows\gotbox.iss
; SrcDir is the folder holding gotbox.exe / README.md; the installer is written
; to <SrcDir>\dist. Both defines fall back to sensible values for local runs.

#ifndef AppVersion
  #define AppVersion "0.0.0"
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

[Tasks]
Name: "autostart"; Description: "Start GotBox automatically at login (background)"; GroupDescription: "Startup:"

[Files]
Source: "{#SrcDir}\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SrcDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion isreadme

[Icons]
Name: "{group}\GotBox"; Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall GotBox"; Filename: "{uninstallexe}"
; daemon-mode autostart shortcut (uses the new -d flag)
Name: "{userstartup}\GotBox"; Filename: "{app}\{#AppExe}"; Parameters: "-d"; Tasks: autostart

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch GotBox now"; Flags: nowait postinstall skipifsilent
