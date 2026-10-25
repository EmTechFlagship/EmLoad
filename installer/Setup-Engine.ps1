<#
.SYNOPSIS
    Prepares EmLoad's Python engine: finds a usable interpreter, creates a
    private virtual environment and installs the packages from requirements.txt.

.DESCRIPTION
    Used by both EmLoad installers (WinUI desktop and CLI) and runnable on its
    own to repair a broken engine. It never touches the system-wide Python; the
    virtual environment lives at <Root>\.venv, which is exactly where the WinUI
    shell's PythonLocator and the emload launcher look for it.

    The requirements file is copied to a temporary file before pip sees it, so
    "SkipPySide6" can drop the (optional, ~150 MB) PySide6 desktop GUI without
    editing the shipped file.

.PARAMETER Root
    Directory that holds the emload package, pyproject.toml and requirements.txt.

.PARAMETER Requirements
    Requirements file to install. Defaults to <Root>\requirements.txt.

.PARAMETER SkipPySide6
    Leave out PySide6. The WinUI desktop app does not need it; the CLI installer
    includes it because "emload gui" (the PySide6 shell) uses it.

.PARAMETER Force
    Delete and recreate the virtual environment even if it looks healthy.

.PARAMETER Quiet
    Only print warnings and errors (the installers run this hidden).

.PARAMETER LogPath
    Where to write the install log. Defaults to
    %LOCALAPPDATA%\EmLoad\logs\engine-<timestamp>.log.

.OUTPUTS
    Exit code 0 on success, non-zero otherwise:
      2  no suitable Python (3.10+) found
      3  virtual environment could not be created
      4  pip could not install the requirements
      5  the installed engine failed its import self-test
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Root,

    [string]$Requirements,

    [switch]$SkipPySide6,
    [switch]$Force,
    [switch]$Quiet,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:MinPython = [version]'3.10'
$script:VenvDir = Join-Path $Root '.venv'
$script:VenvPython = Join-Path $script:VenvDir 'Scripts\python.exe'
$script:BinDir = Join-Path $Root 'bin'

if (-not $LogPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogPath = Join-Path $env:LOCALAPPDATA "EmLoad\logs\engine-$stamp.log"
}
$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
$script:LogPath = $LogPath

