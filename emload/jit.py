"""Enable JIT for a sideloaded app by attaching debugserver, then detaching.

iOS allows writable-and-executable memory only while a process is marked
debugged (``CS_DEBUGGED``). A development signature includes
``get-task-allow``, so a short debugserver attach followed by detach turns
JIT on until the process exits. No jailbreak and no LLDB session are required:
EmLoad speaks the GDB remote protocol itself.

iOS 17 and later reach debugserver through an in-process userspace tunnel, so
this works without root. Older releases use the lockdown developer service
after the developer disk image is mounted.
"""

from __future__ import annotations

import asyncio
import threading
from typing import Any, Callable

from . import apps, device, lockdown
from ._asyncutil import run
from .errors import EmLoadError

ProgressFn = Callable[[str, Any, str | None], None]

#: One tunnel per process. Concurrent enables (the RPC pool) wait their turn.
_enable_lock = threading.Lock()

_SERVICE_LEGACY = "com.apple.debugserver.DVTSecureSocketProxy"
_SERVICE_IOS17 = "com.apple.internal.dt.remote.debugproxy"

_DEVELOPER_MODE = (
    "Turn on Developer Mode on the device (Settings → Privacy & Security → "
    "Developer Mode), unlock it, and try again."
)


class JitError(EmLoadError):
    """JIT could not be enabled, for a reason the user can act on."""


def list_user_apps(serial: str | None = None) -> list[dict[str, Any]]:
    """User-installed apps on the device, sorted by display name."""
    installed = apps.list_installed(serial, "User")
    rows = [
        {
            "bundle_id": bundle_id,
            "name": meta.get("name"),
            "version": meta.get("version"),
            "build": meta.get("build"),
        }
        for bundle_id, meta in installed.items()
    ]
    rows.sort(key=lambda row: str(row.get("name") or row["bundle_id"]).casefold())
    return rows


def enable_jit(
    serial: str | None,
    bundle_id: str,
    *,
    launch: bool = True,
    relaunch: bool = False,
    on_progress: ProgressFn | None = None,
) -> dict[str, Any]:
    """Mount the developer image, attach debugserver to ``bundle_id``, and detach.

    When the app is not running and ``launch`` is true, it is started suspended
    so the debugger is attached before its own code runs. ``relaunch`` quits a
    copy that is already open and starts it the same way. Detach resumes the
    process with JIT enabled.
    """
    bundle_id = (bundle_id or "").strip()
    if not bundle_id:
        raise JitError("A bundle identifier is required.")
    try:
        with _enable_lock:
            return run(
                _enable_async(
                    serial,
                    bundle_id,
                    launch=launch,
                    relaunch=relaunch,
                    on_progress=on_progress,
                )
            )
    except JitError:
        raise
    except EmLoadError:
        raise
    except Exception as exc:
        raise _translate(exc) from exc


def debugserver_service_name(product_version: str) -> str:
    """The lockdown/RSD service that speaks the GDB remote protocol."""
    if _version_at_least(product_version, 17):
        return _SERVICE_IOS17
    return _SERVICE_LEGACY


def gdb_packet(command: str) -> bytes:
    """One GDB remote packet: ``$<command>#<checksum>``."""
    payload = command.encode("ascii")
    return b"$" + payload + b"#" + f"{sum(payload) & 0xFF:02x}".encode("ascii")


# --------------------------------------------------------------------------- #
# Device session
# --------------------------------------------------------------------------- #
async def _enable_async(
    serial: str | None,
    bundle_id: str,
    *,
    launch: bool,
    relaunch: bool,
    on_progress: ProgressFn | None,
) -> dict[str, Any]:
    serial = await device.resolve_serial_async(serial)
    _step(on_progress, "connect", "Connecting to the device")
    client = await lockdown.create(serial)
    version = str(getattr(client, "product_version", "") or "")
    if not _version_at_least(version, 17):
        try:
            await _mount(client, on_progress)
            return await _enable_on(
                client,
                serial,
                bundle_id,
                launch=launch,
                relaunch=relaunch,
                on_progress=on_progress,
            )
        finally:
            await lockdown.close(client)

    await lockdown.close(client)
    _step(on_progress, "tunnel", "Opening a developer tunnel")
    from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel

    async with UserspaceRsdTunnel(serial=serial) as rsd:
        await _mount(rsd, on_progress)
        return await _enable_on(
            rsd,
            serial,
            bundle_id,
            launch=launch,
            relaunch=relaunch,
            on_progress=on_progress,
        )


