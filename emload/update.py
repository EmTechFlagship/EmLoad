"""Over-the-air updates from GitHub releases, starting with 0.1.0 RC 1.

RC 1 is the first EmLoad that looks for a newer release (including
pre-releases) when the app opens. Releases tagged before ``0.1.0-rc1``,
including the betas, are ignored.

Windows installs replace themselves:

- a Setup install runs ``EmLoad-Setup-<version>.exe`` (or the CLI setup) silently
- a portable folder copies ``EmLoad-<version>-win-x64.zip`` over itself

The running process cannot overwrite its own files, so the download is handed
to a detached PowerShell script that waits for EmLoad to quit, applies the
update, and opens the new build. A source checkout only reports the release.
The macOS app applies its own update; this module still describes that release
for ``emload update``.
"""

from __future__ import annotations

import os
import platform
import re
import subprocess
import sys
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

import requests

from . import __version__, paths
from .errors import EmLoadError

REPOSITORY = "EmTechFlagship/EmLoadServer"
_RELEASES_URL = f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=30"
_RELEASE_PAGE = f"https://github.com/{REPOSITORY}/releases/tag/"

#: OTA begins here. Anything older is not offered and not installed.
OTA_SINCE_TEXT = "0.1.0-rc1"

_VERSION_RE = re.compile(
    r"^v?(\d+)\.(\d+)\.(\d+)(?:[.\-]?((?:alpha)|(?:beta)|(?:preview)|(?:rc)|a|b)(\d+))?$",
    re.IGNORECASE,
)
_KIND_NAMES = {
    "a": "alpha",
    "alpha": "alpha",
    "b": "beta",
    "beta": "beta",
    "preview": "preview",
    "rc": "rc",
}
_KIND_RANK = {"alpha": 0, "beta": 1, "preview": 2, "rc": 3}

_REDIRECT_HOSTS = {
    "github.com",
    "www.github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
    "github-releases.githubusercontent.com",
}

ProgressFn = Callable[[str, Any, str | None], None]


@dataclass(frozen=True)
class ReleaseVersion:
    """A release such as ``0.1.0-rc1``. A final release has ``kind is None``."""

    major: int
    minor: int
    patch: int
    kind: str | None = None
    number: int = 0

    def __str__(self) -> str:
        core = f"{self.major}.{self.minor}.{self.patch}"
        if self.kind is None:
            return core
        return f"{core}-{self.kind}{self.number}"

    def __lt__(self, other: ReleaseVersion) -> bool:
        core = (self.major, self.minor, self.patch)
        theirs = (other.major, other.minor, other.patch)
        if core != theirs:
            return core < theirs
        if self.kind is None and other.kind is None:
            return False
        # A final release is newer than any pre-release of the same core.
        if self.kind is None:
            return False
        if other.kind is None:
            return True
        left = (_KIND_RANK.get(self.kind, 1), self.kind, self.number)
        right = (_KIND_RANK.get(other.kind, 1), other.kind, other.number)
        return left < right

    def __le__(self, other: ReleaseVersion) -> bool:
        return self == other or self < other

    def __gt__(self, other: ReleaseVersion) -> bool:
        return other < self

    def __ge__(self, other: ReleaseVersion) -> bool:
        return other == self or other < self


OTA_SINCE = ReleaseVersion(0, 1, 0, "rc", 1)


def parse_version(raw: str) -> ReleaseVersion | None:
    """Parse ``v0.1.0-rc1``, ``0.1.0rc1``, or ``0.1.0``. ``None`` if it does not match."""
    text = raw.strip()
    match = _VERSION_RE.match(text)
    if match is None:
        return None
    kind_raw = match.group(4)
    kind = _KIND_NAMES[kind_raw.lower()] if kind_raw else None
    number = int(match.group(5) or 0)
    return ReleaseVersion(int(match.group(1)), int(match.group(2)), int(match.group(3)), kind, number)


def current_version() -> ReleaseVersion:
    """The engine version shipped in this build."""
    parsed = parse_version(__version__)
    if parsed is None:
        raise EmLoadError(f"EmLoad's version {__version__!r} is not a release version.")
    return parsed


