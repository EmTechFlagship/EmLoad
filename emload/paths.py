"""Filesystem locations for EmLoad's cached state.

All mutable, machine-specific data (anisette provisioning, Apple session, signing
material, install registry) lives under a single per-user data directory so it is
easy to find, back up, or wipe. Nothing here is ever committed to source control.
"""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

APP_NAME = "EmLoad"


def _base_data_dir() -> Path:
    """The platform's per-user application-data root.

    - Windows: ``%LOCALAPPDATA%``
    - macOS: ``~/Library/Application Support``
    - Linux/BSD: ``$XDG_DATA_HOME`` (or ``~/.local/share``)

    ``EMLOAD_DATA_DIR`` overrides the whole location, which is handy for a
    portable install or for tests that want to keep state beside the app.
    """
    override = os.environ.get("EMLOAD_DATA_DIR")
    if override:
        return Path(override).expanduser()

    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support"
    if os.name == "nt":
        return Path(os.environ.get("LOCALAPPDATA") or (Path.home() / "AppData" / "Local"))
    return Path(os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local" / "share"))


def resource_dir() -> Path:
    """Directory of bundled package resources (certs, etc).

    Works from source and honours ``sys._MEIPASS`` for a frozen build.
    """
    if getattr(sys, "frozen", False):
        base = getattr(sys, "_MEIPASS", None)
        if base:
            return Path(base) / "emload"
    return Path(__file__).parent


def data_dir() -> Path:
    """Per-user application data directory (created if missing)."""
    path = _base_data_dir() / APP_NAME
    path.mkdir(parents=True, exist_ok=True)
    return path


def anisette_dir() -> Path:
    """Directory holding the cached anisette libraries + provisioning state."""
    path = data_dir() / "anisette"
    path.mkdir(parents=True, exist_ok=True)
    return path


def anisette_state_file() -> Path:
    """Combined anisette state (portable libs + provisioning) as one file."""
    return anisette_dir() / "anisette.bin"


def session_dir() -> Path:
    """Directory holding Apple account sessions + pending 2FA state."""
    path = data_dir() / "session"
    path.mkdir(parents=True, exist_ok=True)
    return path


def pending_2fa_file() -> Path:
    """Transient state between triggering and submitting a 2FA code."""
    return session_dir() / "pending.json"


def accounts_dir() -> Path:
    """One file per signed-in Apple ID. Never committed."""
    path = session_dir() / "accounts"
    path.mkdir(parents=True, exist_ok=True)
    return path


def account_slug(email: str) -> str:
    """A stable, filesystem-safe name for an account's file (hashed, not exposed)."""
    return hashlib.sha256(email.strip().lower().encode("utf-8")).hexdigest()[:16]


def account_file(email: str) -> Path:
    """Authenticated GSA session for one Apple ID (adsid + tokens)."""
    return accounts_dir() / f"{account_slug(email)}.json"


def active_account_file() -> Path:
    """Which signed-in account commands act on by default."""
    return session_dir() / "active.json"


def signing_dir(account_slug_: str | None = None) -> Path:
    """Signing material (private key, cert, profile, p12), scoped per account."""
    path = data_dir() / "signing"
    if account_slug_:
        path = path / account_slug_
    path.mkdir(parents=True, exist_ok=True)
    return path


def signed_dir() -> Path:
    """Directory holding signed IPAs the user asked to keep."""
    path = data_dir() / "signed"
    path.mkdir(parents=True, exist_ok=True)
    return path


def installs_file() -> Path:
    """Registry of apps this machine has sideloaded (for expiry + refresh)."""
    return data_dir() / "sideloads.json"


def zsign_dir() -> Path:
    """Directory holding the downloaded zsign binary."""
    path = data_dir() / "bin"
    path.mkdir(parents=True, exist_ok=True)
    return path


def zsign_file() -> Path:
    return zsign_dir() / ("zsign.exe" if os.name == "nt" else "zsign")


def tls_dir() -> Path:
    path = data_dir() / "tls"
    path.mkdir(parents=True, exist_ok=True)
    return path


def config_file() -> Path:
    """User settings (connection preference, signed folder, ...) as JSON."""
    return data_dir() / "config.json"