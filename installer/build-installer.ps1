<#
.SYNOPSIS
    Builds the EmLoad installers (WinUI 3 desktop + CLI) from source.

.DESCRIPTION
    End-to-end release build:

      1. publishes the WinUI 3 shell (self-contained, win-x64),
      2. stages the Python engine (emload\, pyproject.toml, requirements.txt),
      3. optionally builds a wheelhouse so the installer works offline,
      4. compiles both Inno Setup installers,
      5. (optionally) packs the portable zip and prints hashes.

    Outputs land in dist\:
      EmLoad-Setup-<tag>.exe       WinUI 3 desktop app + engine
      EmLoad-Cli-Setup-<tag>.exe   command line + engine
      EmLoad-<tag>-win-x64.zip     portable (no admin, no installer)

.PARAMETER Version
    Release version, e.g. 0.1.0.

.PARAMETER Prerelease
    Human-readable channel, e.g. "Beta 1". Leave empty for a final release.

.PARAMETER OutputTag
    Token used in file names. Defaults to "<Version>-<prerelease-slug>",
    e.g. 0.1.0-beta1.

.PARAMETER Offline
    Download every wheel into the installer so it can install without internet.

.PARAMETER SkipPublish
    Reuse the existing dist\EmLoad-win-x64 publish output.

.EXAMPLE
    .\build-installer.ps1

.EXAMPLE
    .\build-installer.ps1 -Version 0.1.0 -Prerelease 'Beta 1' -OutputTag 0.1.0-beta1

.EXAMPLE
    .\build-installer.ps1 -Offline -NoZip
#>
[CmdletBinding()]
param(
    [string]$Version = '0.1.0',
    [string]$Prerelease = 'Beta 1',
    [string]$OutputTag,

    [string]$Iscc,
    [switch]$Offline,
    [switch]$SkipPublish,
    [switch]$SkipWinUI,
    [switch]$SkipCli,
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$distDir = Join-Path $repoRoot 'dist'
$stageDir = Join-Path $PSScriptRoot 'stage'
$publishDir = Join-Path $distDir 'EmLoad-win-x64'
$engineDir = Join-Path $stageDir 'engine'

$slug = ($Prerelease -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
if (-not $OutputTag) {
    if ($slug) { $OutputTag = "$Version-$slug" } else { $OutputTag = $Version }
}
$semver = $Version
if ($slug) { $semver = "$Version-$slug" }

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-Detail {
    param([string]$Text)
    Write-Host "    $Text" -ForegroundColor Gray
}

function Fail {
    param([string]$Text)
    Write-Host ''
    Write-Host "ERROR: $Text" -ForegroundColor Red
    exit 1
}

# --- locate Inno Setup -----------------------------------------------------

function Find-Iscc {
    param([string]$Explicit)

    $candidates = @()
    if ($Explicit) { $candidates += $Explicit }

    $onPath = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }

    foreach ($version in @('7', '6')) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup $version\ISCC.exe")
        $candidates += (Join-Path ${env:ProgramFiles} "Inno Setup $version\ISCC.exe")
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "Inno Setup $version\ISCC.exe")
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

$isccPath = $null
if (-not $SkipWinUI -or -not $SkipCli) {
    $isccPath = Find-Iscc $Iscc
    if (-not $isccPath) {
        Fail ("Inno Setup was not found. Install it from https://jrsoftware.org/isdl.php " +
              "or pass -Iscc <path to ISCC.exe>.")
    }
    Write-Detail "Inno Setup: $isccPath"
}

# --- 1. publish the WinUI shell -------------------------------------------

if (-not $SkipPublish) {
    Write-Step "Publishing the WinUI 3 shell ($semver)"
    $csproj = Join-Path $repoRoot 'gui-winui\EmLoad.WinUI\EmLoad.WinUI.csproj'
    if (-not (Test-Path -LiteralPath $csproj)) { Fail "WinUI project not found: $csproj" }

    if (Test-Path -LiteralPath $publishDir) {
        Remove-Item -LiteralPath $publishDir -Recurse -Force
    }

    $arguments = @(
        'publish', $csproj,
        '-c', 'Release',
        '-r', 'win-x64',
        '--self-contained', 'true',
        '-p:Platform=x64',
        "-p:Version=$semver",
        '-o', $publishDir
    )
    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) { Fail "dotnet publish failed (exit code $LASTEXITCODE)." }
}