def check() -> dict[str, Any]:
    """The newest applicable GitHub release, or ``update: null`` when none is newer."""
    current = current_version()
    releases = fetch_releases()
    found = select_update(
        releases,
        current=current,
        layout=describe_layout(install_root()),
        platform_name=sys.platform,
        architecture=_mac_architecture(),
    )
    return {"current": str(current), "update": found}


def apply(
    host_pid: int | None = None,
    on_progress: ProgressFn | None = None,
) -> dict[str, Any]:
    """Download the newer Windows build and hand it to a detached installer.

    Returns ``status: relaunching`` once the helper is running. The caller
    should then quit so the helper can replace the files and open EmLoad.
    ``status: manual`` means this copy cannot replace itself; ``html_url`` is
    the release page.
    """
    report = check()
    found = report.get("update")
    if not found:
        raise EmLoadError(f"EmLoad {report['current']} is already up to date.")
    if not found.get("can_apply"):
        return {
            "status": "manual",
            "current": report["current"],
            "version": found["version"],
            "html_url": found["html_url"],
        }

    version = parse_version(str(found["version"]))
    if version is None or version < OTA_SINCE or version <= current_version():
        raise EmLoadError("That release is not an EmLoad update.")

    layout = str(found["layout"])
    download_url = str(found["download_url"])
    asset_name = str(found["asset_name"])
    destination = update_dir() / _safe_asset_name(asset_name)
    _download(download_url, destination, asset_name, on_progress)

    root = install_root()
    pids = []
    if host_pid and int(host_pid) > 0 and int(host_pid) != os.getpid():
        pids.append(int(host_pid))
    pids.append(os.getpid())
    relaunch = _relaunch_path(root, layout)
    script_text = render_windows_script(
        mode="portable" if layout == "portable" else "installer",
        pids=pids,
        payload=destination,
        install_dir=root,
        relaunch=relaunch,
        log_path=update_dir() / "update.log",
        wait_for_app=layout != "installed_cli",
    )
    script_path = update_dir() / "apply-update.ps1"
    script_path.write_text(script_text, encoding="utf-8")
    _spawn_detached(script_path)
    if on_progress:
        on_progress("install", 100, "Installing and reopening…")
    return {
        "status": "relaunching",
        "current": report["current"],
        "version": found["version"],
        "asset_name": asset_name,
    }


def fetch_releases() -> list[dict[str, Any]]:
    """The recent GitHub releases for this repository."""
    try:
        response = requests.get(
            _RELEASES_URL,
            timeout=20,
            headers={
                "User-Agent": "EmLoad",
                "Accept": "application/vnd.github+json",
            },
        )
    except requests.RequestException as exc:
        raise EmLoadError(f"Could not reach GitHub to check for updates. {exc}") from exc
    if response.status_code >= 400:
        message = ""
        try:
            body = response.json()
            if isinstance(body, dict):
                message = str(body.get("message") or "")
        except ValueError:
            message = ""
        detail = message or f"GitHub returned HTTP {response.status_code} while checking for updates."
        raise EmLoadError(detail)
    try:
        payload = response.json()
    except ValueError as exc:
        raise EmLoadError("GitHub returned an unexpected release list.") from exc
    return parse_releases(payload)


def parse_releases(payload: Any) -> list[dict[str, Any]]:
    """Normalize a GitHub releases JSON document. Raises if GitHub returned an error object."""
    if isinstance(payload, dict):
        message = payload.get("message") or "GitHub returned an unexpected response."
        raise EmLoadError(str(message))
    if not isinstance(payload, list):
        raise EmLoadError("GitHub returned an unexpected release list.")
    releases: list[dict[str, Any]] = []
    for row in payload:
        parsed = _parse_release(row)
        if parsed is not None:
            releases.append(parsed)
    return releases


