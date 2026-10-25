"""JSON-RPC bridge so a non-Python front end can drive the EmLoad engine.

The WinUI app (``gui-winui/``) is a thin C# shell: every operation that touches
an iPhone, Apple's servers, or the filesystem still runs here, in Python, using
exactly the same ``emload`` modules the CLI and the PySide6 GUI use.

Transport
---------
One long-lived ``emload rpc`` process, newline-delimited JSON in both
directions. Requests::

    {"id": 3, "method": "sideload.run", "params": {...}}

Responses::

    {"id": 3, "ok": true,  "result": {...}}
    {"id": 3, "ok": false, "error": "...", "kind": "EmLoadError"}

Unsolicited events (no ``id``) carry progress, device changes and log lines::

    {"event": "ready",    "version": "0.1.0", "python": "3.15.1"}
    {"event": "progress", "id": 3, "phase": "sign", "percent": 40, "step": "..."}
    {"event": "log",      "id": 3, "message": "..."}
    {"event": "devices",  "data": [{"serial": "...", "connection_type": "usb"}]}
    {"event": "provision.result", "udid": "...", "result": {...}}
    {"event": "watch.error", "message": "..."}

Concurrency
-----------
Requests are handled on a small thread pool, so a two-minute sideload does not
block ``devices.list`` or a device event. Writes to stdout are serialized by a
lock (a JSON line is never interleaved). Nothing here imports PySide6, which
also keeps the process clear of the Qt/Python 3.15 lazy-import incompatibility
that breaks ``asyncio.to_thread`` inside the Qt app.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import traceback
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Callable

from . import (
    __version__,
    apps,
    device,
    doctor,
    gsa,
    ipa,
    paths,
    provision,
    registry,
    sideload,
    signing,
)
from .errors import EmLoadError
from .nugget import schema as nugget_schema

#: How many requests may run at once. Sideloads are long; device listings are
#: quick and must not queue behind them.
_MAX_WORKERS = 8

#: Passwords for the two-step Apple ID flow, held in memory only until the 2FA
#: code arrives (same lifetime as the PySide6 dialog's password field).
_pending_passwords: dict[str, str] = {}


# --------------------------------------------------------------------------- #
# Output plumbing
# --------------------------------------------------------------------------- #
class _Writer:
    """Serialize JSON lines written by any worker thread."""

    def __init__(self, stream: Any):
        self._stream = stream
        self._lock = threading.Lock()

    def send(self, payload: dict[str, Any]) -> None:
        line = json.dumps(payload, ensure_ascii=False, default=str)
        with self._lock:
            try:
                self._stream.write(line + "\n")
                self._stream.flush()
            except (BrokenPipeError, ValueError):
                # The front end went away; nothing useful left to do.
                os._exit(0)


def _force_utf8() -> None:
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        encoding = getattr(stream, "encoding", None)
        if encoding and encoding.lower() not in ("utf-8", "utf8"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except (AttributeError, ValueError):
                pass


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {"result": value}


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else [value]


# --------------------------------------------------------------------------- #
# Settings (the same config.json the PySide6 Settings page writes)
# --------------------------------------------------------------------------- #
def _read_config() -> dict[str, Any]:
    try:
        return json.loads(paths.config_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _write_config(config: dict[str, Any]) -> None:
    paths.config_file().write_text(json.dumps(config, indent=2), encoding="utf-8")


def _settings_get() -> dict[str, Any]:
    config = _read_config()
    return {
        "connection": config.get("connection", "auto"),
        "signed_dir": config.get("signed_dir", ""),
        "keep_signed": bool(config.get("keep_signed")),
        "emstore_server": bool(config.get("emstore_server")),
        "data_dir": str(paths.data_dir()),
        "config_file": str(paths.config_file()),
    }


def _settings_set(patch: dict[str, Any]) -> dict[str, Any]:
    config = _read_config()
    if "connection" in patch:
        connection = patch["connection"]
        if connection not in ("auto", "usb", "wifi"):
            raise ValueError(f"invalid connection mode: {connection!r}")
        config["connection"] = connection
        # Live: the engine reads this env var on every connection attempt.
        if connection == "auto":
            os.environ.pop("EMLOAD_CONNECTION", None)
        else:
            os.environ["EMLOAD_CONNECTION"] = connection
    if "signed_dir" in patch:
        config["signed_dir"] = str(patch["signed_dir"] or "")
    if "keep_signed" in patch:
        config["keep_signed"] = bool(patch["keep_signed"])
    if "emstore_server" in patch:
        config["emstore_server"] = bool(patch["emstore_server"])
    _write_config(config)
    return _settings_get()


# --------------------------------------------------------------------------- #
# Device enrichment
# --------------------------------------------------------------------------- #
def _enrich(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Merge lockdown details into usbmux rows, one entry per serial."""
    seen: list[dict[str, Any]] = []
    done: set[str] = set()
    for entry in entries:
        serial = str(entry.get("serial") or "")
        if not serial or serial in done:
            continue
        done.add(serial)
        info: dict[str, Any] = {}
        try:
            info = device.get_device_info(serial, prefer_usb=False)
        except Exception:  # noqa: BLE001 - unpaired devices may not answer
            pass
        seen.append({**entry, "info": info})
    return seen


