"""Signing-material crypto helpers and the zsign wrapper.

Generates the RSA keypair + PKCS#10 CSR sent to Apple to obtain a development
certificate, and assembles the resulting certificate plus the (locally-held)
private key into a PKCS#12 bundle that zsign consumes at sign time. Apple never
sees the private key; it lives only on this machine.

zsign is a fast C++ iOS code-signing tool (https://github.com/zhlynn/zsign).
EmLoad locates it via (in order): the ``EMLOAD_ZSIGN`` environment variable, a
``vendor/zsign(.exe)`` next to the package, the per-user data dir (where
``emload setup`` downloads it), and the PATH. ``emload setup`` can fetch a
prebuilt binary; otherwise build zsign and point ``EMLOAD_ZSIGN`` at it.
"""

from __future__ import annotations

import io
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path
from typing import Any

import requests
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

from . import paths
from .errors import EmLoadError

P12_PASSWORD = "EmLoad"

#: Where ``emload setup`` tries to fetch a prebuilt zsign, in order.
#: The first entry is GitHub Actions' artifact mirror for zhlynn/zsign's
#: "Build Multi-Platform" workflow (zsign-windows-x64 artifact).
ZSIGN_DOWNLOAD_URLS: tuple[str, ...] = (
    "https://nightly.link/zhlynn/zsign/workflows/build/master/zsign-windows-x64.zip",
)


class SigningError(EmLoadError):
    """Raised when zsign fails to sign an IPA, or is missing."""


def generate_key_and_csr(common_name: str = "EmLoad") -> tuple[bytes, str]:
    """Return (private_key_pem, csr_pem) for a fresh RSA-2048 development key."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)]))
        .sign(key, hashes.SHA256())
    )
    key_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    )
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    return key_pem, csr_pem


def build_p12(cert_der: bytes, key_pem: bytes, password: str = P12_PASSWORD) -> bytes:
    """Bundle a DER certificate + PEM private key into a PKCS#12 blob for zsign."""
    key = serialization.load_pem_private_key(key_pem, password=None)
    cert = x509.load_der_x509_certificate(cert_der)
    encryption = (
        serialization.BestAvailableEncryption(password.encode())
        if password
        else serialization.NoEncryption()
    )
    return pkcs12.serialize_key_and_certificates(b"EmLoad", key, cert, None, encryption)


# --------------------------------------------------------------------------- #
# zsign resolution + setup
# --------------------------------------------------------------------------- #
def resolve_zsign() -> str:
    """Locate the zsign binary: env override, bundled vendor copy, data dir, PATH."""
    override = os.environ.get("EMLOAD_ZSIGN")
    if override and Path(override).exists():
        return override
    exe = "zsign.exe" if os.name == "nt" else "zsign"
    candidates = [
        paths.resource_dir() / "vendor" / exe,  # bundled next to the package
        Path(sys.executable).parent / exe,       # alongside a frozen app
        paths.zsign_file(),                       # downloaded by `emload setup`
    ]
    # Homebrew is not always on a GUI app's PATH (especially /opt/homebrew/bin),
    # so check its two standard prefixes explicitly.
    if sys.platform == "darwin":
        candidates.extend(
            Path(prefix) / exe for prefix in ("/opt/homebrew/bin", "/usr/local/bin")
        )
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)
    found = shutil.which("zsign")
    if found:
        return found
    if sys.platform == "darwin":
        raise SigningError(
            "zsign not found. Run 'emload setup' (it downloads the official "
            "build, or compiles zsign for Intel and Apple silicon), set "
            "EMLOAD_ZSIGN, or place a zsign binary in vendor/."
        )
    raise SigningError(
        "zsign not found. Run 'emload setup' to download it, set EM_ZSIGN, or "
        "place zsign in vendor/."
    )


def zsign_version() -> str | None:
    """Return zsign's version string, or None if it cannot be run."""
    try:
        proc = subprocess.run(
            [resolve_zsign(), "-v"], capture_output=True, text=True, timeout=15
        )
        output = (proc.stdout or proc.stderr or "").strip()
        return output or None
    except Exception:  # noqa: BLE001 - probing should never raise
        return None


#: Fallback URLs for a prebuilt Windows zsign (GitHub Actions artifact mirror).
ZSIGN_DOWNLOAD_URLS: tuple[str, ...] = (
    "https://nightly.link/zhlynn/zsign/workflows/build/v1.1.2/zsign-windows-x64.zip",
)

_GITHUB_API = "https://api.github.com/repos/zhlynn/zsign/releases/latest"
_GITHUB_RELEASES = "https://github.com/zhlynn/zsign/releases"