if (-not $SkipWinUI) {
    if (-not (Test-Path -LiteralPath (Join-Path $publishDir 'EmLoad.WinUI.exe'))) {
        Fail "The publish output is missing EmLoad.WinUI.exe: $publishDir"
    }
}

# --- 2. stage app + engine -------------------------------------------------

Write-Step 'Staging files'

if (Test-Path -LiteralPath $stageDir) {
    Remove-Item -LiteralPath $stageDir -Recurse -Force
}
$appDir = Join-Path $stageDir 'app'
New-Item -ItemType Directory -Force -Path $appDir, $engineDir | Out-Null

if (-not $SkipWinUI) {
    Copy-Item -Path (Join-Path $publishDir '*') -Destination $appDir -Recurse -Force
    Write-Detail "app:    $(@(Get-ChildItem $appDir -File).Count) files"
}

# The engine root is flattened into {app}: pyproject.toml and emload\ must sit
# beside .venv for PythonLocator and the emload launcher to find them.
Copy-Item -LiteralPath (Join-Path $repoRoot 'emload') -Destination $engineDir -Recurse -Force
foreach ($file in @('pyproject.toml', 'requirements.txt', 'README.md', 'LICENSE')) {
    $source = Join-Path $repoRoot $file
    if (-not (Test-Path -LiteralPath $source)) { Fail "Missing required file: $source" }
    Copy-Item -LiteralPath $source -Destination $engineDir -Force
}

Get-ChildItem -LiteralPath $engineDir -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
Get-ChildItem -LiteralPath $engineDir -Recurse -File -Filter '*.pyc' -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }

$engineFiles = @(Get-ChildItem -LiteralPath $engineDir -Recurse -File)
$engineKb = [int]((($engineFiles | Measure-Object -Property Length -Sum).Sum) / 1KB)
Write-Detail "engine: $($engineFiles.Count) files, $engineKb KB"

# --- 3. optional offline wheelhouse ---------------------------------------

if ($Offline) {
    Write-Step 'Downloading wheels for an offline install'

    $requirements = Join-Path $repoRoot 'requirements.txt'
    $wheelhouse = Join-Path $engineDir 'wheelhouse'
    New-Item -ItemType Directory -Force -Path $wheelhouse | Out-Null

    $python = Join-Path $repoRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python)) {
        $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    }
    if (-not $python) { Fail 'Offline build needs Python on PATH (or the repo .venv) to download wheels.' }

    & $python -m pip download -r $requirements -d $wheelhouse --only-binary=:all: --disable-pip-version-check
    if ($LASTEXITCODE -ne 0) { Fail "pip download failed (exit code $LASTEXITCODE)." }

    $wheelCount = @(Get-ChildItem -LiteralPath $wheelhouse -Filter '*.whl').Count
    Write-Detail "$wheelCount wheels, $([int]((Get-ChildItem $wheelhouse -File | Measure-Object Length -Sum).Sum / 1MB)) MB"
}

# --- 4. compile the installers --------------------------------------------

$definesPath = Join-Path $PSScriptRoot 'build.defines.iss'
$defines = @(
    '; Generated by build-installer.ps1 - do not edit or commit.',
    "#define AppVersion `"$Version`"",
    "#define AppPrerelease `"$Prerelease`"",
    "#define OutputTag `"$OutputTag`"",
    "#define StageDir `"$stageDir`"",
    "#define OutputDir `"$distDir`"",
    "#define RepoRoot `"$repoRoot`""
)
Set-Content -LiteralPath $definesPath -Value $defines -Encoding ASCII
Write-Detail "defines: $definesPath"

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