def select_update(
    releases: list[dict[str, Any]],
    *,
    current: ReleaseVersion,
    layout: str,
    platform_name: str,
    architecture: str,
) -> dict[str, Any] | None:
    """The newest release at or after RC 1 that is newer than ``current``.

    Prefers a release that has an asset this machine can install. When a newer
    tag has no asset for the platform, an older tag that does is used. When
    nothing can be installed automatically, the newest release is still returned
    with ``can_apply`` false so the app can open the release page.
    """
    ranked: list[tuple[ReleaseVersion, dict[str, Any]]] = []
    for release in releases:
        if release.get("draft"):
            continue
        version = parse_version(str(release.get("tag") or ""))
        if version is None or version < OTA_SINCE or not version > current:
            continue
        ranked.append((version, release))
    ranked.sort(key=lambda item: item[0], reverse=True)

    fallback: dict[str, Any] | None = None
    for version, release in ranked:
        page = _release_page(str(release["tag"]), str(release.get("html_url") or ""))
        described = _describe(version, release, page, layout, can_apply=False, asset=None)
        if fallback is None:
            fallback = described
        asset = choose_asset(
            release.get("assets") or [],
            platform_name=platform_name,
            layout=layout,
            architecture=architecture,
        )
        if asset is None or not is_trusted_download(str(asset.get("url") or "")):
            continue
        return _describe(
            version,
            release,
            page,
            layout,
            can_apply=_can_apply(layout, platform_name),
            asset=asset,
        )
    return fallback


def choose_asset(
    assets: list[dict[str, str]],
    *,
    platform_name: str,
    layout: str,
    architecture: str,
) -> dict[str, str] | None:
    """The archive or installer for this operating system, or ``None``."""
    if platform_name == "win32":
        return _windows_asset(assets, layout)
    if platform_name == "darwin":
        return _macos_asset(assets, architecture)
    return None


def describe_layout(root: Path) -> str:
    """How this copy of EmLoad was installed, based on the files next to the engine.

    ``installed_app`` is the WinUI setup, ``installed_cli`` is the command-line
    setup, ``portable`` is the zip, and ``source`` is a checkout.
    """
    if (root / "app" / "EmLoad.WinUI.exe").is_file() and (root / "unins000.exe").is_file():
        return "installed_app"
    if (root / "unins000.exe").is_file():
        return "installed_cli"
    if (root / "EmLoad.WinUI.exe").is_file():
        return "portable"
    return "source"


def install_root() -> Path:
    """Directory that contains ``emload/`` and, for an install, the app files."""
    return Path(__file__).resolve().parents[1]


def is_trusted_download(url: str) -> bool:
    """True when ``url`` is an HTTPS asset on this repository's release."""
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or host not in {"github.com", "www.github.com"}:
        return False
    path = urllib.parse.unquote(parsed.path)
    marker = f"/{REPOSITORY}/releases/download/"
    return marker in path and ".." not in path.split("/")


def render_windows_script(
    *,
    mode: str,
    pids: list[int],
    payload: Path,
    install_dir: Path,
    relaunch: Path | None,
    log_path: Path,
    wait_for_app: bool,
) -> str:
    """PowerShell that waits for EmLoad to exit, then installs ``payload``."""
    if mode not in {"installer", "portable"}:
        raise EmLoadError(f"Unknown update mode {mode!r}.")
    pid_list = ",".join(str(int(pid)) for pid in pids)
    relaunch_text = "" if relaunch is None else str(relaunch)
    common = f"""$ErrorActionPreference = 'Stop'
$log = {_ps(str(log_path))}
$payload = {_ps(str(payload))}
$dest = {_ps(str(install_dir))}
$relaunch = {_ps(relaunch_text)}
$pids = @({pid_list})
function Wait-Pid([int]$procId) {{
  if ($procId -le 0) {{ return }}
  while (Get-Process -Id $procId -ErrorAction SilentlyContinue) {{
    Start-Sleep -Milliseconds 200
  }}
}}
Start-Transcript -Path $log -Force | Out-Null
try {{
  foreach ($procId in $pids) {{ Wait-Pid $procId }}
  Start-Sleep -Milliseconds 400
"""
    if wait_for_app:
        common += """  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Process -Name 'EmLoad.WinUI' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
  }
"""
    if mode == "installer":
        body = """  $setupLog = Join-Path (Split-Path -Parent $log) 'setup.log'
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $payload
  $psi.Arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /DIR=`"$dest`" /LOG=`"$setupLog`""
  $psi.UseShellExecute = $false
  $proc = [System.Diagnostics.Process]::Start($psi)
  $proc.WaitForExit()
  if ($proc.ExitCode -ne 0) { throw "The installer exited with $($proc.ExitCode)." }
"""
    else:
        body = r"""  $stage = Join-Path $env:TEMP ("EmLoadUpdate-" + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Expand-Archive -LiteralPath $payload -DestinationPath $stage -Force
  $exe = Get-ChildItem -LiteralPath $stage -Filter 'EmLoad.WinUI.exe' -Recurse -File | Select-Object -First 1
  if (-not $exe) { throw 'The update archive does not contain EmLoad.WinUI.exe.' }
  $source = $exe.DirectoryName
  $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
  & $robocopy $source $dest /E /XD .venv /R:2 /W:1 /NFL /NDL /NJH /NJS
  if ($LASTEXITCODE -ge 8) { throw "Could not copy the update (robocopy $LASTEXITCODE)." }
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
"""
    ending = """  if ($relaunch -and (Test-Path -LiteralPath $relaunch)) {
    Start-Process -FilePath $relaunch
  }
} catch {
  $_ | Out-String | Write-Output
  throw
} finally {
  Stop-Transcript | Out-Null
}
"""
    return common + body + ending


