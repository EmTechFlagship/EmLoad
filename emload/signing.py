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
import shutil
import subprocess
import sys
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
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)
    found = shutil.which("zsign")
    if found:
        return found
    raise SigningError(
        "zsign not found. Run 'emload setup' to download it, set EM_ZSIGN, or "
        "place zsign.exe in vendor/."
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


def zsign_download_urls() -> list[str]:
    """Candidate URLs for a prebuilt Windows zsign, newest release first."""
    urls: list[str] = []
    tag = _latest_zsign_tag()
    if tag:
        urls.append(
            f"https://nightly.link/zhlynn/zsign/workflows/build/{tag}/"
            "zsign-windows-x64.zip"
        )
    urls.extend(ZSIGN_DOWNLOAD_URLS)
    return urls


def download_zsign(urls: list[str] | None = None) -> dict[str, Any]:
    """Download a prebuilt zsign into the data dir; returns a status report."""
    attempts: list[str] = []
    dest = paths.zsign_file()
    for url in urls or zsign_download_urls():
        try:
            response = requests.get(url, timeout=120)
            response.raise_for_status()
            data = response.content
            if data[:2] == b"PK":  # a zip - extract zsign.exe
                with zipfile.ZipFile(io.BytesIO(data)) as zf:
                    names = zf.namelist()
                    target = next(
                        (n for n in names if n.lower().endswith("zsign.exe")), None
                    )
                    if target is None:
                        raise ValueError("archive contains no zsign.exe")
                    dest.write_bytes(zf.read(target))
            else:
                dest.write_bytes(data)
            dest.chmod(0o755)
            version = zsign_version()
            if version is None:
                dest.unlink(missing_ok=True)
                raise ValueError("downloaded binary does not run")
            return {"status": "ok", "path": str(dest), "version": version, "source": url}
        except Exception as exc:  # noqa: BLE001 - record every source that failed
            attempts.append(f"{url}: {exc}")
    raise SigningError(
        "Could not download zsign. Tried:\n  " + "\n  ".join(attempts)
        + "\n\nBuild it from https://github.com/zhlynn/zsign and set EM_ZSIGN "
        "to the binary, or drop it in vendor/."
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