# EmLoad installers

This folder builds the Windows release artifacts. There are three of them:

| Artifact | Contents |
| --- | --- |
| `EmLoad-Setup-<tag>.exe` | WinUI 3 desktop app + Python engine |
| `EmLoad-Cli-Setup-<tag>.exe` | Python engine + `emload` on PATH |
| `EmLoad-<tag>-win-x64.zip` | Portable folder, no installer |

Everything is **per-user** (`PrivilegesRequired=lowest`): no UAC prompt, no
machine-wide changes, uninstall via **Settings → Apps**.

## Build

```powershell
# from the repository root
powershell -File installer\build-installer.ps1

# a different version / channel
powershell -File installer\build-installer.ps1 -Version 0.1.0 -Prerelease 'Beta 1'

# reuse the existing dotnet publish output, skip the zip
powershell -File installer\build-installer.ps1 -SkipPublish -NoZip

# installer that works without internet (bundles every wheel)
powershell -File installer\build-installer.ps1 -Offline
```

Outputs go to `dist\`. The script prints size and SHA-256 for each file.

### Prerequisites

| Tool | Why | Notes |
| --- | --- | --- |
| .NET SDK 10 | publishes the WinUI 3 shell | `dotnet --version` |
| [Inno Setup 6 or 7](https://jrsoftware.org/isdl.php) | compiles the `.exe` installers | auto-detected in the usual folders; or pass `-Iscc <path>` |
| Python 3.10+ | only for `-Offline` (downloads wheels) | the repo `.venv` is used when present |

`dotnet publish` needs the Windows App SDK workload that the project already
restores; no separate installer is required because the app is published
self-contained (`WindowsPackageType=None`).

### Versioning

| Parameter | Default | Appears in |
| --- | --- | --- |
| `-Version` | `0.1.0` | file version, `AppVersion` |
| `-Prerelease` | `Beta 1` | "EmLoad 0.1.0 Beta 1" in Setup and Apps list |
| `-OutputTag` | `<version>-<slug>` (`0.1.0-beta1`) | output file names |

The Python side carries the matching PEP 440 version (`0.1.0b1` in
`pyproject.toml` and `emload/__init__.py`). Keep the two in sync when cutting a
release.

### Releasing from GitHub Actions

`.github/workflows/release.yml` builds the same three artifacts on
`windows-latest` and publishes them as a GitHub release. A tag is the whole
interface:

```powershell
git tag v0.1.0-beta1
git push origin v0.1.0-beta1
```

The tag is parsed into every version string, so nothing needs editing first:

| Tag | Version | Channel | File tag | Python |
| --- | --- | --- | --- | --- |
| `v0.1.0-beta1` | `0.1.0` | `Beta 1` | `0.1.0-beta1` | `0.1.0b1` |
| `v1.2.3-rc2` | `1.2.3` | `RC 2` | `1.2.3-rc2` | `1.2.3rc2` |
| `v2.0.0` | `2.0.0` | *(none)* | `2.0.0` | `2.0.0` |

The run installs .NET 10, Python 3.12 and Inno Setup 7.1.0, runs `pytest`,
builds with `build-installer.ps1`, writes `SHA256SUMS.txt`, uploads the files
to the run, and creates (or updates) the release. A tag with a channel suffix
becomes a pre-release; a bare `v2.0.0` becomes the latest release.

**Actions → Release → Run workflow** does the same by hand: it takes a version,
a channel, an optional tag, and two switches — *offline* (bundle every wheel in
the installers) and *publish* (create the release, or just keep the artifacts
on the run).

## What gets installed

```
%LOCALAPPDATA%\Programs\EmLoad
├─ app\EmLoad.WinUI.exe        WinUI 3 shell (self-contained)
├─ app\...                     .NET + Windows App SDK runtime
├─ emload\                     Python engine (source)
├─ pyproject.toml
├─ requirements.txt
├─ .venv\                      created during installation
├─ bin\emload.cmd              CLI launcher (+ emload-gui.cmd with PySide6)
└─ tools\Setup-Engine.ps1      repair / re-run helper
```

The WinUI shell's `PythonLocator` walks up from `app\`, finds `pyproject.toml`
plus `emload\` in the parent, and runs `<root>\.venv\Scripts\python.exe -m
emload rpc`. That is why the engine is flattened into the install root instead
of a subfolder.

The CLI installer uses the same root layout without `app\` and puts
`%LOCALAPPDATA%\Programs\EmLoad CLI\bin` on the user PATH.

## How the Python engine is prepared

Both installers call [Setup-Engine.ps1](Setup-Engine.ps1) during
`ssPostInstall`:

1. find a usable interpreter (`EMLOAD_PYTHON`, `py -3.12`…`py -3.10`,
   `python` on PATH, registry installs, common folders),
2. create `.venv` with it (an existing healthy venv is reused),
3. `pip install -r requirements.txt` (PySide6 filtered out when the task is
   unticked; `wheelhouse\` is used with `--no-index` when present),
4. import-test the result and write `bin\emload.cmd`.

On failure the wizard offers **Abort / Retry / Ignore**. Ignore keeps the files
so the engine can be fixed later:

```powershell
powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\Programs\EmLoad\tools\Setup-Engine.ps1" -Root "%LOCALAPPDATA%\Programs\EmLoad"
```

Exit codes: `2` no Python, `3` venv creation failed, `4` pip failed, `5`
import test failed.

The script is standalone — run it by hand to repair an install or to prepare a
portable copy.

## The script-based CLI installer

For a checkout or a custom folder, `install-cli.ps1` does what the CLI setup
does without Inno Setup:

```powershell
.\installer\install-cli.ps1                       # %LOCALAPPDATA%\Programs\EmLoad CLI
.\installer\install-cli.ps1 -SkipPySide6
.\installer\install-cli.ps1 -InstallDir D:\Tools\EmLoad
.\installer\install-cli.ps1 -Uninstall
```

It copies the engine, prepares `.venv`, writes `bin\emload.cmd`, updates the
user PATH, and registers itself in **Settings → Apps**. `install-cli.cmd` is a
double-clickable wrapper that keeps the window open on errors.

## Silent install and testing

```powershell
# install without UI; /TASKS also drives which optional deps are installed
.\dist\EmLoad-Setup-0.1.0-beta1.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART `
    /DIR="$env:TEMP\EmLoad" /TASKS="addpath" /LOG="$env:TEMP\emload-setup.log"

# smoke-test the file layout without waiting for pip
.\dist\EmLoad-Setup-0.1.0-beta1.exe /VERYSILENT /DIR="$env:TEMP\EmLoad" /SKIPENGINE=1

# uninstall
& "$env:TEMP\EmLoad\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES
```