async def _mount(provider: Any, on_progress: ProgressFn | None) -> None:
    from pymobiledevice3.exceptions import AlreadyMountedError
    from pymobiledevice3.services.mobile_image_mounter import auto_mount

    _step(on_progress, "mount", "Mounting the developer disk image")
    try:
        await auto_mount(provider)
    except AlreadyMountedError:
        _step(on_progress, "mount", "Developer disk image is already mounted")


async def _enable_on(
    provider: Any,
    serial: str,
    bundle_id: str,
    *,
    launch: bool,
    relaunch: bool,
    on_progress: ProgressFn | None,
) -> dict[str, Any]:
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
    from pymobiledevice3.services.lockdown_service import LockdownService

    _step(on_progress, "prepare", "Finding the app")
    launched_suspended = False
    pid = 0
    async with DvtProvider(provider) as dvt, ProcessControl(dvt) as process_control:
        pid, launched_suspended = await _prepare_process(
            process_control,
            bundle_id,
            launch=launch,
            relaunch=relaunch,
            on_progress=on_progress,
        )
        memory_limit_disabled = await _waive_memory_limit(process_control, pid)

    service_name = debugserver_service_name(str(getattr(provider, "product_version", "")))
    debugserver = LockdownService(provider, service_name=service_name, is_developer_service=True)
    try:
        _step(on_progress, "attach", f"Attaching the debugger to pid {pid}")
        try:
            await debugserver.connect()
            await _attach_and_detach(debugserver.service, pid)
        except Exception as exc:
            note = ""
            if launched_suspended:
                try:
                    await _resume(provider, pid)
                except Exception:
                    note = " The app was left suspended; force-quit it on the device and try again."
            if isinstance(exc, JitError):
                if note:
                    raise JitError(str(exc) + note) from exc
                raise
            raise JitError(_failure_text(exc) + note) from exc
    finally:
        await debugserver.close()

    if not memory_limit_disabled:
        memory_limit_disabled = await _waive_memory_limit_again(provider, pid)

    _step(on_progress, "done", f"JIT is enabled for {bundle_id}")
    return {
        "udid": serial,
        "bundle_id": bundle_id,
        "pid": pid,
        "launched": launched_suspended,
        "memory_limit_disabled": memory_limit_disabled,
    }


async def _prepare_process(
    process_control: Any,
    bundle_id: str,
    *,
    launch: bool,
    relaunch: bool,
    on_progress: ProgressFn | None,
) -> tuple[int, bool]:
    """Return ``(pid, launched_suspended)``."""
    try:
        pid = int(await process_control.process_identifier_for_bundle_identifier(bundle_id))
    except Exception as exc:
        raise JitError(
            f"Could not look up {bundle_id}. Confirm it is installed and the phone is unlocked."
        ) from exc

    if pid > 0 and not relaunch:
        return pid, False
    if pid <= 0 and not launch and not relaunch:
        raise JitError(
            f"{bundle_id} is not running. Open it on the device, or let EmLoad launch it."
        )
    if pid <= 0 and relaunch and not launch:
        raise JitError(
            f"{bundle_id} is not running. Open it on the device, or let EmLoad launch it."
        )

    _step(
        on_progress,
        "launch",
        "Relaunching the app" if pid > 0 else "Launching the app",
    )
    try:
        launched = int(
            await process_control.launch(
                bundle_id,
                kill_existing=pid > 0,
                start_suspended=True,
            )
        )
    except AssertionError as exc:
        raise JitError(
            f"The device did not start {bundle_id}. Confirm it is installed and the phone is unlocked."
        ) from exc
    if launched <= 0:
        raise JitError(f"The device did not start {bundle_id}.")
    return launched, True


