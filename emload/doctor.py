"""Environment readiness checks (the ``emload doctor`` command).

Checks everything a sideload needs, one item at a time, and reports each as
ok/error/warn with an actionable message. The GUI shows the same report on its
Diagnostics page.
"""

from __future__ import annotations

import os
import platform
import sys
from importlib import metadata
from typing import Any

from . import anisette, device, paths, signing


def _pkg_version(name: str) -> str | None:
    try:
        return metadata.version(name)
    except metadata.PackageNotFoundError:
        return None


def check() -> list[dict[str, Any]]:
    """Return a list of ``{name, status, message}`` checks."""
    results: list[dict[str, Any]] = []

    # Python
    results.append(
        {
            "name": "Python",
            "status": "ok",
            "message": f"{platform.python_version()} ({sys.executable})",
        }
    )

    # Core packages
    missing = [
        name for name in ("pymobiledevice3", "Anisette", "srp", "cryptography")
        if _pkg_version(name) is None
    ]
    results.append(
        {
            "name": "Core packages",
            "status": "ok" if not missing else "error",
            "message": (
                "all installed"
                if not missing
                else f"missing: {', '.join(missing)} - run 'pip install -r requirements.txt'"
            ),
        }
    )

    # Apple driver / usbmuxd
    results.append(_check_usbmux())

    # Anisette
    ani = anisette.status()
    if not ani["available"]:
        results.append(
            {
                "name": "Anisette",
                "status": "error",
                "message": "the Anisette package is not installed",
            }
        )
    elif ani["state_cached"]:
        results.append(
            {
                "name": "Anisette",
                "status": "ok",
                "message": f"provisioned state cached at {ani['state_path']}",
            }
        )
    else:
        results.append(
            {
                "name": "Anisette",
                "status": "warn",
                "message": "not provisioned yet - will download provisioning libraries "
                "on first login",
            }
        )

    # zsign
    zsign = signing.signing_status()
    if zsign["available"]:
        results.append(
            {
                "name": "zsign",
                "status": "ok",
                "message": f"{zsign['path']} ({zsign.get('version') or 'unknown version'})",
            }
        )
    else:
        results.append(
            {
                "name": "zsign",
                "status": "error",
                "message": zsign["error"] + " Run 'emload setup' to download it.",
            }
        )

    # Data directory
    results.append(
        {
            "name": "Data directory",
            "status": "ok",
            "message": str(paths.data_dir()),
        }
    )

    return results


def _check_usbmux() -> dict[str, Any]:
    """Check that usbmuxd / Apple Mobile Device Service is reachable."""
    try:
        entries = device.list_devices()
        if entries:
            udids = device._targetable_udids(entries)
            return {
                "name": "Device service",
                "status": "ok",
                "message": f"{len(udids)} device(s) connected: {', '.join(udids)}",
            }
        return {
            "name": "Device service",
            "status": "warn",
            "message": "running, but no device is connected",
        }
    except Exception as exc:  # noqa: BLE001 - report, don't crash
        return {
            "name": "Device service",
            "status": "error",
            "message": (
                "could not reach the Apple Mobile Device Service (usbmuxd). "
                "Install Apple Devices or iTunes from the Microsoft Store, then "
                f"retry. ({exc})"
            ),
        }


def summary() -> dict[str, Any]:
    """A short machine-readable readiness report for the CLI/GUI."""
    checks = check()
    return {
        "ok": all(c["status"] == "ok" for c in checks),
        "checks": checks,
    }