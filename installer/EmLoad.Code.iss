; ---------------------------------------------------------------------------
; Shared Pascal script for both EmLoad installers.
;
; Both setups install the same Python engine, so both must:
;   * create the .venv from requirements.txt (Setup-Engine.ps1 does the work),
;   * optionally put <app>\bin on the user PATH (Set-UserPath.ps1 does that,
;     because Inno's Pascal script cannot broadcast WM_SETTINGCHANGE itself).
;
; The tasks consulted here - "pyside" and "addpath" - are declared by each
; installer's own [Tasks] section.
; ---------------------------------------------------------------------------

[Code]

var
  EngineLogPath: String;

function PowerShellExe: String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function RunPowerShell(const Arguments: String): Integer;
var
  ResultCode: Integer;
begin
  if Exec(PowerShellExe, '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' + Arguments,
          ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := ResultCode
  else
    Result := -1;
end;

function EngineArguments: String;
begin
  Result := '';
  if not WizardIsTaskSelected('pyside') then
    Result := Result + ' -SkipPySide6';
end;

procedure UpdatePathEntry(const ExtraArguments: String);
begin
  RunPowerShell('-File "' + ExpandConstant('{app}\tools\Set-UserPath.ps1') +
                '" -Dir "' + ExpandConstant('{app}\bin') + '" -Quiet' + ExtraArguments);
end;

{ True once the engine bootstrap has produced the launcher. Used by [Run]
  entries so optional steps do not fire when the engine was skipped. }
function EngineReady: Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\bin\emload.cmd'));
end;

{ Creates the virtual environment and installs requirements.txt.

  On failure the user gets Abort / Retry / Ignore:
    Abort  - roll the installation back (the app would not start anyway),
    Retry  - run it again (network hiccups, a just-closed pip, ...),
    Ignore - keep the files and fix it later by running
             tools\Setup-Engine.ps1 again. }
procedure PrepareEngine;
var
  ResultCode: Integer;
  Answer: Integer;
  Message: String;
begin
  EngineLogPath := ExpandConstant('{localappdata}\EmLoad\logs\install-' +
    GetDateTimeString('yyyy-mm-dd-hh-nn-ss', '-', '-') + '.log');
  ForceDirectories(ExpandConstant('{localappdata}\EmLoad\logs'));

  repeat
    ResultCode := RunPowerShell(
      '-File "' + ExpandConstant('{app}\tools\Setup-Engine.ps1') + '"' +
      ' -Root "' + ExpandConstant('{app}') + '"' +
      ' -LogPath "' + EngineLogPath + '"' +
      EngineArguments);

    if ResultCode = 0 then
      Break;

    Message := 'EmLoad could not prepare its Python engine (exit code ' + IntToStr(ResultCode) + ').' + #13#10 + #13#10 +
      'The usual causes are:' + #13#10 +
      '  - Python 3.10 or newer is not installed' + #13#10 +
      '  - pip could not reach the internet' + #13#10 + #13#10 +
      'Details: ' + EngineLogPath + #13#10 + #13#10 +
      'Retry tries again. Ignore keeps EmLoad installed; you can fix the engine later by ' +
      'running tools\Setup-Engine.ps1. Abort undoes the installation.';

    Answer := SuppressibleMsgBox(Message, mbError, MB_ABORTRETRYIGNORE, IDABORT);

    if Answer = IDIGNORE then
      Break;
    if Answer = IDABORT then
      Abort;
    { IDRETRY falls through and runs the setup again. }
  until False;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep <> ssPostInstall then
    Exit;

  { Escape hatch for CI and offline smoke tests: Setup.exe /SKIPENGINE=1 skips
    only the Python part; shortcuts and PATH are still created. }
  if ExpandConstant('{param:skipengine|0}') <> '1' then
    PrepareEngine;

  if WizardIsTaskSelected('addpath') then
    UpdatePathEntry('');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  { Remove the PATH entry while tools\Set-UserPath.ps1 is still on disk. }
  if CurUninstallStep = usUninstall then
    UpdatePathEntry(' -Remove');
end;