def _latest_zsign_tag() -> str | None:
    """The newest released zsign tag (``v1.x.y``), or None if GitHub is unreachable."""
    try:
        response = requests.get(
            _GITHUB_API, timeout=20, headers={"User-Agent": "EmLoad"}
        )
        response.raise_for_status()
        tag = response.json().get("tag_name")
        return tag if isinstance(tag, str) and tag.startswith("v") else None
    except Exception:  # noqa: BLE001 - the hardcoded fallback URLs still apply
        return None


def _release_url(tag: str | None, asset: str) -> str:
    """A zsign GitHub release asset URL, using ``latest`` when the tag is unknown."""
    if tag:
        return f"{_GITHUB_RELEASES}/download/{tag}/{asset}"
    return f"{_GITHUB_RELEASES}/latest/download/{asset}"


def _macos_arch() -> str:
    """``arm64`` or ``x86_64`` for the running Mac."""
    machine = platform.machine().lower()
    return "arm64" if machine in ("arm64", "aarch64") else "x86_64"


def zsign_download_urls() -> list[str]:
    """Candidate URLs for a prebuilt zsign, newest release first.

    zsign publishes a macOS arm64 tarball, Linux tarballs for x86_64/aarch64,
    and a Windows zip. There is no official Intel-macOS build; ``emload setup``
    compiles one from source on macOS (see :func:`download_zsign`).
    """
    tag = _latest_zsign_tag()
    urls: list[str] = []

    if sys.platform == "darwin":
        if _macos_arch() == "arm64":
            urls.append(_release_url(tag, "zsign-macos-arm64.tar.gz"))
        return urls

    if sys.platform.startswith("linux"):
        asset = (
            "zsign-linux-aarch64.tar.gz"
            if platform.machine().lower() in ("arm64", "aarch64")
            else "zsign-linux-x86_64.tar.gz"
        )
        urls.append(_release_url(tag, asset))
        return urls

    # Windows: a release zip is now published; nightly.link remains the fallback
    # for tags whose release assets have not finished uploading yet.
    if tag:
        urls.append(_release_url(tag, "zsign-windows-x64.zip"))
    urls.extend(ZSIGN_DOWNLOAD_URLS)
    return urls


def _extract_zsign(data: bytes, dest: Path) -> None:
    """Write the zsign binary from a raw, ZIP, or tar.gz response body."""
    if data[:2] == b"PK":  # a zip - extract the binary
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            target = next(
                (
                    n for n in zf.namelist()
                    if Path(n).name.lower() in ("zsign.exe", "zsign")
                ),
                None,
            )
            if target is None:
                raise ValueError("archive contains no zsign binary")
            dest.write_bytes(zf.read(target))
        return

    if data[:2] == b"\x1f\x8b":  # tar.gz - read the member into memory
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
            member = next(
                (
                    m for m in tf.getmembers()
                    if m.isfile() and Path(m.name).name in ("zsign", "zsign-musl")
                ),
                None,
            )
            if member is None:
                raise ValueError("archive contains no zsign binary")
            extracted = tf.extractfile(member)
            if extracted is None:
                raise ValueError("archive member could not be read")
            dest.write_bytes(extracted.read())
        return

    dest.write_bytes(data)


def _macos_zsign_build_script() -> Path | None:
    """The macOS script that compiles zsign for x86_64 and arm64."""
    candidates: list[Path] = []
    override = os.environ.get("EMLOAD_ZSIGN_SCRIPT")
    if override:
        candidates.append(Path(override))
    root = Path(__file__).resolve().parents[1]
    candidates.append(root / "gui-macos" / "scripts" / "build-zsign.sh")
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def _compile_zsign(dest: Path) -> None:
    """Compile zsign into ``dest``. Raises if the macOS build script fails."""
    script = _macos_zsign_build_script()
    if script is None:
        raise FileNotFoundError("gui-macos/scripts/build-zsign.sh")
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(script), "-o", str(dest)], check=True, timeout=1800)


def _install_zsign_with_brew() -> str | None:
    """Install Homebrew's zsign on macOS and return its path (or None)."""
    if sys.platform != "darwin":
        return None
    brew = next(
        (
            str(path)
            for path in (
                Path("/opt/homebrew/bin/brew"),
                Path("/usr/local/bin/brew"),
            )
            if path.exists()
        ),
        shutil.which("brew"),
    )
    if not brew:
        return None
    env = {**os.environ, "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"}
    try:
        subprocess.run(
            [brew, "install", "zsign"],
            check=True,
            capture_output=True,
            text=True,
            timeout=900,
            env=env,
        )
        prefix = subprocess.run(
            [brew, "--prefix", "zsign"],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
            env=env,
        ).stdout.strip()
        candidates = [
            Path(prefix) / "bin" / "zsign",
            Path("/opt/homebrew/bin/zsign"),
            Path("/usr/local/bin/zsign"),
        ]
        for candidate in candidates:
            if candidate.exists():
                return str(candidate)
    except (OSError, subprocess.SubprocessError):
        return None
    return None


