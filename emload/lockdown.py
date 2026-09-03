"""Lockdown client helpers.

Centralizes how EmLoad opens a lockdown connection to a device so every feature
(device info, app inventory, app install) shares the same connection-selection
policy: prefer USB, fall back to network, or honor an explicit choice from
settings/environment (``EMLOAD_CONNECTION`` = auto | usb | wifi).
"""

from __future__ import annotations

import os
from typing import Any

from ._asyncutil import maybe_await
from . import device as device_mod  # deferred import to avoid a cycle
from .errors import EmLoadError

#: Environment variable naming the transport to use: ``usb``, ``wifi``, or unset.
CONNECTION_ENV = "EMLOAD_CONNECTION"


class ConnectionError(EmLoadError):
    """A device could not be reached."""


def preferred_connection() -> str | None:
    """The transport the user picked, or None to prefer USB and fall back."""
    raw = (os.environ.get(CONNECTION_ENV) or "").strip().lower()
    if raw in ("", "auto"):
        return None
    if raw == "usb":
        return "USB"
    if raw in ("network", "wifi", "wi-fi"):
        return "Network"
    raise ConnectionError(
        f"{CONNECTION_ENV}={raw!r} is not a transport; use usb, wifi, or auto."
    )


async def create(serial: str | None = None, prefer_usb: bool = True) -> Any:
    """Open a lockdown client for a device.

    ``serial`` selects a specific UDID; ``None`` means "the single connected
    device" (resolved here; with two phones attached that becomes an error rather
    than an arbitrary pick - see :func:`emload.device.resolve_serial`).
    """
    from pymobiledevice3.lockdown import create_using_usbmux

    serial = await device_mod.resolve_serial_async(serial)
    forced = preferred_connection()
    if forced is not None:
        attempts: tuple[str | None, ...] = (forced,)
    else:
        # USB first: faster and more reliable for installs.
        attempts = ("USB", None) if prefer_usb else (None,)
    last: Exception | None = None
    for connection_type in attempts:
        try:
            return await maybe_await(
                create_using_usbmux(serial=serial, connection_type=connection_type)
            )
        except Exception as exc:  # this transport is unavailable - try the next
            last = exc
    raise ConnectionError(_unreachable(serial, last, forced)) from last


def _unreachable(serial: str, cause: Exception | None, forced: str | None) -> str:
    """Why a known device could not be reached, in words worth showing a person."""
    from pymobiledevice3.exceptions import DeviceNotFoundError

    if forced is not None:
        wording = "over USB" if forced == "USB" else "over Wi-Fi"
        return (
            f"Device {serial} is not reachable {wording}. Connect it that way, or "
            "set the connection back to Automatic."
        )
    if isinstance(cause, DeviceNotFoundError):
        return (
            f"Device {serial} is not connected. Reconnect it, or pick another device."
        )
    detail = str(cause) if cause is not None and str(cause) else type(cause).__name__
    return (
        f"Could not reach device {serial}: {detail}. "
        "Check it is plugged in, unlocked, and trusted."
    )


async def all_values(client: Any) -> dict[str, Any]:
    """Return the device's lockdown value bag as a plain dict."""
    values = await maybe_await(getattr(client, "all_values", {}))
    return values if isinstance(values, dict) else {}


async def close(client: Any) -> None:
    """Close a lockdown client, awaiting if needed."""
    await maybe_await(client.close())