`/SKIPENGINE=1` skips only the Python step; shortcuts and the PATH entry are
still created.

## Uninstall

The uninstaller removes `app\`, `.venv\`, `bin\`, `emload\`, `tools\` and the
PATH entry. It deliberately **keeps** `%LOCALAPPDATA%\EmLoad` — Apple ID
sessions, certificates, provisioning profiles, the sideload registry and the
logs. Delete that folder manually for a factory reset.

## Signing

The build does not sign anything. Windows SmartScreen will warn on unsigned
setup files. To sign, add a `SignTool` line to the `[Setup]` section of
`EmLoad.iss`/`EmLoadCli.iss` and pass the certificate via Inno's
`/S<name>=<command>` switch, or sign the finished `.exe` afterwards with
`signtool sign /fd sha256 /tr <timestamp-url> /td sha256 ...`.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Inno Setup was not found` | install Inno Setup 6/7 or pass `-Iscc "C:\...\ISCC.exe"` |
| Setup stops with "Python 3.10 or newer was not found" | install python.org Python (Store builds cannot create venvs) and retry |
| `pip could not install the requirements` | check the log under `%LOCALAPPDATA%\EmLoad\logs`, then re-run `tools\Setup-Engine.ps1`; build with `-Offline` for machines without internet |
| App starts then closes instantly | the shell needs `EmLoad.WinUI.pri` next to `app\EmLoad.WinUI.exe`; the publish target in the csproj adds it — rebuild with `build-installer.ps1` |
| `emload` not found in a terminal | open a new terminal (PATH changes need a fresh process) or run `%LOCALAPPDATA%\Programs\EmLoad\bin\emload.cmd` |