def download_zsign(urls: list[str] | None = None) -> dict[str, Any]:
    """Download a prebuilt zsign into the data dir; returns a status report.

    On macOS, a failed download (including Intel, which has no upstream
    binary) is followed by a source build, then Homebrew's ``zsign`` formula.
    """
    attempts: list[str] = []
    dest = paths.zsign_file()
    for url in urls or zsign_download_urls():
        try:
            response = requests.get(url, timeout=120)
            response.raise_for_status()
            _extract_zsign(response.content, dest)
            dest.chmod(0o755)
            version = zsign_version()
            if version is None:
                dest.unlink(missing_ok=True)
                raise ValueError("downloaded binary does not run")
            return {"status": "ok", "path": str(dest), "version": version, "source": url}
        except Exception as exc:  # noqa: BLE001 - record every source that failed
            attempts.append(f"{url}: {exc}")

    if sys.platform == "darwin":
        try:
            _compile_zsign(dest)
            dest.chmod(0o755)
            version = zsign_version()
            if version is None:
                dest.unlink(missing_ok=True)
                raise ValueError("compiled binary does not run")
            return {"status": "ok", "path": str(dest), "version": version, "source": "source"}
        except Exception as exc:  # noqa: BLE001 - Homebrew is the remaining fallback
            attempts.append(f"compile: {exc}")

    brew_path = _install_zsign_with_brew()
    if brew_path:
        version = zsign_version()
        return {
            "status": "ok",
            "path": brew_path,
            "version": version,
            "source": "homebrew",
        }

    detail = "\n  ".join(attempts) if attempts else "no prebuilt binary for this platform"
    hint = (
        "On macOS, ./gui-macos/scripts/build-zsign.sh compiles zsign for Intel "
        "and Apple silicon. You can also 'brew install zsign' or set EMLOAD_ZSIGN."
        if sys.platform == "darwin"
        else
        "Build it from https://github.com/zhlynn/zsign and set EMLOAD_ZSIGN to the "
        "binary, or drop it in vendor/."
    )
    raise SigningError(
        f"Could not download zsign. Tried:\n  {detail}\n\n{hint}"
    )


# --------------------------------------------------------------------------- #
# IPA signing
# --------------------------------------------------------------------------- #
def sign_ipa(
    input_ipa: str,
    output_ipa: str,
    *,
    p12_path: str,
    p12_password: str,
    profile_path: str,
    bundle_id: str | None = None,
    display_name: str | None = None,
    bundle_version: str | None = None,
    remove_extensions: bool = True,
    remove_watch: bool = True,
    remove_uisd: bool = True,
    enable_file_sharing: bool = False,
    entitlements: str | None = None,
    zip_level: int = 6,
    temp_folder: str | None = None,
) -> dict[str, Any]:
    """Re-sign an IPA with zsign (SHA256 CodeDirectory + DER entitlements).

    ``temp_folder`` is where zsign unpacks the IPA and assembles the signed copy -
    by far the heaviest I/O of a sideload. It must already exist: zsign rejects a
    missing temp folder outright.
    """
    zsign = resolve_zsign()
    cmd = [
        zsign,
        "-k", p12_path,
        "-p", p12_password,
        "-m", profile_path,
        "-z", str(zip_level),
        "-o", output_ipa,
    ]
    if temp_folder:
        cmd += ["-t", temp_folder]
    if bundle_id:
        cmd += ["-b", bundle_id]
    if display_name:
        cmd += ["-n", display_name]
    if bundle_version:
        cmd += ["-r", bundle_version]
    if remove_extensions:
        cmd.append("-E")
    if remove_watch:
        cmd.append("-W")
    if remove_uisd:
        cmd.append("-U")
    if enable_file_sharing:
        cmd.append("-S")
    if entitlements:
        cmd += ["-e", entitlements]
    cmd.append(input_ipa)

    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SigningError(
            f"zsign failed (exit {proc.returncode}):\n{proc.stdout}\n{proc.stderr}"
        )
    return {"output": output_ipa, "log": proc.stdout}


def signing_status() -> dict[str, Any]:
    """Report whether zsign is available and where from."""
    try:
        path = resolve_zsign()
        return {
            "available": True,
            "path": path,
            "version": zsign_version(),
        }
    except SigningError as exc:
        return {"available": False, "error": str(exc)}