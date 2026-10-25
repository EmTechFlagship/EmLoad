; ---------------------------------------------------------------------------
; EmLoad - WinUI 3 desktop app installer.
;
; Per-user install (no admin prompt): the WinUI shell is unpackaged and
; self-contained, and its Python engine lives in <app>\.venv. That is exactly
; the layout the app's PythonLocator looks for (pyproject.toml + emload\ next
; to - or above - the executable).
;
; Build with: powershell -File installer\build-installer.ps1
; ---------------------------------------------------------------------------

#include "EmLoad.Defines.iss"

[Setup]
AppId={{B2F4C1A7-5E3D-4A8B-9C6F-1D2E3A4B5C60}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#BuildLabel}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
DefaultDirName={localappdata}\Programs\EmLoad
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=EmLoad-Setup-{#OutputTag}
SetupIconFile={#RepoRoot}\gui-winui\EmLoad.WinUI\Assets\EmLoad.ico
UninstallDisplayIcon={app}\app\{#AppExeName}
UninstallDisplayName={#AppName} {#BuildLabel}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
CloseApplications=yes
RestartApplications=no
UsePreviousAppDir=yes
AllowNoIcons=yes
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName={#AppName}
VersionInfoProductTextVersion={#BuildLabel}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} {#BuildLabel} installer

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "addpath"; Description: "Add the emload command to my user PATH"; GroupDescription: "Command line:"
Name: "pyside"; Description: "Also install the optional PySide6 desktop GUI (+150 MB)"; GroupDescription: "Python engine:"; Flags: unchecked
Name: "zsign"; Description: "Download zsign now (required to sign apps)"; GroupDescription: "Python engine:"

[Files]
; WinUI shell (published, self-contained).
Source: "{#StageDir}\app\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs createallsubdirs
; Python engine: pyproject.toml + emload\ + requirements.txt at the root, so
; the shell finds it by walking up from app\EmLoad.WinUI.exe.
Source: "{#StageDir}\engine\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Helpers kept in the install so the engine can be repaired from Explorer.
Source: "Setup-Engine.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "PathTools.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "Set-UserPath.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion

[InstallDelete]
; Stale WinUI binaries from a previous version; the venv is left alone.
Type: filesandordirs; Name: "{app}\app"

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\app\{#AppExeName}"; Comment: "Sideload iOS apps with a free Apple ID"
Name: "{group}\{#AppName} (command line)"; Filename: "{cmd}"; Parameters: "/k ""{app}\bin\emload.cmd"""; WorkingDir: "{app}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\app\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\bin\emload.cmd"; Parameters: "setup"; StatusMsg: "Downloading zsign ..."; Flags: runhidden waituntilterminated; Tasks: zsign; Check: EngineReady
Filename: "{app}\app\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Created at install time, so the uninstaller has no record of them.
Type: filesandordirs; Name: "{app}\app"
Type: filesandordirs; Name: "{app}\.venv"
Type: filesandordirs; Name: "{app}\bin"
Type: filesandordirs; Name: "{app}\emload"
Type: filesandordirs; Name: "{app}\tools"
Type: dirifempty; Name: "{app}"

#include "EmLoad.Code.iss"
