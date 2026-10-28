<#
.SYNOPSIS
    Installs (or removes) the EmLoad command-line app and its Python engine.

.DESCRIPTION
    A self-contained installer for the "requirements.txt" side of EmLoad. It:

      1. copies the emload package into a per-user folder,
      2. creates a private virtual environment and installs requirements.txt,
      3. drops an "emload.cmd" launcher into <InstallDir>\bin and puts that
         folder on the user PATH,
      4. registers an entry in Settings > Apps so it can be uninstalled.

    There is no admin prompt and nothing is written outside the user profile.
    The WinUI desktop installer does not use this script; both share
    Setup-Engine.ps1 so the Python environment is prepared identically.

.PARAMETER InstallDir
    Target folder. Defaults to %LOCALAPPDATA%\Programs\EmLoad CLI.

.PARAMETER Source
    Folder that holds emload\, pyproject.toml and requirements.txt. Defaults to
    the repository this script was run from.

.PARAMETER SkipPySide6
    Do not install PySide6. "emload" works; "emload gui" (PySide6 shell) will not.

.PARAMETER SkipPath
    Leave the user PATH untouched (run emload from <InstallDir>\bin).

.PARAMETER Force
    Recreate the virtual environment even if it looks healthy.

.PARAMETER Uninstall
    Remove the install, the PATH entry and the uninstall registration.

.PARAMETER SetupZsign
    Also download zsign (the signing helper) right away.

.EXAMPLE
    .\install-cli.ps1

.EXAMPLE
    .\install-cli.ps1 -InstallDir 'D:\Tools\EmLoad' -SkipPySide6

.EXAMPLE
    .\install-cli.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\EmLoad CLI'),
    [string]$Source,
    [string]$DisplayVersion = '0.1.0 Beta 2',
    [string]$ProductName = 'EmLoad CLI',

    [switch]$SkipPySide6,
    [switch]$SkipPath,
    [switch]$Force,
    [switch]$Quiet,
    [switch]$Uninstall,
    [switch]$SetupZsign,

    # internal: set when the uninstaller re-launches itself from %TEMP%
    [switch]$NoRelaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:RegKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\EmLoadCLI'
$script:InstallDir = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$script:BinDir = Join-Path $script:InstallDir 'bin'
$script:ToolsDir = Join-Path $script:InstallDir 'tools'