$built = New-Object System.Collections.ArrayList

function Build-Setup {
    param([string]$ScriptName, [string]$ExpectedName)

    Write-Step "Compiling $ScriptName"
    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    $exePath = Join-Path $distDir $ExpectedName

    if (Test-Path -LiteralPath $exePath) { Remove-Item -LiteralPath $exePath -Force }

    & $isccPath '/Q' $scriptPath
    if ($LASTEXITCODE -ne 0) { Fail "ISCC failed for $ScriptName (exit code $LASTEXITCODE)." }
    if (-not (Test-Path -LiteralPath $exePath)) { Fail "ISCC reported success but $exePath is missing." }

    [void]$built.Add($exePath)
    Write-Detail ("{0}  ({1:N1} MB)" -f (Split-Path -Leaf $exePath), ((Get-Item $exePath).Length / 1MB))
}

if (-not $SkipWinUI) { Build-Setup 'EmLoad.iss' "EmLoad-Setup-$OutputTag.exe" }
if (-not $SkipCli) { Build-Setup 'EmLoadCli.iss' "EmLoad-Cli-Setup-$OutputTag.exe" }

# --- 5. portable zip -------------------------------------------------------

if (-not $NoZip -and -not $SkipWinUI) {
    Write-Step 'Packing the portable build'

    $portableDir = Join-Path $stageDir 'portable'
    New-Item -ItemType Directory -Force -Path $portableDir | Out-Null
    Copy-Item -Path (Join-Path $appDir '*') -Destination $portableDir -Recurse -Force
    Copy-Item -Path (Join-Path $engineDir '*') -Destination $portableDir -Recurse -Force

    $toolsDir = Join-Path $portableDir 'tools'
    New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
    foreach ($tool in @('Setup-Engine.ps1', 'PathTools.ps1', 'Set-UserPath.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $tool) -Destination $toolsDir -Force
    }

    $firstRun = @'
@echo off
rem Portable EmLoad: prepare the Python engine once, then start the app.
setlocal
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" goto run

echo Preparing the Python engine for the first run...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Setup-Engine.ps1" -Root "%~dp0"
if errorlevel 1 (
    echo.
    echo The Python engine could not be prepared. See the message above.
    pause
    exit /b 1
)

:run
start "" "%~dp0EmLoad.WinUI.exe"
'@
    Set-Content -LiteralPath (Join-Path $portableDir 'First-Run.cmd') -Value $firstRun -Encoding ASCII

    $zipPath = Join-Path $distDir "EmLoad-$OutputTag-win-x64.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    # Build the archive by hand: .NET Framework's CreateFromDirectory (used by
    # PowerShell 5.1) stores backslashes, which is not what the ZIP spec and
    # non-Windows tools expect.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $base = (Resolve-Path -LiteralPath $portableDir).Path.TrimEnd('\')
    $archive = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        Get-ChildItem -LiteralPath $portableDir -Recurse -File | ForEach-Object {
            $entryName = $_.FullName.Substring($base.Length + 1).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $_.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally {
        $archive.Dispose()
    }
    [void]$built.Add($zipPath)
    Write-Detail ("{0}  ({1:N1} MB)" -f (Split-Path -Leaf $zipPath), ((Get-Item $zipPath).Length / 1MB))
    Remove-Item -LiteralPath $portableDir -Recurse -Force
}

# --- 6. report -------------------------------------------------------------

Write-Host ''
Write-Host 'Build complete' -ForegroundColor Green
foreach ($item in $built) {
    $file = Get-Item -LiteralPath $item
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    Write-Host ''
    Write-Host ("  {0}" -f $file.Name) -ForegroundColor White
    Write-Host ("    {0,8:N1} MB   {1}" -f ($file.Length / 1MB), $file.DirectoryName) -ForegroundColor Gray
    Write-Host ("    sha256 {0}" -f $hash) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host ("  Version: {0} {1}" -f $Version, $Prerelease).TrimEnd()
Write-Host ''