# --------------------------------------------------------------------------- #
# Method handlers
# --------------------------------------------------------------------------- #
class Handlers:
    """Every callable the front end can reach, each returning JSON-ready data."""

    def __init__(self, writer: _Writer):
        self._w = writer
        self._watch_stop: threading.Event | None = None
        self._watch_thread: threading.Thread | None = None
        self._watch_lock = threading.Lock()
        self._known_serials: set[str] = set()
        self._attach_lock = threading.Lock()
        self._emstore_lock = threading.Lock()
        self._emstore_busy: set[str] = set()
        # usbmux emits from inside its own event loop, where lockdown calls
        # (which use asyncio.run) are illegal -- so device events are handled
        # here instead of on the watcher thread.
        self._devices_pool = ThreadPoolExecutor(
            max_workers=2, thread_name_prefix="emload-devices"
        )

    def close(self) -> None:
        self._devices_pool.shutdown(wait=False, cancel_futures=True)

    # -- meta -------------------------------------------------------------- #
    def version(self, _params: dict[str, Any]) -> dict[str, Any]:
        return {"version": __version__, "python": sys.version.split()[0]}

    def doctor(self, _params: dict[str, Any]) -> list[dict[str, Any]]:
        return doctor.check()

    def browse(self, params: dict[str, Any]) -> dict[str, Any]:
        """List a directory for the WinUI folder picker fallback."""
        target = Path(params.get("path") or str(paths.data_dir()))
        entries = []
        for child in sorted(target.iterdir(), key=lambda p: p.name.lower()):
            if child.name.startswith("."):
                continue
            entries.append({"name": child.name, "is_dir": child.is_dir()})
        return {"path": str(target), "entries": entries}

    # -- devices ----------------------------------------------------------- #
    def devices_list(self, _params: dict[str, Any]) -> list[dict[str, Any]]:
        return _enrich(device.list_devices())

    def devices_raw(self, _params: dict[str, Any]) -> list[dict[str, Any]]:
        return device.list_devices()

    def devices_info(self, params: dict[str, Any]) -> dict[str, Any]:
        udid = params.get("udid")
        return device.get_device_info(udid, prefer_usb=False)

    def watch_start(self, _params: dict[str, Any]) -> dict[str, Any]:
        with self._watch_lock:
            if self._watch_thread is not None and self._watch_thread.is_alive():
                return {"status": "already_watching"}
            stop = threading.Event()
            self._watch_stop = stop
            thread = threading.Thread(
                target=self._watch_loop, args=(stop,), name="emload-watch", daemon=True
            )
            self._watch_thread = thread
            thread.start()
            return {"status": "watching"}

    def watch_stop(self, _params: dict[str, Any]) -> dict[str, Any]:
        with self._watch_lock:
            if self._watch_stop is not None:
                self._watch_stop.set()
            self._watch_stop = None
            self._watch_thread = None
            return {"status": "stopped"}

    def _watch_loop(self, stop: threading.Event) -> None:
        def emit(entry: dict[str, Any]) -> None:
            if entry.get("name") != "devices":
                return
            # Runs on the usbmux event loop: hand off and return immediately.
            self._devices_pool.submit(self._handle_devices, list(entry.get("data") or []))

        try:
            device.run_usbmux_watch(emit, stop)
        except Exception as exc:  # noqa: BLE001 - surfaced to the UI, not fatal
            if not stop.is_set():
                self._w.send({"event": "watch.error", "message": str(exc)})

    def _handle_devices(self, entries: list[dict[str, Any]]) -> None:
        rows = _enrich(entries)
        self._w.send({"event": "devices", "data": rows})
        current = {str(row.get("serial")) for row in rows if row.get("serial")}
        with self._attach_lock:
            attached = sorted(current - self._known_serials)
            self._known_serials = current
        for serial in attached:
            self._after_attach(serial)

    def _after_attach(self, serial: str) -> None:
        """Provision new devices automatically (mirrors the PySide6 window)."""
        try:
            result = provision.ensure_provisioned_for_device(serial)
            self._w.send({"event": "provision.result", "udid": serial, "result": _as_dict(result)})
        except Exception as exc:  # noqa: BLE001 - best effort
            self._w.send({"event": "log", "message": f"Could not provision {serial}: {exc}"})

        if _read_config().get("emstore_server"):
            self._schedule_emstore(serial)

    # -- EmSideStore (AltServer-style SideStore auto-install) ---------------- #
    def _schedule_emstore(self, serial: str, *, force: bool = False) -> None:
        """Install/refresh SideStore for one device on a background thread."""
        with self._emstore_lock:
            if serial in self._emstore_busy:
                return
            self._emstore_busy.add(serial)

        def run() -> None:
            from . import server

            settings = _settings_get()
            try:
                result = server.ensure_installed(
                    serial,
                    force=force,
                    keep_signed=bool(settings.get("keep_signed")),
                    signed_dir=settings.get("signed_dir") or None,
                )
                if result.get("status") == "already_installed":
                    refreshed = server.refresh_sidestore_if_due(serial)
                    if refreshed is not None:
                        result = {**refreshed, "status": "refreshed"}
                self._w.send({
                    "event": "emstore.result",
                    "udid": serial,
                    "result": _as_dict(result),
                })
            except Exception as exc:  # noqa: BLE001 - surfaced in the UI, not fatal
                self._w.send({
                    "event": "emstore.result",
                    "udid": serial,
                    "result": {"status": "error", "error": str(exc)},
                })
            finally:
                with self._emstore_lock:
                    self._emstore_busy.discard(serial)

        threading.Thread(
            target=run, name=f"emload-emstore-{serial[:8]}", daemon=True
        ).start()

    def emstore_status(self, _params: dict[str, Any]) -> dict[str, Any]:
        """Sign-in state, local SideStore IPAs, and per-device install state."""
        from . import server

        payload: dict[str, Any] = {
            "bundle_id": server.SIDESTORE_BUNDLE_ID,
            "repo": server.SIDESTORE_REPO,
            "account": gsa.status(),
            "ipa": [str(path) for path in server.local_candidates()],
            "devices": [],
        }
        seen: set[str] = set()
        for entry in _enrich(device.list_devices()):
            serial = str(entry.get("serial") or "")
            if not serial or serial in seen:
                continue
            seen.add(serial)
            info = entry.get("info") or {}
            row: dict[str, Any] = {
                "udid": serial,
                "name": info.get("DeviceName"),
                "connection": entry.get("connection_type"),
                "emstore_installed": False,
                "emstore_version": None,
            }
            try:
                present = apps.list_installed(serial).get(payload["bundle_id"])
                row["emstore_installed"] = present is not None
                if present:
                    row["emstore_version"] = present.get("version")
            except Exception:  # noqa: BLE001 - unpaired devices can't be read
                row["emstore_installed"] = None
            payload["devices"].append(row)
        return payload

    def emstore_install(self, params: dict[str, Any], progress: Callable[..., None]) -> dict[str, Any]:
        """Install (or refresh) SideStore on one device, or every connected one."""
        from . import server

        serials = (
            [str(params["udid"])]
            if params.get("udid")
            else server.distinct_serials(device.list_devices())
        )
        if not serials:
            raise EmLoadError("No device connected; plug in an iPhone (or pass a UDID).")

        settings = _settings_get()
        keep_signed = bool(params.get("keepSigned", settings.get("keep_signed")))
        signed_dir = params.get("signedDir") or settings.get("signed_dir") or None
        results: list[dict[str, Any]] = []
        failed = 0
        for serial in serials:
            try:
                result = server.ensure_installed(
                    serial,
                    ipa=params.get("ipa") or None,
                    download=bool(params.get("download")),
                    channel=params.get("channel") or None,
                    force=bool(params.get("force")),
                    keep_signed=keep_signed,
                    signed_dir=signed_dir,
                    on_progress=progress,
                )
                if result.get("status") == "already_installed":
                    refreshed = server.refresh_sidestore_if_due(
                        serial, on_progress=progress
                    )
                    if refreshed is not None:
                        result = {**refreshed, "status": "refreshed"}
                results.append(result)
            except EmLoadError as exc:
                failed += 1
                results.append({"udid": serial, "status": "error", "error": str(exc)})
        return {"results": results, "failed": failed}

    # -- sideload ---------------------------------------------------------- #
    def ipa_inspect(self, params: dict[str, Any]) -> dict[str, Any]:
        return ipa.inspect(params["path"])

    def sideload_run(self, params: dict[str, Any], progress: Callable[..., None]) -> dict[str, Any]:
        return sideload.run_sideload(
            params["ipa"],
            params.get("udid"),
            bundle_id=params.get("bundleId") or None,
            display_name=params.get("displayName") or None,
            bundle_version=params.get("version") or None,
            remove_extensions=bool(params.get("removeExtensions", True)),
            remove_uisd=bool(params.get("removeUisd", True)),
            enable_file_sharing=bool(params.get("enableFileSharing", False)),
            keep_signed=bool(params.get("keepSigned", False)),
            signed_dir=params.get("signedDir") or None,
            allow_other_platform=bool(params.get("allowOtherPlatform", False)),
            on_progress=progress,
        )

    # -- library ----------------------------------------------------------- #
    def library_list(self, _params: dict[str, Any]) -> list[dict[str, Any]]:
        return registry.records()

    def library_refresh(self, params: dict[str, Any], progress: Callable[..., None]) -> dict[str, Any]:
        ids = [str(b) for b in _as_list(params.get("bundleIds") or []) if b]
        keep_signed = bool(params.get("keepSigned", False))
        signed_dir = params.get("signedDir") or None
        results: list[dict[str, Any]] = []
        failed = 0
        for bundle_id in ids:
            entry = registry.get(bundle_id)
            if entry is None:
                results.append({"bundle_id": bundle_id, "status": "not_tracked"})
                continue
            try:
                result = sideload.refresh_record(
                    entry,
                    on_progress=progress,
                    keep_signed=keep_signed,
                    signed_dir=signed_dir,
                )
                results.append({"bundle_id": bundle_id, "status": "ok", **result})
            except EmLoadError as exc:
                failed += 1
                results.append({"bundle_id": bundle_id, "status": "error", "error": str(exc)})
        return {"results": results, "failed": failed}

    def library_forget(self, params: dict[str, Any]) -> dict[str, Any]:
        bundle_id = params["bundleId"]
        return {"bundle_id": bundle_id, "forgotten": registry.forget(bundle_id)}

    def apps_uninstall(self, params: dict[str, Any]) -> dict[str, Any]:
        apps.uninstall(params["bundleId"], params.get("udid"))
        return {"bundle_id": params["bundleId"], "uninstalled": True}

    # -- account ----------------------------------------------------------- #
    def account_status(self, _params: dict[str, Any]) -> dict[str, Any]:
        return gsa.status()

    def account_resume(self, _params: dict[str, Any]) -> dict[str, Any]:
        for account in gsa.list_accounts():
            if account.get("has_auth_token"):
                return gsa.use_account(account["email"])
        return {"status": "nothing_to_resume"}

    def account_login(self, params: dict[str, Any]) -> dict[str, Any]:
        email = params["email"]
        password = params["password"]
        result = gsa.begin_login(email, password)
        if result.get("status") == "2fa_required":
            _pending_passwords[email] = password
        else:
            _pending_passwords.pop(email, None)
        return result

    def account_login_2fa(self, params: dict[str, Any]) -> dict[str, Any]:
        email = params["email"]
        code = params["code"]
        password = _pending_passwords.pop(email, None)
        if password is None:
            raise ValueError("no pending sign-in for that account; start over")
        return gsa.complete_2fa(email, password, code)

    def account_logout(self, params: dict[str, Any]) -> dict[str, Any]:
        return gsa.logout(params.get("email"))

    def account_teams(self, _params: dict[str, Any]) -> list[dict[str, Any]]:
        from . import developer

        return developer.list_teams()

    # -- provisioning ------------------------------------------------------ #
    def provision_ensure(self, params: dict[str, Any]) -> dict[str, Any]:
        return provision.ensure_provisioned_for_device(params["udid"])

    def provision_reset(self, params: dict[str, Any]) -> dict[str, Any]:
        return provision.reset_app_id(params["udid"])

    # -- settings / signing ------------------------------------------------ #
    def settings_get(self, _params: dict[str, Any]) -> dict[str, Any]:
        return _settings_get()

    def settings_set(self, params: dict[str, Any]) -> dict[str, Any]:
        return _settings_set(params)

    def signing_status(self, _params: dict[str, Any]) -> dict[str, Any]:
        return signing.signing_status()

    def signing_download(self, _params: dict[str, Any]) -> dict[str, Any]:
        return _as_dict(signing.download_zsign())

    def signed_status(self, params: dict[str, Any]) -> dict[str, Any]:
        return _as_dict(sideload.signed_status(params.get("directory")))

    def signed_clean(self, params: dict[str, Any]) -> dict[str, Any]:
        return _as_dict(sideload.clean_signed(params.get("directory")))

    # -- Misc tweaks ------------------------------------------------------- #
    def nugget_schema(self, params: dict[str, Any]) -> dict[str, Any]:
        return nugget_schema.describe(params["group"])

    def nugget_set(self, params: dict[str, Any]) -> dict[str, Any]:
        control = nugget_schema.set_control(
            params["group"],
            params["id"],
            state=params.get("state"),
            value=params.get("value"),
            checked=params.get("checked"),
        )
        return {"control": control}

    def nugget_apply(self, params: dict[str, Any], progress: Callable[..., None]) -> dict[str, Any]:
        options = nugget_schema.apply_options(
            respring=bool(params.get("respring")),
            reboot=bool(params.get("reboot", True)),
            apply_method=params.get("applyMethod", "auto"),
            transfer_mode=params.get("transferMode", "localhost"),
            skip_setup=bool(params.get("skipSetup", True)),
        )
        return _as_dict(_nugget_apply(params["udid"], options, progress))

    def nugget_respring(self, params: dict[str, Any], progress: Callable[..., None]) -> dict[str, Any]:
        from .nugget import respring_device

        return _as_dict(respring_device(params["udid"], on_progress=progress))