function Write-Status {
    param(
        [Parameter(Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )

    if ($Quiet -and $Level -eq 'INFO') { return }
    $color = switch ($Level) {
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'OK' { 'Green' }
        default { 'Gray' }
    }
    Write-Host ("  " + $Message) -ForegroundColor $color
}

function Write-Header {
    param([string]$Text)
    if ($Quiet) { return }
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
}

# --- shared helpers --------------------------------------------------------

# User-PATH editing lives in PathTools.ps1 so both installers behave the same.
. (Join-Path $PSScriptRoot 'PathTools.ps1')

# --- helpers ---------------------------------------------------------------

function Get-EngineSource {
    param([string]$Candidate)

    if ($Candidate) {
        if (Test-Path -LiteralPath (Join-Path $Candidate 'emload\__init__.py')) { return $Candidate }
        return $null
    }

    $candidates = @(
        (Split-Path -Parent $PSScriptRoot),   # repo checkout: installer\.. 
        $script:InstallDir                   # repairing an existing install
    )

    foreach ($item in $candidates) {
        if ($item -and (Test-Path -LiteralPath (Join-Path $item 'emload\__init__.py'))) {
            return $item
        }
    }
    return $null
}

function Remove-Pycache {
    param([string]$Root)
    $packageDir = Join-Path $Root 'emload'
    if (-not (Test-Path -LiteralPath $packageDir)) { return }
    Get-ChildItem -LiteralPath $packageDir -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

function Copy-Engine {
    param([string]$From, [string]$To)

    New-Item -ItemType Directory -Force -Path $To | Out-Null

    if ($From.TrimEnd('\') -ine $To.TrimEnd('\')) {
        # Replace the package rather than merging, so files removed in a newer
        # version do not linger after an upgrade.
        $destPackage = Join-Path $To 'emload'
        if (Test-Path -LiteralPath $destPackage) {
            Remove-Item -LiteralPath $destPackage -Recurse -Force
        }
        Copy-Item -LiteralPath (Join-Path $From 'emload') -Destination $To -Recurse -Force
        foreach ($file in @('pyproject.toml', 'requirements.txt', 'README.md', 'LICENSE')) {
            $path = Join-Path $From $file
            if (Test-Path -LiteralPath $path) {
                Copy-Item -LiteralPath $path -Destination (Join-Path $To $file) -Force
            }
        }
    }
    Remove-Pycache -Root $To

    New-Item -ItemType Directory -Force -Path $script:ToolsDir | Out-Null
    foreach ($tool in @('Setup-Engine.ps1', 'PathTools.ps1', 'Set-UserPath.ps1')) {
        $toolPath = Join-Path $PSScriptRoot $tool
        if (Test-Path -LiteralPath $toolPath) {
            Copy-Item -LiteralPath $toolPath -Destination $script:ToolsDir -Force
        }
    }

    $self = $PSCommandPath
    $target = Join-Path $script:ToolsDir 'install-cli.ps1'
    if ($self -and ([System.IO.Path]::GetFullPath($self) -ine [System.IO.Path]::GetFullPath($target))) {
        Copy-Item -LiteralPath $self -Destination $target -Force
    }

    Set-Content -LiteralPath (Join-Path $script:ToolsDir 'version.txt') `
        -Value ("$ProductName $DisplayVersion") -Encoding ASCII
}

function Register-Uninstaller {
    param([int]$SizeKb)

    New-Item -Path $script:RegKey -Force | Out-Null
    $uninstallString = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Uninstall -InstallDir "{1}"' -f `
        (Join-Path $script:ToolsDir 'install-cli.ps1'), $script:InstallDir

    $values = [ordered]@{
        DisplayName     = "$ProductName $DisplayVersion"
        DisplayVersion  = $DisplayVersion
        Publisher       = 'EmLoad contributors'
        InstallLocation = $script:InstallDir
        UninstallString = $uninstallString
        QuietUninstallString = $uninstallString + ' -Quiet'
        InstallDate     = (Get-Date -Format 'yyyyMMdd')
        NoModify        = 1
        NoRepair        = 1
        EstimatedSize   = $SizeKb
    }
    foreach ($name in $values.Keys) {
        $value = $values[$name]
        $type = 'String'
        if ($value -is [int]) { $type = 'DWord' }
        New-ItemProperty -Path $script:RegKey -Name $name -Value $value -PropertyType $type -Force | Out-Null
    }
}

# --- uninstall -------------------------------------------------------------

function Uninstall-EmLoad {
    Write-Header "Removing $ProductName from $script:InstallDir"

    if (-not (Test-Path -LiteralPath $script:InstallDir)) {
        Write-Status 'Nothing is installed there.' 'WARN'
        Remove-UserPath -Entry $script:BinDir | Out-Null
        if (Test-Path $script:RegKey) { Remove-Item -Path $script:RegKey -Recurse -Force -ErrorAction SilentlyContinue }
        return 0
    }

    $looksRight = (Test-Path -LiteralPath (Join-Path $script:InstallDir 'emload')) -or
                  (Test-Path -LiteralPath (Join-Path $script:InstallDir 'pyproject.toml'))
    if (-not $looksRight -and -not $Force) {
        Write-Status "Refusing to delete $script:InstallDir - it does not look like an EmLoad install." 'ERROR'
        Write-Status 'Pass -Force if you are sure.' 'ERROR'
        return 1
    }

    # Deleting the folder that contains the running script is fine, but the
    # file handle can lag on some systems. Copy ourselves to %TEMP% first.
    $self = $PSCommandPath
    $inside = $self -and [System.IO.Path]::GetFullPath($self).ToLowerInvariant().StartsWith(
        $script:InstallDir.ToLowerInvariant() + '\')

    if ($inside -and -not $NoRelaunch) {
        $tempScript = Join-Path $env:TEMP ('emload-uninstall-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Copy-Item -LiteralPath $self -Destination $tempScript -Force
        $argString = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Uninstall -NoRelaunch -InstallDir "{1}"' -f `
            $tempScript, $script:InstallDir
        if ($Quiet) { $argString += ' -Quiet' }
        if ($Force) { $argString += ' -Force' }
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argString -Wait -PassThru
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        return $proc.ExitCode
    }

    if (Remove-UserPath -Entry $script:BinDir) {
        Write-Status 'Removed the PATH entry.' 'OK'
    }

    if (Test-Path $script:RegKey) {
        Remove-Item -Path $script:RegKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status 'Removed the Apps list entry.' 'OK'
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Remove-Item -LiteralPath $script:InstallDir -Recurse -Force -ErrorAction Stop
            break
        }
        catch {
            if ($attempt -eq 3) {
                Write-Status ("Could not delete {0}: {1}" -f $script:InstallDir, $_.Exception.Message) 'ERROR'
                Write-Status 'Close any EmLoad windows and run the uninstaller again.' 'ERROR'
                return 1
            }
            Start-Sleep -Milliseconds 700
        }
    }

    Write-Status 'EmLoad CLI removed.' 'OK'
    Write-Status 'Your Apple ID sign-in, certificates and install registry in %LOCALAPPDATA%\EmLoad were kept.'
    return 0
}

# --- install ---------------------------------------------------------------

function Install-EmLoad {
    $engineSource = Get-EngineSource $Source
    if (-not $engineSource) {
        Write-Status 'Could not find the EmLoad engine (emload\__init__.py).' 'ERROR'
        Write-Status 'Run this from the repository, or pass -Source <folder>.' 'ERROR'
        return 1
    }
    $engineSource = (Resolve-Path -LiteralPath $engineSource).Path

    Write-Header "Installing $ProductName $DisplayVersion"
    Write-Status "engine:  $engineSource"
    Write-Status "target:  $script:InstallDir"

    New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null

    if ($engineSource.TrimEnd('\') -ine $script:InstallDir.TrimEnd('\')) {
        Write-Status 'Copying the engine ...'
    }
    else {
        Write-Status 'Repairing the existing install in place ...'
    }
    Copy-Engine -From $engineSource -To $script:InstallDir

    # --- Python environment ------------------------------------------------
    $engineArgs = @{
        Root         = $script:InstallDir
        Requirements = (Join-Path $script:InstallDir 'requirements.txt')
        Quiet        = $Quiet
    }
    if ($SkipPySide6) { $engineArgs['SkipPySide6'] = $true }
    if ($Force) { $engineArgs['Force'] = $true }

    $setupEngine = Join-Path $script:ToolsDir 'Setup-Engine.ps1'
    & $setupEngine @engineArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Status "Python setup failed (exit code $LASTEXITCODE)." 'ERROR'
        Write-Status 'The files are installed; fix the problem and run this installer again to retry.' 'ERROR'
        return $LASTEXITCODE
    }

    # --- PATH ---------------------------------------------------------------
    if (-not $SkipPath) {
        if (Add-UserPath -Entry $script:BinDir) {
            Write-Status "Added $script:BinDir to your PATH (open a new terminal to use it)." 'OK'
        }
        else {
            Write-Status "PATH already contains $script:BinDir."
        }
    }

    # --- uninstall registration --------------------------------------------
    $total = (Get-ChildItem -LiteralPath $script:InstallDir -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $sizeKb = 0
    if ($total) { $sizeKb = [int]($total / 1KB) }
    Register-Uninstaller -SizeKb $sizeKb

    if ($SetupZsign) {
        Write-Status 'Downloading zsign ...'
        & (Join-Path $script:BinDir 'emload.cmd') setup
        if ($LASTEXITCODE -ne 0) { Write-Status 'zsign download failed; run "emload setup" later.' 'WARN' }
    }

    Write-Header 'EmLoad CLI is installed.'
    if (-not $Quiet) {
        Write-Host '  Open a new terminal, then run:' -ForegroundColor Gray
        Write-Host '    emload doctor        check the environment' -ForegroundColor Gray
        Write-Host '    emload setup         download zsign (required to sign)' -ForegroundColor Gray
        if (-not $SkipPySide6) {
            Write-Host '    emload gui           open the PySide6 desktop app' -ForegroundColor Gray
        }
        Write-Host ''
        Write-Host '  Without a new terminal, use:' -ForegroundColor DarkGray
        Write-Host ("    `"{0}`"" -f (Join-Path $script:BinDir 'emload.cmd')) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  Uninstall from Settings > Apps, or run:' -ForegroundColor DarkGray
        Write-Host '    install-cli.ps1 -Uninstall' -ForegroundColor DarkGray
        Write-Host ''
    }
    return 0
}

if ($Uninstall) { exit (Uninstall-EmLoad) }
exit (Install-EmLoad)
