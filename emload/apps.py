"""Installed-app inventory and IPA installation.

Wraps pymobiledevice3's ``InstallationProxyService`` for listing, installing, and
removing apps. Installation streams progress via a callback so the UI can show a
live progress bar (upload via AFC, then installd's own phases).
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Callable

from . import lockdown
from ._asyncutil import maybe_await, run
from .errors import EmLoadError

ProgressCallback = Callable[[dict[str, Any]], None]


class InstallLimitError(EmLoadError):
    """The device will not take another app, said the way a person would say it."""


async def _list_installed_async(serial: str | None, app_type: str) -> dict[str, Any]:
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    client = await lockdown.create(serial)
    try:
        proxy = InstallationProxyService(lockdown=client)
        try:
            apps = await maybe_await(proxy.get_apps(application_type=app_type))
        finally:
            await maybe_await(proxy.close())
    finally:
        await lockdown.close(client)

    result: dict[str, Any] = {}
    for bundle_id, meta in (apps or {}).items():
        result[bundle_id] = {
            "name": meta.get("CFBundleDisplayName") or meta.get("CFBundleName"),
            "version": meta.get("CFBundleShortVersionString"),
            "build": meta.get("CFBundleVersion"),
        }
    return result


def list_installed(serial: str | None = None, app_type: str = "User") -> dict[str, Any]:
    """List installed apps. ``app_type`` is ``User``, ``System``, or ``Any``."""
    return run(_list_installed_async(serial, app_type))


async def _icons_async(
    serial: str | None, bundle_ids: list[str] | None, app_type: str
) -> dict[str, str]:
    import base64

    from pymobiledevice3.services.springboard import SpringBoardServicesService

    client = await lockdown.create(serial)
    try:
        if bundle_ids is None:
            from pymobiledevice3.services.installation_proxy import (
                InstallationProxyService,
            )

            proxy = InstallationProxyService(lockdown=client)
            try:
                listed = await maybe_await(proxy.get_apps(application_type=app_type))
            finally:
                await maybe_await(proxy.close())
            bundle_ids = sorted(listed or {})

        springboard = SpringBoardServicesService(lockdown=client)
        try:
            icons: dict[str, str] = {}
            for bundle_id in bundle_ids:
                try:
                    data = await springboard.get_icon_pngdata(bundle_id)
                except Exception:  # noqa: BLE001 - one unreadable icon must not lose the rest
                    continue
                if data:
                    encoded = base64.b64encode(data).decode("ascii")
                    icons[bundle_id] = f"data:image/png;base64,{encoded}"
            return icons
        finally:
            await maybe_await(springboard.close())
    finally:
        await lockdown.close(client)


def icons(
    bundle_ids: list[str] | None = None,
    serial: str | None = None,
    app_type: str = "User",
) -> dict[str, str]:
    """Home-screen icons as PNG data URIs, keyed by bundle id."""
    return run(_icons_async(serial, bundle_ids, app_type))


# 4 MiB per AFC write: frequent, low-overhead byte-level upload progress.
_UPLOAD_CHUNK = 1 << 22


async def _install_async(
    ipa_path: str, serial: str | None, progress: ProgressCallback | None
) -> None:
    import uuid

    from pymobiledevice3.services.afc import AfcService
    from pymobiledevice3.services.installation_proxy import (
        TEMP_REMOTE_BASEDIR,
        InstallationProxyService,
    )

    report: ProgressCallback = progress or (lambda _u: None)
    src = Path(ipa_path)
    total = src.stat().st_size

    client = await lockdown.create(serial)
    try:
        proxy = InstallationProxyService(lockdown=client)
        try:
            remote = f"{TEMP_REMOTE_BASEDIR}/{uuid.uuid4()}.ipa"
            async with AfcService(client) as afc:
                await afc.makedirs(TEMP_REMOTE_BASEDIR)
                # Phase 1 - copy the signed IPA to the device, reporting bytes.
                report({"phase": "upload", "percent": 0, "sent": 0, "total": total})
                handle = await afc.fopen(remote, "w")
                try:
                    sent = 0
                    with src.open("rb") as fh:
                        while True:
                            chunk = fh.read(_UPLOAD_CHUNK)
                            if not chunk:
                                break
                            await afc.fwrite(handle, chunk)
                            sent += len(chunk)
                            report({
                                "phase": "upload",
                                "percent": int(sent * 100 / total) if total else 100,
                                "sent": sent,
                                "total": total,
                            })
                finally:
                    await afc.fclose(handle)
                # Phase 2 - installd extracts/verifies/installs, reporting sub-steps.
                try:
                    await _watch_install(proxy, remote, report)
                finally:
                    await afc.rm_single(remote, force=True)
        finally:
            await maybe_await(proxy.close())
    finally:
        await lockdown.close(client)


# installd's wording when the free-profile ceiling is reached.
_FREE_PROFILE_LIMIT = "maximum number of installed apps using a free developer profile"


def _installed_ids(description: str) -> list[str]:
    """The `TEAMID.bundle.id` entries installd names as occupying the slots."""
    return re.findall(r'"([A-Z0-9]{10}\.[^"]+)"', description or "")


def _readable_install_error(error: str, description: str | None) -> str | None:
    """A sentence for the install failures worth explaining, or None to pass through."""
    if not description or _FREE_PROFILE_LIMIT not in description:
        return None

    occupied = _installed_ids(description)
    lines = [
        "Your iPhone already has the most apps a free Apple ID can install at once "
        f"({len(occupied) or 3}). Delete one to make room."
    ]
    if occupied:
        lines.append("Currently using the slots:")
        for entry in occupied:
            team, _, bundle = entry.partition(".")
            lines.append(f"  - {bundle}  (team {team})")
        teams = {entry.split(".", 1)[0] for entry in occupied}
        if len(teams) > 1:
            lines.append(
                "These come from more than one Apple ID, which is the point: iOS counts "
                "every app signed by any free account, so signing in with another one "
                "does not add slots. Only a paid developer account lifts this."
            )
        else:
            lines.append(
                "iOS counts every app signed by any free account, so signing in with "
                "another Apple ID does not add slots. Only a paid developer account "
                "lifts this."
            )
    return "\n".join(lines)


async def _watch_install(proxy: Any, remote_path: str, report: ProgressCallback) -> None:
    """Send the Install command and stream installd's progress + status sub-steps."""
    from pymobiledevice3.exceptions import AppInstallError

    await proxy.service.send_plist(
        {"Command": "Install", "ClientOptions": {}, "PackagePath": remote_path}
    )
    while True:
        response = await proxy.service.recv_plist()
        if not response:
            break
        error = response.get("Error")
        if error:
            description = response.get("ErrorDescription")
            readable = _readable_install_error(error, description)
            if readable:
                raise InstallLimitError(readable)
            raise AppInstallError(f"{error}: {description}")
        status = response.get("Status")
        percent = response.get("PercentComplete")
        if status or percent is not None:
            report({"phase": "install", "percent": percent, "status": status})
        if status == "Complete":
            return
    raise AppInstallError("installd closed the connection before completing the install")


def install(
    ipa_path: str, serial: str | None = None, progress: ProgressCallback | None = None
) -> None:
    """Install (or upgrade) a signed IPA, staging it via AFC + installd."""
    return run(_install_async(ipa_path, serial, progress))


async def _uninstall_async(bundle_id: str, serial: str | None) -> None:
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    client = await lockdown.create(serial)
    try:
        proxy = InstallationProxyService(lockdown=client)
        try:
            await maybe_await(proxy.uninstall(bundle_id))
        finally:
            await maybe_await(proxy.close())
    finally:
        await lockdown.close(client)


def uninstall(bundle_id: str, serial: str | None = None) -> None:
    """Uninstall an app by bundle identifier."""
    return run(_uninstall_async(bundle_id, serial))