async def _waive_memory_limit(process_control: Any, pid: int) -> bool:
    try:
        await process_control.disable_memory_limit_for_pid(pid)
    except Exception:
        return False
    return True


async def _waive_memory_limit_again(provider: Any, pid: int) -> bool:
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

    try:
        async with DvtProvider(provider) as dvt, ProcessControl(dvt) as process_control:
            return await _waive_memory_limit(process_control, pid)
    except Exception:
        return False


async def _resume(provider: Any, pid: int) -> None:
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

    async with DvtProvider(provider) as dvt, ProcessControl(dvt) as process_control:
        await process_control.resume(pid)


async def _attach_and_detach(service: Any, pid: int) -> None:
    """Attach debugserver to ``pid`` and detach, leaving the process running."""
    reader = _Buffered(service.recv_any)
    send = service.sendall

    reply = await _roundtrip(reader, send, "QStartNoAckMode", timeout=15)
    if not reply.startswith("OK"):
        raise JitError(f"debugserver rejected no-ack mode ({_short(reply)}).")

    # Best-effort: if our connection drops, the device should resume the app
    # instead of killing it. Ignore stubs that do not implement the command.
    await _roundtrip(reader, send, "QSetDetachOnError:1", timeout=15)

    reply = await _roundtrip(reader, send, f"vAttach;{pid:x}", timeout=40)
    if reply.startswith("E") or reply[:1] not in {"T", "S", "W"}:
        raise JitError(
            f"debugserver refused to attach ({_short(reply)}). The app needs a "
            "development signature with get-task-allow. Sideload it with EmLoad, "
            "keep the device unlocked, and try again."
        )

    reply = await _roundtrip(reader, send, "D", timeout=15)
    if reply.startswith("E"):
        raise JitError(f"debugserver refused to detach ({_short(reply)}).")


# --------------------------------------------------------------------------- #
# GDB remote protocol
# --------------------------------------------------------------------------- #
class _Buffered:
    """Byte buffer over a ``read(n) -> up to n bytes`` coroutine."""

    def __init__(self, read: Callable[[int], Any]):
        self._read = read
        self._buf = bytearray()

    async def readexactly(self, n: int, timeout: float) -> bytes:
        while len(self._buf) < n:
            try:
                chunk = await asyncio.wait_for(self._read(max(4096, n - len(self._buf))), timeout)
            except asyncio.TimeoutError as exc:
                raise JitError(
                    "debugserver did not answer. Keep the device unlocked, with "
                    "Developer Mode on, and try again."
                ) from exc
            if not chunk:
                raise JitError(
                    "The device closed debugserver before JIT was enabled. Unlock "
                    "the phone, leave Developer Mode on, and try again."
                )
            self._buf.extend(chunk)
        out = bytes(self._buf[:n])
        del self._buf[:n]
        return out


async def _roundtrip(reader: _Buffered, send: Callable[[bytes], Any], command: str, *, timeout: float) -> str:
    """Send one command and return the first reply that is not console output.

    When the peer still speaks acknowledgements, the ``+`` it prefixes to a
    reply is answered with ``+`` before the next command. ``QStartNoAckMode``
    turns that off for everything after its own ``OK``.
    """
    await send(gdb_packet(command))
    while True:
        raw, saw_ack = await _read_packet(reader, timeout)
        if saw_ack:
            await send(b"+")
        text = _decode_packet(raw)
        # Console output is ``O<hex>``. ``OK`` is a normal acknowledgement and
        # must not be read as another output packet.
        if text.startswith("O") and not text.startswith("OK"):
            continue
        return text


