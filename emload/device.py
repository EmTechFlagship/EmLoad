"""Device enumeration, identity, and target selection.

Lists iOS devices visible to usbmuxd (USB and network), decides *which* of them a
command with no explicit UDID means, and reads a curated, stable subset of
lockdown values for a chosen device.
"""

from __future__ import annotations

import asyncio
import threading
from collections.abc import Awaitable, Callable
from typing import Any

from . import lockdown
from ._asyncutil import maybe_await, run
from .errors import EmLoadError


class DeviceError(EmLoadError):
    """No device to act on, or no way to tell which one was meant."""


def mux_device_to_entry(dev: Any) -> dict[str, Any]:
    """One ``devices`` row from a pymobiledevice3 ``MuxDevice``."""
    return {
        "serial": getattr(dev, "serial", None),
        "connection_type": getattr(dev, "connection_type", None),
        "device_id": getattr(dev, "devid", getattr(dev, "device_id", None)),
    }


def listing_signature(entries: list[dict[str, Any]]) -> tuple[tuple[Any, ...], ...]:
    """Identity of a usbmux listing: serial, transport, and mux handle per row."""
    return tuple(
        (entry.get("serial"), entry.get("connection_type"), entry.get("device_id"))
        for entry in entries
    )


async def _list_devices_async() -> list[dict[str, Any]]:
    from pymobiledevice3 import usbmux

    devices = await maybe_await(usbmux.list_devices())
    return [mux_device_to_entry(dev) for dev in devices]


def list_devices() -> list[dict[str, Any]]:
    """List every iOS device currently visible to usbmuxd (USB and network)."""
    return run(_list_devices_async())


def _targetable_udids(entries: list[dict[str, Any]]) -> list[str]:
    """The distinct devices in a usbmux listing, in the order first seen.

    usbmux reports one entry *per transport*, so a phone that is plugged in and
    also reachable over Wi-Fi is listed twice under the same serial. That is one
    device with two ways in, not two devices.
    """
    udids: list[str] = []
    for entry in entries:
        serial = entry.get("serial")
        if serial and str(serial) not in udids:
            udids.append(str(serial))
    return udids


def _choose_udid(entries: list[dict[str, Any]]) -> str:
    """The one device in ``entries``, or a ``DeviceError`` explaining the problem."""
    udids = _targetable_udids(entries)
    if not udids:
        raise DeviceError("No device connected; connect an iPhone (or pass --udid).")
    if len(udids) > 1:
        raise DeviceError(
            f"More than one device is connected ({', '.join(udids)}). "
            "Pass --udid to choose one, or disconnect the others."
        )
    return udids[0]


def resolve_serial(serial: str | None = None) -> str:
    """The UDID to act on: the one given, or the single connected device."""
    if serial:
        return serial
    return _choose_udid(list_devices())


async def resolve_serial_async(serial: str | None = None) -> str:
    """``resolve_serial`` for callers already inside the event loop."""
    if serial:
        return serial
    return _choose_udid(await _list_devices_async())


# Fields surfaced for a connected device. Kept small and stable so the UI can
# rely on them; the raw lockdown value bag has hundreds of keys.
_INFO_KEYS = (
    "DeviceName",
    "ProductType",
    "ProductVersion",
    "BuildVersion",
    "UniqueDeviceID",
    "SerialNumber",
    "CPUArchitecture",
    "DeviceClass",
    "HardwareModel",
    "ProductName",
)


async def _get_device_info_async(serial: str | None, prefer_usb: bool) -> dict[str, Any]:
    client = await lockdown.create(serial, prefer_usb=prefer_usb)
    try:
        values = await lockdown.all_values(client)
        return {key: values[key] for key in _INFO_KEYS if key in values}
    finally:
        await lockdown.close(client)


def get_device_info(serial: str | None = None, prefer_usb: bool = True) -> dict[str, Any]:
    """Return a curated lockdown value bag for one device (USB preferred)."""
    return run(_get_device_info_async(serial, prefer_usb))


def describe_device(serial: str | None = None) -> dict[str, Any]:
    """A friendly description of one device for CLI/UI display."""
    entries = list_devices()
    target = serial or (_choose_udid(entries) if entries else None)
    if not target:
        return {"udid": None, "name": None, "connected": False}
    info = get_device_info(target)
    return {
        "udid": target,
        "name": info.get("DeviceName"),
        "model": info.get("ProductType"),
        "ios": info.get("ProductVersion"),
        "connected": True,
    }


async def _wait_until_stopped(stop: threading.Event) -> None:
    await asyncio.to_thread(stop.wait)


async def watch_usbmux(
    emit: Callable[[dict[str, Any]], None],
    stop: threading.Event,
    *,
    create_mux: Callable[[], Awaitable[Any]] | None = None,
    reconnect_wait: float = 1.0,
) -> None:
    """Hold a usbmux Listen socket and ``emit`` a ``devices`` event on changes.

    ``emit`` is called with the full current entry list whenever the inventory
    changes (Attached/Detached). It is not a poll: ``receive_device_state_update``
    blocks until usbmux writes a state change.
    """
    from pymobiledevice3.exceptions import MuxException

    async def default_create_mux() -> Any:
        from pymobiledevice3 import usbmux

        return await usbmux.create_mux()

    factory = create_mux or default_create_mux
    last: tuple[tuple[Any, ...], ...] | None = None
    had_listen = False
    stopped = asyncio.create_task(_wait_until_stopped(stop))

    def publish(entries: list[dict[str, Any]]) -> None:
        nonlocal last
        signature = listing_signature(entries)
        if signature == last:
            return
        last = signature
        emit({"type": "event", "name": "devices", "data": entries})

    try:
        while not stop.is_set():
            mux: Any = None
            try:
                mux = await factory()
                await mux.listen()
                if had_listen:
                    publish([mux_device_to_entry(dev) for dev in mux.devices])
                had_listen = True
                while not stop.is_set():
                    update = asyncio.create_task(mux.receive_device_state_update())
                    done, _pending = await asyncio.wait(
                        {update, stopped},
                        return_when=asyncio.FIRST_COMPLETED,
                    )
                    if stopped in done:
                        if not update.done():
                            update.cancel()
                            try:
                                await update
                            except asyncio.CancelledError:
                                pass
                        return
                    await update
                    publish([mux_device_to_entry(dev) for dev in mux.devices])
            except (OSError, MuxException):
                if stop.is_set():
                    return
                await asyncio.to_thread(stop.wait, reconnect_wait)
            finally:
                if mux is not None:
                    close = getattr(mux, "close", None)
                    if close is not None:
                        try:
                            await maybe_await(close())
                        except OSError:
                            pass
    finally:
        if not stopped.done():
            stopped.cancel()
            try:
                await stopped
            except asyncio.CancelledError:
                pass


def run_usbmux_watch(
    emit: Callable[[dict[str, Any]], None],
    stop: threading.Event,
    **kwargs: Any,
) -> None:
    """``watch_usbmux`` for a background thread that has no event loop yet."""
    asyncio.run(watch_usbmux(emit, stop, **kwargs))