def update_dir() -> Path:
    directory = paths.data_dir() / "update"
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def _describe(
    version: ReleaseVersion,
    release: dict[str, Any],
    page: str,
    layout: str,
    *,
    can_apply: bool,
    asset: dict[str, str] | None,
) -> dict[str, Any]:
    title = str(release.get("name") or "").strip() or f"EmLoad {version}"
    return {
        "tag": release["tag"],
        "title": title,
        "notes": _notes(str(release.get("body") or "")),
        "html_url": page,
        "asset_name": "" if asset is None else asset["name"],
        "download_url": "" if asset is None else asset["url"],
        "version": str(version),
        "prerelease": bool(release.get("prerelease")),
        "can_apply": can_apply,
        "layout": layout,
    }


def _can_apply(layout: str, platform_name: str) -> bool:
    return platform_name == "win32" and layout in {"installed_app", "installed_cli", "portable"}


def _windows_asset(assets: list[dict[str, str]], layout: str) -> dict[str, str] | None:
    if layout == "installed_cli":
        return _prefer(
            assets,
            lambda name: name.startswith("emload-cli-setup-") and name.endswith(".exe"),
        )
    if layout == "portable":
        return _prefer(
            assets,
            lambda name: name.endswith("-win-x64.zip") and "setup" not in name,
        )
    # installed_app and a source checkout both point at the desktop setup.
    return _prefer(
        assets,
        lambda name: name.startswith("emload-setup-") and name.endswith(".exe") and "cli" not in name,
    )


def _macos_asset(assets: list[dict[str, str]], architecture: str) -> dict[str, str] | None:
    zips = [asset for asset in assets if _is_mac_zip(asset.get("name", ""))]
    suffix = f"-macos-{architecture}.zip"
    for asset in zips:
        if asset["name"].lower().endswith(suffix):
            return asset
    for asset in zips:
        if asset["name"].lower().endswith("-macos.zip"):
            return asset
    for asset in zips:
        name = asset["name"].lower()
        if "arm64" in name or "aarch64" in name:
            if architecture == "arm64":
                return asset
            continue
        if "x86_64" in name or "intel" in name:
            if architecture == "x86_64":
                return asset
            continue
        return asset
    return None


def _prefer(
    assets: list[dict[str, str]],
    predicate: Callable[[str], bool],
) -> dict[str, str] | None:
    matches = [asset for asset in assets if predicate(asset.get("name", "").lower())]
    return matches[0] if matches else None


def _is_mac_zip(name: str) -> bool:
    lower = name.lower()
    return lower.endswith(".zip") and "macos" in lower and "win" not in lower


