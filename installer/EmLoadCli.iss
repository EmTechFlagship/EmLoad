; ---------------------------------------------------------------------------
; EmLoad - command-line installer.
;
; Installs the same Python engine/requirements.txt as the WinUI setup, but
; without the desktop shell: just `emload` (plus `emload gui` when PySide6 is
; included). Per-user, no admin prompt.
;
; Build with: powershell -File installer\build-installer.ps1
; ---------------------------------------------------------------------------

#include "EmLoad.Defines.iss"

[Setup]
AppId={{C3A9D2E4-7B1F-4C5A-8E2D-6F4B1A0C9D73}
AppName={#AppName} CLI
AppVersion={#AppVersion}
AppVerName={#AppName} CLI {#BuildLabel}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
DefaultDirName={localappdata}\Programs\EmLoad CLI
DefaultGroupName={#AppName} CLI
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=EmLoad-Cli-Setup-{#OutputTag}
SetupIconFile={#RepoRoot}\gui-winui\EmLoad.WinUI\Assets\EmLoad.ico
UninstallDisplayIcon={app}\bin\emload.cmd
UninstallDisplayName={#AppName} CLI {#BuildLabel}
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
VersionInfoProductName={#AppName} CLI
VersionInfoProductTextVersion={#BuildLabel}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} CLI {#BuildLabel} installer

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "addpath"; Description: "Add the emload command to my user PATH"; GroupDescription: "Command line:"
Name: "pyside"; Description: "Include PySide6 for the optional desktop GUI (emload gui)"; GroupDescription: "Python engine:"
Name: "zsign"; Description: "Download zsign now (required to sign apps)"; GroupDescription: "Python engine:"

[Files]
; The engine root: pyproject.toml + emload\ + requirements.txt.
Source: "{#StageDir}\engine\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "Setup-Engine.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "PathTools.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "Set-UserPath.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion

[InstallDelete]
; Refresh the package on upgrade; .venv and bin are regenerated as needed.
Type: filesandordirs; Name: "{app}\emload"

[Icons]
Name: "{group}\{#AppName} CLI"; Filename: "{cmd}"; Parameters: "/k ""{app}\bin\emload.cmd"""; WorkingDir: "{app}"; Comment: "emload command line"
Name: "{group}\Uninstall {#AppName} CLI"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\bin\emload.cmd"; Parameters: "setup"; StatusMsg: "Downloading zsign ..."; Flags: runhidden waituntilterminated; Tasks: zsign; Check: EngineReady
Filename: "{cmd}"; Parameters: "/k ""{app}\bin\emload.cmd"" doctor"; Description: "Run emload doctor to check the setup"; Flags: postinstall skipifsilent nowait; Check: EngineReady

[UninstallDelete]
Type: filesandordirs; Name: "{app}\.venv"
Type: filesandordirs; Name: "{app}\bin"
Type: filesandordirs; Name: "{app}\emload"
Type: filesandordirs; Name: "{app}\tools"
Type: dirifempty; Name: "{app}"

#include "EmLoad.Code.iss"