function Write-Status {
    param(
        [Parameter(Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '[{0}] {1,-5} {2}' -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }

    if ((-not $Quiet) -or $Level -ne 'INFO') {
        $color = 'Gray'
        if ($Level -eq 'WARN') { $color = 'Yellow' }
        if ($Level -eq 'ERROR') { $color = 'Red' }
        Write-Host $line -ForegroundColor $color
    }
}

function Fail {
    param(
        [Parameter(Position = 0)][string]$Message,
        [Parameter(Position = 1)][int]$Code = 1
    )
    Write-Status $Message 'ERROR'
    exit $Code
}

# --- Python discovery ------------------------------------------------------

function Get-PythonId {
    <# Returns "3.12" for a usable interpreter, or $null. #>
    param([string]$Exe)

    if ([string]::IsNullOrWhiteSpace($Exe) -or -not (Test-Path -LiteralPath $Exe)) { return $null }

    try {
        # Note: keep the Python code free of double quotes. The Microsoft Store
        # app-execution alias mangles arguments that contain them.
        $out = & $Exe -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $text = ($out | Where-Object { $_ -match '^\d+\.\d+$' } | Select-Object -First 1)
        if (-not $text) { return $null }
        return [version]$text
    }
    catch {
        return $null
    }
}

function Get-InterpreterPath {
    <# Resolves the py launcher ("py -3.12") to a concrete python.exe. #>
    param([string]$LauncherArgs)

    try {
        $out = & py $LauncherArgs -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($out | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
    }
    catch {
        return $null
    }
}

function Get-PythonCandidates {
    $candidates = New-Object System.Collections.ArrayList

    if ($env:EMLOAD_PYTHON) { [void]$candidates.Add($env:EMLOAD_PYTHON) }

    # The py launcher knows about installs that are not on PATH.
    foreach ($tag in @('-3.12', '-3.13', '-3.11', '-3.10', '-3')) {
        $resolved = Get-InterpreterPath $tag
        if ($resolved) { [void]$candidates.Add($resolved) }
    }

    # Anything on PATH (the Microsoft Store stub fails the version probe).
    foreach ($name in @('python', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { [void]$candidates.Add($cmd.Source) }
    }

    # Registry installs, including the 32-bit view.
    $regRoots = @(
        'HKLM:\SOFTWARE\Python\PythonCore',
        'HKCU:\SOFTWARE\Python\PythonCore',
        'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore'
    )
    foreach ($regRoot in $regRoots) {
        if (-not (Test-Path $regRoot)) { continue }
        Get-ChildItem $regRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $installPath = Join-Path $_.PSPath 'InstallPath'
            if (Test-Path $installPath) {
                $value = (Get-ItemProperty -LiteralPath $installPath -ErrorAction SilentlyContinue).'(default)'
                if (-not $value) {
                    $value = (Get-ItemProperty -LiteralPath $installPath -ErrorAction SilentlyContinue).ExecutablePath
                }
                if ($value) {
                    if (Test-Path -LiteralPath $value -PathType Container) {
                        [void]$candidates.Add((Join-Path $value 'python.exe'))
                    }
                    else {
                        [void]$candidates.Add($value)
                    }
                }
            }
        }
    }

    # Conventional directories (per-user first, then machine-wide).
    $patterns = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python3*\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Python\pythoncore-*\python.exe'),
        (Join-Path $env:ProgramFiles 'Python3*\python.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Python3*\python.exe'),
        'C:\Python3*\python.exe'
    )
    foreach ($pattern in $patterns) {
        if (-not $pattern -or $pattern -notmatch '^[A-Za-z]:') { continue }
        Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$candidates.Add($_.FullName)
        }
    }

    return $candidates
}

function Select-Python {
    $seen = @{}
    $best = $null
    $bestScore = [int]::MaxValue
    $bestVersion = [version]'0.0'

    foreach ($candidate in (Get-PythonCandidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        $full = $null
        try { $full = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch { continue }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $version = Get-PythonId $full
        if (-not $version) { continue }
        if ($version -lt $script:MinPython) {
            Write-Status "Ignoring Python $version at $full (need $($script:MinPython)+)." 'WARN'
            continue
        }

        # Prefer the versions the wheel ecosystem is happiest with.
        $score = switch ($version.ToString()) {
            '3.12' { 0 }
            '3.13' { 1 }
            '3.11' { 2 }
            '3.10' { 3 }
            '3.14' { 4 }
            default { 5 }
        }

        if ($score -lt $bestScore -or ($score -eq $bestScore -and $version -gt $bestVersion)) {
            $best = $full
            $bestScore = $score
            $bestVersion = $version
        }
    }

    return $best
}

# --- requirements ----------------------------------------------------------

function Get-EffectiveRequirements {
    <# Writes the requirements pip should see and returns its path. #>
    param([string]$Source, [bool]$WithoutPySide6)

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Requirements file not found: $Source"
    }

    $kept = New-Object System.Collections.ArrayList
    foreach ($line in (Get-Content -LiteralPath $Source)) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        if ($WithoutPySide6 -and $trimmed -match '^(?i)pyside6\b') {
            Write-Status 'Skipping PySide6 (desktop shell does not use it).'
            continue
        }
        [void]$kept.Add($trimmed)
    }

    if ($kept.Count -eq 0) { throw "No requirements left to install from $Source" }

    $temp = Join-Path $env:TEMP ('emload-requirements-' + [guid]::NewGuid().ToString('N') + '.txt')
    Set-Content -LiteralPath $temp -Value $kept -Encoding ASCII
    return $temp
}

# --- main ------------------------------------------------------------------

try {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        Fail "Install directory not found: $Root" 1
    }
    $Root = (Resolve-Path -LiteralPath $Root).Path
    $script:VenvDir = Join-Path $Root '.venv'
    $script:VenvPython = Join-Path $script:VenvDir 'Scripts\python.exe'
    $script:BinDir = Join-Path $Root 'bin'

    if (-not $Requirements) { $Requirements = Join-Path $Root 'requirements.txt' }
    if (-not (Test-Path -LiteralPath $Requirements)) {
        Fail "requirements.txt not found next to the engine: $Requirements" 1
    }

    Write-Status "EmLoad engine setup"
    Write-Status "  root:         $Root"
    Write-Status "  requirements: $Requirements"
    Write-Status "  log:          $LogPath"

    # Fast path: an existing venv that imports the engine and deps is left alone.
    $reuse = $false
    if (-not $Force -and (Test-Path -LiteralPath $script:VenvPython)) {
        Push-Location $Root
        try {
            & $script:VenvPython -c 'import emload, pymobiledevice3, srp, cryptography, requests, certifi, wsproto' 2>$null | Out-Null
            $reuse = ($LASTEXITCODE -eq 0)
        }
        finally { Pop-Location }

        if ($reuse) {
            Write-Status 'Existing virtual environment is healthy; leaving it alone.'
        }
        else {
            Write-Status 'Existing virtual environment is incomplete; rebuilding it.' 'WARN'
        }
    }

    if (-not $reuse) {
        if ($Force -and (Test-Path -LiteralPath $script:VenvDir)) {
            Write-Status 'Removing the old virtual environment (-Force).'
            Remove-Item -LiteralPath $script:VenvDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        elseif (Test-Path -LiteralPath $script:VenvDir) {
            Remove-Item -LiteralPath $script:VenvDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        $python = Select-Python
        if (-not $python) {
            Fail ("Python 3.10 or newer was not found. Install it from " +
                  "https://www.python.org/downloads/windows/ (tick 'Add python.exe to PATH') " +
                  "and run this installer again.") 2
        }

        $pythonVersion = Get-PythonId $python
        Write-Status "Using Python $pythonVersion ($python)"

        Write-Status 'Creating the virtual environment (.venv) ...'
        & $python -m venv $script:VenvDir
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $script:VenvPython)) {
            Fail ("Could not create a virtual environment with $python. " +
                  "A Microsoft Store copy of Python cannot create one; install the " +
                  "full build from python.org instead.") 3
        }

        Write-Status 'Upgrading pip ...'
        & $script:VenvPython -m pip install --upgrade pip --disable-pip-version-check --no-input --quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Status 'pip self-upgrade failed; continuing with the bundled pip.' 'WARN'
        }

        $effective = $null
        try {
            $effective = Get-EffectiveRequirements -Source $Requirements -WithoutPySide6 ([bool]$SkipPySide6)

            $pipArgs = @(
                '-m', 'pip', 'install',
                '--disable-pip-version-check',
                '--no-input',
                '--no-warn-script-location',
                '--retries', '3',
                '--timeout', '60',
                '-r', $effective
            )

            $wheelhouse = Join-Path $Root 'wheelhouse'
            if (Test-Path -LiteralPath $wheelhouse) {
                $wheels = @(Get-ChildItem -LiteralPath $wheelhouse -Filter '*.whl' -ErrorAction SilentlyContinue)
                if ($wheels.Count -gt 0) {
                    Write-Status "Installing from the bundled wheelhouse ($($wheels.Count) wheels, offline)."
                    $pipArgs += @('--no-index', '--find-links', $wheelhouse)
                }
            }

            Write-Status 'Installing Python packages (this can take a few minutes) ...'
            & $script:VenvPython @pipArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Status 'First pip run failed; retrying once ...' 'WARN'
                & $script:VenvPython @pipArgs
                if ($LASTEXITCODE -ne 0) {
                    Fail ("pip could not install the requirements (exit code $LASTEXITCODE). " +
                          "Check the log, then re-run this installer. If you are offline, " +
                          "build the installer with -Offline so it carries a wheelhouse.") 4
                }
            }
        }
        finally {
            if ($effective -and (Test-Path -LiteralPath $effective)) {
                Remove-Item -LiteralPath $effective -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Status 'Verifying the engine ...'
    $probe = 'import emload, pymobiledevice3, srp, cryptography, requests, certifi, wsproto'
    if (-not $SkipPySide6) { $probe += ', PySide6' }

    Push-Location $Root
    $verifyOk = $false
    try {
        & $script:VenvPython -c $probe 2>&1 | ForEach-Object { if ($_ -and -not $Quiet) { Write-Host "    $_" } }
        $verifyOk = ($LASTEXITCODE -eq 0)
    }
    finally { Pop-Location }

    if (-not $verifyOk) {
        Fail 'The engine installed but failed to import. See the log above for the traceback.' 5
    }

    # --- launchers ---------------------------------------------------------
    if (-not (Test-Path -LiteralPath $script:BinDir)) {
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    }

    $cliShim = @"
@echo off
rem EmLoad CLI launcher. Generated by Setup-Engine.ps1.
setlocal
for %%I in ("%~dp0..") do set "EMLOAD_HOME=%%~fI"
"%EMLOAD_HOME%\.venv\Scripts\python.exe" -m emload %*
"@
    Set-Content -LiteralPath (Join-Path $script:BinDir 'emload.cmd') -Value $cliShim -Encoding ASCII

    if (-not $SkipPySide6) {
        $guiShim = @"
@echo off
rem EmLoad PySide6 desktop launcher. Generated by Setup-Engine.ps1.
setlocal
for %%I in ("%~dp0..") do set "EMLOAD_HOME=%%~fI"
start "" "%EMLOAD_HOME%\.venv\Scripts\pythonw.exe" -m emload gui
"@
        Set-Content -LiteralPath (Join-Path $script:BinDir 'emload-gui.cmd') -Value $guiShim -Encoding ASCII
    }

    Write-Status 'Engine is ready.' 
    if (-not $Quiet) {
        Write-Host ''
        Write-Host '  Next steps:' -ForegroundColor Cyan
        Write-Host '    emload setup       download zsign (required for signing)'
        Write-Host '    emload doctor      check the environment'
        Write-Host ''
    }
    exit 0
}
catch {
    Write-Status ("Unexpected failure: " + $_.Exception.Message) 'ERROR'
    Write-Status ($_.ScriptStackTrace) 'ERROR'
    exit 1
}