def _parse_release(row: Any) -> dict[str, Any] | None:
    if not isinstance(row, dict) or not isinstance(row.get("tag_name"), str):
        return None
    assets: list[dict[str, str]] = []
    for asset in row.get("assets") or []:
        if not isinstance(asset, dict):
            continue
        name = asset.get("name")
        url = asset.get("browser_download_url")
        if isinstance(name, str) and isinstance(url, str):
            assets.append({"name": name, "url": url})
    return {
        "tag": row["tag_name"],
        "name": row.get("name") if isinstance(row.get("name"), str) else "",
        "body": row.get("body") if isinstance(row.get("body"), str) else "",
        "prerelease": bool(row.get("prerelease")),
        "draft": bool(row.get("draft")),
        "html_url": row.get("html_url") if isinstance(row.get("html_url"), str) else "",
        "assets": assets,
    }


def _release_page(tag: str, html_url: str) -> str:
    parsed = urllib.parse.urlparse(html_url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme == "https" and host in {"github.com", "www.github.com"}:
        if parsed.path.startswith(f"/{REPOSITORY}/"):
            return html_url
    return _RELEASE_PAGE + tag


def _notes(body: str) -> str:
    trimmed = body.replace("\r\n", "\n").strip()
    if len(trimmed) <= 700:
        return trimmed
    return trimmed[:700].rstrip() + "…"


def _safe_asset_name(name: str) -> str:
    cleaned = Path(name).name
    if not cleaned or cleaned in {".", ".."}:
        raise EmLoadError("The update asset name is not a file name.")
    return cleaned


def _relaunch_path(root: Path, layout: str) -> Path | None:
    if layout == "installed_app":
        return root / "app" / "EmLoad.WinUI.exe"
    if layout == "portable":
        return root / "EmLoad.WinUI.exe"
    return None


def _mac_architecture() -> str:
    machine = platform.machine().lower()
    return "arm64" if machine in {"arm64", "aarch64"} else "x86_64"


def _download(url: str, destination: Path, asset_name: str, on_progress: ProgressFn | None) -> None:
    if not is_trusted_download(url):
        raise EmLoadError("The update link is not a GitHub release asset.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".part")
    try:
        with requests.get(
            url,
            stream=True,
            timeout=60,
            headers={"User-Agent": "EmLoad"},
            allow_redirects=True,
        ) as response:
            _reject_untrusted_hops(url, response)
            if response.status_code >= 400:
                raise EmLoadError(
                    f"GitHub returned HTTP {response.status_code} while downloading the update."
                )
            total = int(response.headers.get("Content-Length") or 0)
            written = 0
            with partial.open("wb") as handle:
                for chunk in response.iter_content(chunk_size=256 * 1024):
                    if not chunk:
                        continue
                    handle.write(chunk)
                    written += len(chunk)
                    if on_progress and total > 0:
                        percent = min(100, int(written * 100 / total))
                        on_progress("download", percent, f"Downloading {asset_name}")
    except requests.RequestException as exc:
        partial.unlink(missing_ok=True)
        raise EmLoadError(f"Could not download the update. {exc}") from exc
    except EmLoadError:
        partial.unlink(missing_ok=True)
        raise
    partial.replace(destination)
    if on_progress:
        on_progress("download", 100, f"Downloaded {asset_name}")


def _reject_untrusted_hops(original: str, response: requests.Response) -> None:
    hops = [original, *[item.url for item in response.history], response.url]
    for hop in hops:
        parsed = urllib.parse.urlparse(hop)
        host = (parsed.hostname or "").lower()
        if parsed.scheme != "https" or host not in _REDIRECT_HOSTS:
            raise EmLoadError("The update download was redirected away from GitHub.")


def _spawn_detached(script_path: Path) -> None:
    if sys.platform != "win32":
        raise EmLoadError("EmLoad can only apply an update automatically on Windows.")
    flags = 0x00000008 | 0x00000200  # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    breakaway = flags | 0x01000000
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-WindowStyle",
        "Hidden",
        "-File",
        str(script_path),
    ]
    try:
        subprocess.Popen(  # noqa: S603 - fixed powershell path plus the script we just wrote
            command,
            creationflags=breakaway,
            close_fds=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        subprocess.Popen(  # noqa: S603
            command,
            creationflags=flags,
            close_fds=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def _ps(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"