def _nugget_apply(udid: str, options: dict[str, Any], progress: Callable[..., None]) -> Any:
    from .nugget import apply_tweaks

    return apply_tweaks(udid, on_progress=progress, **options)


# ``progress`` is optional for most handlers; this table records which ones
# accept the streaming callback so dispatch stays a simple loop.
_STREAMING = {
    "sideload.run": "sideload_run",
    "library.refresh": "library_refresh",
    "emstore.install": "emstore_install",
    "nugget.apply": "nugget_apply",
    "nugget.respring": "nugget_respring",
}

#: Public method name -> Handlers attribute. Underscored names never leak out.
_METHODS = {
    "version": "version",
    "doctor.check": "doctor",
    "fs.browse": "browse",
    "devices.list": "devices_list",
    "devices.raw": "devices_raw",
    "devices.info": "devices_info",
    "watch.start": "watch_start",
    "watch.stop": "watch_stop",
    "ipa.inspect": "ipa_inspect",
    "sideload.run": "sideload_run",
    "library.list": "library_list",
    "library.refresh": "library_refresh",
    "library.forget": "library_forget",
    "apps.uninstall": "apps_uninstall",
    "account.status": "account_status",
    "account.resume": "account_resume",
    "account.login": "account_login",
    "account.login2fa": "account_login_2fa",
    "account.logout": "account_logout",
    "account.teams": "account_teams",
    "provision.ensure": "provision_ensure",
    "provision.reset": "provision_reset",
    "settings.get": "settings_get",
    "settings.set": "settings_set",
    "signing.status": "signing_status",
    "signing.download": "signing_download",
    "signed.status": "signed_status",
    "signed.clean": "signed_clean",
    "emstore.status": "emstore_status",
    "emstore.install": "emstore_install",
    "nugget.schema": "nugget_schema",
    "nugget.set": "nugget_set",
    "nugget.apply": "nugget_apply",
    "nugget.respring": "nugget_respring",
}


# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #
def _run_request(
    handlers: Handlers,
    writer: _Writer,
    pool: ThreadPoolExecutor,
    request: dict[str, Any],
) -> None:
    request_id = request.get("id")
    method = request.get("method")
    params = request.get("params") or {}

    def dispatch() -> None:
        def progress(phase: str, percent: Any, step: str | None) -> None:
            writer.send({
                "event": "progress",
                "id": request_id,
                "phase": phase,
                "percent": percent,
                "step": step,
            })

        def log(message: str) -> None:
            writer.send({"event": "log", "id": request_id, "message": message})

        try:
            name = _METHODS.get(str(method))
            if name is None:
                raise ValueError(f"unknown method: {method!r}")
            handler = getattr(handlers, name)
            if method in _STREAMING:
                result = handler(params, progress)
            else:
                result = handler(params)
            writer.send({"id": request_id, "ok": True, "result": result})
        except EmLoadError as exc:
            writer.send({
                "id": request_id,
                "ok": False,
                "error": str(exc),
                "kind": "EmLoadError",
            })
        except KeyboardInterrupt:
            writer.send({
                "id": request_id,
                "ok": False,
                "error": "interrupted",
                "kind": "Interrupted",
            })
        except Exception as exc:  # noqa: BLE001 - never kill the bridge
            log(traceback.format_exc())
            writer.send({
                "id": request_id,
                "ok": False,
                "error": str(exc) or exc.__class__.__name__,
                "kind": exc.__class__.__name__,
            })

    pool.submit(dispatch)


def serve(stdin: Any = None, stdout: Any = None) -> int:
    """Run the bridge until stdin closes (the front end exited)."""
    _force_utf8()
    stdin = stdin or sys.stdin
    writer = _Writer(stdout or sys.stdout)
    handlers = Handlers(writer)
    pool = ThreadPoolExecutor(max_workers=_MAX_WORKERS, thread_name_prefix="emload-rpc")

    writer.send({
        "event": "ready",
        "version": __version__,
        "python": sys.version.split()[0],
    })

    try:
        for line in stdin:
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
            except ValueError:
                writer.send({
                    "id": None,
                    "ok": False,
                    "error": f"invalid JSON: {line[:200]}",
                    "kind": "ProtocolError",
                })
                continue
            if not isinstance(request, dict):
                writer.send({
                    "id": None,
                    "ok": False,
                    "error": "request must be a JSON object",
                    "kind": "ProtocolError",
                })
                continue
            _run_request(handlers, writer, pool, request)
    finally:
        stop = handlers._watch_stop
        if stop is not None:
            stop.set()
        handlers.close()
        pool.shutdown(wait=False, cancel_futures=True)
    return 0


def main() -> int:
    return serve()


if __name__ == "__main__":
    sys.exit(main())