async def _read_packet(reader: _Buffered, timeout: float) -> tuple[bytes, bool]:
    """Return ``(payload, saw_ack)`` for one GDB packet.

    ``payload`` is the raw bytes between ``$`` and ``#``. Escaped bytes stay
    escaped: the checksum covers the transmitted form, and the replies EmLoad
    inspects (``OK``, ``E..``, ``T..``) are not escaped. A leading ``+`` means
    the peer still expects an acknowledgement.
    """
    saw_ack = False
    first = await reader.readexactly(1, timeout)
    while first in (b"+", b"-"):
        if first == b"-":
            raise JitError("debugserver rejected a packet.")
        saw_ack = True
        first = await reader.readexactly(1, timeout)
    if first != b"$":
        raise JitError(f"debugserver sent an unexpected byte ({first!r}).")

    raw = bytearray()
    while True:
        byte = await reader.readexactly(1, timeout)
        if byte == b"#":
            break
        raw.extend(byte)
    checksum = await reader.readexactly(2, timeout)
    expected = f"{sum(raw) & 0xFF:02x}".encode("ascii")
    if checksum.lower() != expected:
        raise JitError("debugserver sent a packet with a bad checksum.")
    return bytes(raw), saw_ack


def _decode_packet(raw: bytes) -> str:
    out = bytearray()
    index = 0
    while index < len(raw):
        byte = raw[index]
        if byte == 0x7D and index + 1 < len(raw):  # '}' escapes the next byte
            out.append(raw[index + 1] ^ 0x20)
            index += 2
            continue
        out.append(byte)
        index += 1
    return out.decode("ascii", "replace")


def _short(reply: str) -> str:
    reply = reply.replace("\n", " ").strip()
    if len(reply) > 80:
        return reply[:77] + "..."
    return reply or "empty reply"


def _step(on_progress: ProgressFn | None, phase: str, step: str) -> None:
    if on_progress is not None:
        on_progress(phase, None, step)


def _version_at_least(version: str, major: int, minor: int = 0) -> bool:
    parts: list[int] = []
    for piece in (version or "").split("."):
        digits = ""
        for char in piece:
            if char.isdigit():
                digits += char
            else:
                break
        if not digits:
            break
        parts.append(int(digits))
    while len(parts) < 2:
        parts.append(0)
    return (parts[0], parts[1]) >= (major, minor)


def _failure_text(exc: BaseException) -> str:
    message = str(exc).strip()
    if message:
        return message
    return exc.__class__.__name__


def _translate(exc: BaseException) -> EmLoadError:
    """Turn a pymobiledevice3 failure into a sentence for the CLI and the GUI."""
    from pymobiledevice3.exceptions import (
        DeveloperDiskImageNotFoundError,
        DeveloperModeError,
        DeveloperModeIsNotEnabledError,
        InvalidServiceError,
        PyMobileDevice3Exception,
        UserspaceTunnelUnavailableError,
    )

    if isinstance(exc, (DeveloperModeIsNotEnabledError, DeveloperModeError, InvalidServiceError)):
        return JitError(_DEVELOPER_MODE)
    if isinstance(exc, DeveloperDiskImageNotFoundError):
        return JitError(
            "No developer disk image is available for this iOS version. Install "
            "Xcode, or update the EmLoad Python environment, then try again."
        )
    if isinstance(exc, UserspaceTunnelUnavailableError):
        detail = str(exc).strip()
        if detail:
            return JitError(detail)
        return JitError(
            "EmLoad could not open a developer tunnel to this device. Keep it "
            "plugged in, unlocked, and on the same Wi-Fi as this Mac, then try again."
        )
    if isinstance(exc, PyMobileDevice3Exception):
        detail = str(exc).strip() or exc.__class__.__name__
        if "already active" in detail.lower():
            return JitError(
                "A developer tunnel is still open. Wait for the other JIT request "
                "to finish, or restart EmLoad, then try again."
            )
        return JitError(detail)
    if isinstance(exc, (asyncio.TimeoutError, TimeoutError)):
        return JitError(
            "debugserver did not answer. Keep the device unlocked, with Developer "
            "Mode on, and try again."
        )
    if isinstance(exc, (ConnectionError, OSError, asyncio.IncompleteReadError)):
        return JitError(
            "The connection to the device dropped. Unlock it, reconnect the cable, "
            "and try again."
        )
    return JitError(_failure_text(exc))
