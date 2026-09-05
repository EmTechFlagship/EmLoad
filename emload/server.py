"""EmLoad server - the EmStore app's AltServer alternative.

This is the EmStoreServer: EmLoad's own server for installing the upcoming
AltStore/SideStore alternative, **EmStore**. It ships two things:

1. **EmStore.ipa auto-download + auto-install**: resolve the EmStore IPA
   (an explicit ``--ipa`` path, a locally-built copy, or the latest published
   GitHub release - stable / alpha / nightly, downloaded into EmLoad's data
   dir), sideload it onto every iPhone/iPad as it attaches, and keep watching
   usbmuxd. This is what ``emload emstore-server install/watch`` and the GUI's
   EmStoreServer toggle run.

2. **HTTP API** (JSON in/out) so the EmStore app on an iPhone/iPad can ask the
   PC to do the things the phone cannot (signing with an Apple ID, provisioning,
   installing IPAs):

    GET  /api/status       service info: sign-in state, local IPA, recent jobs
    GET  /api/devices      devices currently visible to usbmuxd
    GET  /api/apps?udid=   apps installed on one device
    POST /api/refresh      re-sign + reinstall recorded apps before profiles expire
                           body: {"udid": ..., "bundle_ids": [...], "all": bool,
                                  "within_days": 2.0}
    POST /api/install      sideload the EmStore app itself (like AltServer does)
                           body: {"udid": ..., "force": bool}
    GET  /api/jobs         jobs, newest first
    GET  /api/jobs/<id>    one job, including its log and results

Long-running work (refresh/install) runs on a single serial background worker;
the API returns 202 with a ``job_id`` immediately and the client polls
``/api/jobs/<id>``. Jobs are kept in memory only (volatile, never spilled).

Security: deliberately bare-bones. There is no authentication; anyone who can
reach the port can trigger installs with your signed-in Apple ID. Bind to
127.0.0.1 (``--host``) or keep it on a trusted LAN only. ``/api/status`` reports
sign-in state without echoing session tokens.
"""

from __future__ import annotations

import json
import queue
import requests
import sys
import threading
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse

from . import __version__, apps, device, gsa, paths, registry, sideload, tls
from .errors import EmLoadError

#: Human-readable service name (shown in /api/status + the HTTP Server header).
SERVICE_NAME = "EmStoreServer"

#: Default HTTP port. Deliberately not AltServer's 12345, so both can coexist.
DEFAULT_PORT = 1740

#: Jobs are dropped oldest-first once this many have accumulated (the UI only
#: ever shows a handful, and finished jobs are not worth memory).
_JOB_LIMIT = 100


# --------------------------------------------------------------------------- #
# EmStore IPA auto-download & auto-install (the server's default job)
# --------------------------------------------------------------------------- #
#: Bundle identifier of the EmStore app (see EmStore's ``Build.xcconfig``).
EMSTORE_BUNDLE_ID = "com.SideStore.SideStore"

#: GitHub repository that publishes EmStore builds as releases.
EMSTORE_REPO = "embabyty/EmStore"

#: Name the downloaded IPA is cached under in EmLoad's data dir.
EMSTORE_IPA_NAME = "EmStore.ipa"

_GH_API = "https://api.github.com/repos/{repo}/releases?per_page=30"
_GH_TIMEOUT = 30


class EmStoreServerError(EmLoadError):
    """The server could not find, fetch, or install the EmStore app."""


def emstore_dir() -> Path:
    """EmLoad's folder for the downloaded EmStore IPA (created if missing)."""
    path = paths.data_dir() / "emstore"
    path.mkdir(parents=True, exist_ok=True)
    return path


def local_candidates() -> list[Path]:
    """A built EmStore IPA found on this machine, newest first.

    Looks beside the EmStore source checkout (where a local ``xcodebuild`` or
    the repo's CI both drop ``SideStore.ipa``) and in EmLoad's own data dir.
    """
    home = Path.home()
    candidates = [
        home / "EmStore" / "SideStore.ipa",
        home / "EmStore" / "build" / "SideStore.ipa",
        home / "EmStore" / "EmStore.ipa",
        emstore_dir() / EMSTORE_IPA_NAME,
    ]
    found = [path for path in candidates if path.is_file()]
    found.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    return found


def _select_release_asset(
    releases: list[dict[str, Any]], channel: str | None
) -> tuple[dict[str, Any], dict[str, Any]] | None:
    """Pick ``(release, ipa_asset)`` from GitHub release JSON.

    Drafts are never considered. ``channel`` narrows by matching the release
    tag/name (``stable``, ``alpha``, ``nightly``); without it, the newest
    non-prerelease release is preferred, falling back to prereleases (nightly
    and alpha builds are marked prerelease by the EmStore CI). Returns
    ``None`` when nothing has an ``.ipa`` asset.
    """
    usable = [r for r in releases if not r.get("draft")]
    if channel:
        needle = channel.lower()
        matching = [
            r for r in usable
            if needle in f"{r.get('name', '')} {r.get('tag_name', '')}".lower()
        ]
        if matching:
            usable = matching

    candidates = [r for r in usable if not r.get("prerelease")]
    if not candidates:
        candidates = usable  # nightlies/alphas are prereleases - take what exists

    for release in candidates:
        asset = _ipa_asset(release)
        if asset is not None:
            return release, asset
    return None


def _ipa_asset(release: dict[str, Any]) -> dict[str, Any] | None:
    for asset in release.get("assets") or []:
        name = asset.get("name") or ""
        if name.lower().endswith(".ipa"):
            return asset
    return None


def download_release_ipa(
    repo: str = EMSTORE_REPO,
    channel: str | None = None,
    dest: Path | None = None,
) -> Path:
    """Download the latest channel IPA from EmStore's GitHub releases.

    The file is streamed to a temp file and renamed into place only after its
    ZIP magic header is verified, so a truncated download is never mistaken for
    a good IPA.
    """
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "EmLoad/EmStoreServer",
    }
    try:
        response = requests.get(
            _GH_API.format(repo=repo), headers=headers, timeout=_GH_TIMEOUT,
            verify=tls.ca_bundle(),
        )
        response.raise_for_status()
        releases = response.json()
    except requests.RequestException as exc:
        raise EmStoreServerError(
            f"Could not fetch EmStore releases from GitHub: {exc}"
        ) from exc

    picked = _select_release_asset(releases, channel)
    if picked is None:
        label = f" for channel '{channel}'" if channel else ""
        raise EmStoreServerError(
            f"No EmStore build{label} has been published to GitHub yet "
            f"({repo}). Build the IPA locally and pass --ipa, or wait for a release."
        )
    release, asset = picked
    url = asset["browser_download_url"]

    try:
        download = requests.get(url, timeout=_GH_TIMEOUT, verify=tls.ca_bundle())
        download.raise_for_status()
        raw = download.content
    except requests.RequestException as exc:
        raise EmStoreServerError(
            f"Could not download EmStore IPA from GitHub: {exc}"
        ) from exc

    if not raw.startswith(b"PK\x03\x04"):
        raise EmStoreServerError(
            "The file GitHub served is not an IPA (missing ZIP header); "
            "the release may be misconfigured."
        )

    target = dest or emstore_dir() / EMSTORE_IPA_NAME
    tmp = target.with_name(target.name + ".part")
    tmp.write_bytes(raw)
    tmp.replace(target)
    return target


def resolve_ipa(
    explicit: str | None = None,
    *,
    download: bool = False,
    channel: str | None = None,
) -> tuple[Path, str]:
    """The EmStore IPA to sideload, as ``(path, source label)``.

    ``download=True`` always fetches the newest published build (overwriting
    the cache). Otherwise an explicit path wins, then local candidates, then a
    fresh download.
    """
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_file():
            raise EmStoreServerError(f"No EmStore IPA at '{path}'.")
        return path.resolve(), "explicit"

    if download:
        return download_release_ipa(channel=channel), f"github:{channel or 'latest'}"

    local = local_candidates()
    if local:
        return local[0], f"local:{local[0].name}"

    return download_release_ipa(channel=channel), f"github:{channel or 'latest'}"


def ensure_installed(
    udid: str,
    *,
    ipa: str | None = None,
    download: bool = False,
    channel: str | None = None,
    force: bool = False,
    display_name: str | None = None,
    bundle_id: str | None = None,
    remove_extensions: bool = True,
    remove_uisd: bool = True,
    enable_file_sharing: bool = False,
    keep_signed: bool = False,
    signed_dir: str | None = None,
    allow_other_platform: bool = False,
    on_progress: sideload.ProgressFn | None = None,
) -> dict[str, Any]:
    """Make sure EmStore is sideloaded on ``udid``.

    Returns either ``{"status": "already_installed", ...}`` when the app is
    already there and ``force`` is false, or the ``sideload.run_sideload``
    result tagged ``"status": "installed"``.
    """
    account = gsa.status()
    if not account.get("authenticated"):
        raise EmStoreServerError(
            "not signed in to an Apple ID; run 'emload login' first (the server "
            "will retry on the next device attach)"
        )

    ipa_path, source = resolve_ipa(ipa, download=download, channel=channel)
    target_bundle = bundle_id or EMSTORE_BUNDLE_ID

    installed = apps.list_installed(udid)
    present = installed.get(target_bundle)
    if present and not force:
        return {
            "status": "already_installed",
            "bundle_id": target_bundle,
            "udid": udid,
            "version": present.get("version"),
            "ipa_source": source,
        }

    result = sideload.run_sideload(
        str(ipa_path),
        udid,
        bundle_id=bundle_id or EMSTORE_BUNDLE_ID,
        display_name=display_name,
        remove_extensions=remove_extensions,
        remove_uisd=remove_uisd,
        enable_file_sharing=enable_file_sharing,
        keep_signed=keep_signed,
        signed_dir=signed_dir,
        allow_other_platform=allow_other_platform,
        on_progress=on_progress,
    )
    result["status"] = "installed"
    result["ipa_source"] = source
    return result


def distinct_serials(entries: list[dict[str, Any]]) -> list[str]:
    """Distinct device serials in a usbmux event, in first-seen order.

    usbmux reports one row per transport, so a single phone plugged in over USB
    and reachable over Wi-Fi appears twice under one serial.
    """
    seen: list[str] = []
    for entry in entries:
        serial = entry.get("serial")
        if serial and str(serial) not in seen:
            seen.append(str(serial))
    return seen


def new_serials(known: set[str], entries: list[dict[str, Any]]) -> list[str]:
    """Serials in ``entries`` that are not yet tracked in ``known``."""
    return [serial for serial in distinct_serials(entries) if serial not in known]


def watch_and_install(
    stop: threading.Event,
    *,
    on_log: Callable[[str], None] | None = None,
    on_result: Callable[[dict[str, Any]], None] | None = None,
    filter_udid: str | None = None,
    initial: list[dict[str, Any]] | None = None,
    **install_kwargs: Any,
) -> None:
    """Run until ``stop`` is set: install EmStore on every device as it attaches.

    ``initial`` is a current usbmux listing (from ``device.list_devices()``)
    processed before the listener starts, so phones that were already connected
    are not ignored. Calls ``on_log(message)`` for human-readable progress and
    ``on_result(result)`` after each finished install attempt. Installations
    run on per-device worker threads so the usbmux listener never blocks, and a
    device that fails (untrusted, not signed in, offline) is retried the next
    time it attaches.
    """
    log: Callable[[str], None] = on_log or (lambda _m: None)
    known: set[str] = set()
    busy: set[str] = set()

    def _install_one(serial: str) -> None:
        try:
            def relay(phase: str, percent: Any, step: str | None) -> None:
                if step:
                    log(f"[{serial}] {step}")

            result = ensure_installed(serial, on_progress=relay, **install_kwargs)
            log(f"[{serial}] {result['status'].replace('_', ' ')}.")
            if on_result:
                on_result(result)
        except EmLoadError as exc:
            log(f"[{serial}] skipped: {exc}")
        except Exception as exc:  # noqa: BLE001 - keep the watcher alive
            log(f"[{serial}] failed: {exc}")
        finally:
            busy.discard(serial)

    def handle(entries: list[dict[str, Any]]) -> None:
        current = set(distinct_serials(entries))
        # A serial that left the bus may re-attach later (e.g. to retry after a
        # failed first install) - forget it so "new" stays meaningful.
        for departed in known - current:
            known.discard(departed)

        for serial in new_serials(known, entries):
            known.add(serial)
            if filter_udid and serial != filter_udid:
                continue
            if serial in busy:
                continue
            busy.add(serial)
            threading.Thread(target=_install_one, args=(serial,), daemon=True).start()

    def emit(entry: dict[str, Any]) -> None:
        if entry.get("name") == "devices":
            handle(entry.get("data") or [])

    if initial:
        handle(initial)
    device.run_usbmux_watch(emit, stop)


def _now_iso() -> str:
    """UTC timestamp for job bookkeeping (ISO 8601, seconds precision)."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _now_local() -> datetime:
    """Local time for human-readable log lines ([HH:MM:SS])."""
    return datetime.now().astimezone()


class JobStore:
    """In-memory job bookkeeping, safe to touch from HTTP and worker threads."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._jobs: dict[str, dict[str, Any]] = {}

    def create(self, action: str, params: dict[str, Any]) -> dict[str, Any]:
        """Register a new job and return its description (already published)."""
        job: dict[str, Any] = {
            "job_id": uuid.uuid4().hex[:12],
            "action": action,
            "params": params,
            "status": "queued",
            "log": [],
            "results": [],
            "created_at": _now_iso(),
            "updated_at": _now_iso(),
            "finished_at": None,
        }
        with self._lock:
            self._jobs[job["job_id"]] = job
            while len(self._jobs) > _JOB_LIMIT:
                oldest = min(self._jobs, key=lambda k: self._jobs[k]["created_at"])
                del self._jobs[oldest]
        return dict(job)

    def get(self, job_id: str) -> dict[str, Any] | None:
        with self._lock:
            job = self._jobs.get(job_id)
            return dict(job) if job else None

    def list(self) -> list[dict[str, Any]]:
        with self._lock:
            jobs = sorted(
                self._jobs.values(), key=lambda j: j["created_at"], reverse=True
            )
            return [dict(job) for job in jobs]

    def touch(self, job_id: str, **fields: Any) -> None:
        """Apply partial updates (results, summary, ...)."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return
            job.update(fields)
            job["updated_at"] = _now_iso()

    def append_log(self, job_id: str, message: str) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return
            job["log"].append(f"[{_now_local().strftime('%H:%M:%S')}] {message}")
            job["updated_at"] = _now_iso()

    def finish(self, job_id: str) -> None:
        """Mark a job done. Callers set ``results``/``summary`` via :meth:`touch` first."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return
            job["status"] = "done"
            job["finished_at"] = _now_iso()
            job["updated_at"] = _now_iso()

    def fail(self, job_id: str, error: str) -> None:
        """Mark a job done with an overall error string."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return
            job["status"] = "done"
            job["error"] = error
            job["finished_at"] = _now_iso()
            job["updated_at"] = _now_iso()


class HttpError(Exception):
    """A request-level problem that maps to a 4xx HTTP response."""

    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# --------------------------------------------------------------------------- #
# Job runners (the long-running work behind /api/refresh and /api/install)
# --------------------------------------------------------------------------- #
def _progress_log(
    log: Callable[[str], None],
    _phase: str,
    _percent: Any,
    step: str | None,
) -> None:
    """A sideload ``on_progress`` callback that feeds the job log."""
    if step:
        log(step)


def _run_refresh(
    jobs: JobStore,
    job_id: str,
    params: dict[str, Any],
    log: Callable[[str], None],
) -> None:
    """Re-sign + reinstall recorded apps before their profiles expire."""
    udid = params.get("udid") or None
    bundle_ids = params.get("bundle_ids") or []
    all_records = bool(params.get("all"))
    within_days = float(params.get("within_days") or 2.0)

    if bundle_ids:
        targets = [
            entry
            for bundle_id in bundle_ids
            if (entry := registry.get(bundle_id)) is not None
            and (not udid or entry.get("udid") == udid)
        ]
    else:
        candidates = registry.records() if all_records else registry.due(within_days)
        targets = [entry for entry in candidates if not udid or entry.get("udid") == udid]

    if not targets:
        log("nothing to refresh")
        jobs.touch(job_id, summary="nothing to refresh")
        jobs.finish(job_id)
        return

    log(f"refreshing {len(targets)} app(s)" + (f" on {udid}" if udid else ""))
    results: list[dict[str, Any]] = []
    failed = 0
    for entry in targets:
        label = entry.get("name") or entry.get("bundle_id") or "app"
        log(f"{label}: re-signing and reinstalling\u2026")
        try:
            result = sideload.refresh_record(
                entry,
                on_progress=lambda phase, percent, step: _progress_log(
                    log, phase, percent, step
                ),
            )
            results.append({"bundle_id": entry["bundle_id"], "status": "ok", **result})
        except EmLoadError as exc:
            failed += 1
            results.append({
                "bundle_id": entry["bundle_id"],
                "status": "error",
                "error": str(exc),
            })
            log(f"{label}: {exc}")
    summary = f"{len(results) - failed}/{len(results)} refreshed"
    jobs.touch(job_id, results=results, summary=summary)
    jobs.finish(job_id)
    log(summary)


def _run_install(
    jobs: JobStore,
    job_id: str,
    params: dict[str, Any],
    log: Callable[[str], None],
) -> None:
    """Sideload the EmStore app itself onto one device (like AltServer bootstraps AltStore)."""
    udid = params.get("udid") or device.resolve_serial()
    result = ensure_installed(
        udid,
        ipa=params.get("ipa"),
        download=bool(params.get("download")),
        channel=params.get("channel"),
        force=bool(params.get("force")),
        display_name=params.get("display_name"),
        bundle_id=params.get("bundle_id"),
        keep_signed=bool(params.get("keep_signed")),
        signed_dir=params.get("signed_dir"),
        on_progress=lambda phase, percent, step: _progress_log(
            log, phase, percent, step
        ),
    )
    status = result.get("status", "done").replace("_", " ")
    jobs.touch(job_id, results=[result], summary=status)
    jobs.finish(job_id)
    log(status)


#: Action registry consulted by the worker at run time (tests swap it wholesale).
_ACTIONS: dict[str, Callable[[JobStore, str, dict[str, Any], Callable[[str], None]], None]] = {
    "refresh": _run_refresh,
    "install": _run_install,
}


class JobWorker:
    """Single serial background thread for long-running jobs.

    Submissions are queued and run one at a time in arrival order, so two refresh
    jobs cannot fight over the same signing cache. The thread is a daemon: the
    process (CLI/GUI) owns the workload's lifetime.
    """

    def __init__(
        self, jobs: JobStore, log: Callable[[str], None] | None = None
    ) -> None:
        self._jobs = jobs
        self._console = log
        self._queue: queue.Queue[tuple[str, str, dict[str, Any]] | None] = queue.Queue()
        self._thread = threading.Thread(
            target=self._loop, name="server-worker", daemon=True
        )

    def start(self) -> None:
        self._thread.start()

    def stop(self, timeout: float = 5.0) -> None:
        """Ask the worker to finish the current job, then exit the loop."""
        self._queue.put(None)
        self._thread.join(timeout=timeout)

    def submit(self, action: str, params: dict[str, Any]) -> dict[str, Any]:
        """Publish a jobs row and enqueue its work; returns the row."""
        job = self._jobs.create(action, params)
        self._queue.put((job["job_id"], action, params))
        return job

    def _loop(self) -> None:
        log: Callable[[str], None] = self._console or (lambda _m: None)
        while True:
            task = self._queue.get()
            if task is None:
                return
            job_id, action, params = task
            runner = _ACTIONS.get(action)
            if runner is None:
                self._jobs.fail(job_id, f"unknown action '{action}'")
                continue
            try:
                runner(self._jobs, job_id, params, log)
            except EmLoadError as exc:
                self._jobs.fail(job_id, str(exc))
            except Exception as exc:  # noqa: BLE001 - a bug must not kill the worker
                self._jobs.fail(job_id, f"unexpected error: {exc}")


# --------------------------------------------------------------------------- #
# HTTP server + handlers
# --------------------------------------------------------------------------- #
class EmStoreHTTPServer(ThreadingHTTPServer):
    """Threaded HTTP server that carries EmStoreServer state to the handlers."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address: tuple[str, int],
        jobs: JobStore,
        worker: JobWorker,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self.jobs = jobs
        self.worker = worker
        self.log = log
        super().__init__(address, ApiHandler)


class ApiHandler(BaseHTTPRequestHandler):
    """JSON API: status/devices/apps/jobs (GET) and refresh/install (POST)."""

    server_version = f"EmStoreServer/{__version__}"
    sys_version = ""  # don't leak the Python version

    def log_message(self, format: str, *args: Any) -> None:
        # Route access lines to the service's own log sink (or nowhere).
        if self.server.log:
            self.server.log(f"[http] {format % args}")

    # ------------------------------------------------------------------ #
    # Helpers
    # ------------------------------------------------------------------ #
    def _send(self, code: int, payload: Any) -> None:
        body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, code: int, message: str) -> None:
        self._send(code, {"error": message})

    def _read_json_body(self) -> dict[str, Any]:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            return {}
        try:
            length = int(raw_length)
        except ValueError as exc:
            raise HttpError(400, "invalid Content-Length") from exc
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        if not raw:
            return {}
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise HttpError(400, f"request body is not valid JSON: {exc}") from exc
        if not isinstance(payload, dict):
            raise HttpError(400, "request body must be a JSON object")
        return payload

    # ------------------------------------------------------------------ #
    # GET routing
    # ------------------------------------------------------------------ #
    def do_GET(self) -> None:
        path, query = _url_parts(self.path)
        try:
            if path == "/":
                self._send(200, {
                    "service": SERVICE_NAME,
                    "version": __version__,
                    "endpoints": [
                        "/api/status", "/api/devices", "/api/apps",
                        "/api/refresh", "/api/install", "/api/jobs",
                        "/api/jobs/<id>",
                    ],
                })
            elif path == "/api/status":
                self._get_status()
            elif path == "/api/devices":
                self._get_devices()
            elif path == "/api/apps":
                self._get_apps(query)
            elif path == "/api/jobs":
                self._send(200, {"jobs": self.server.jobs.list()})
            elif path.startswith("/api/jobs/"):
                self._get_job(path[len("/api/jobs/"):])
            else:
                self._send_error(404, f"unknown endpoint '{path}'")
        except HttpError as exc:
            self._send_error(exc.code, exc.message)
        except EmLoadError as exc:
            self._send_error(400, str(exc))

    def _get_status(self) -> None:
        account = gsa.status()
        state: dict[str, Any] = {
            "authenticated": bool(account.get("authenticated")),
            "account_count": account.get("account_count", 0),
        }
        if account.get("email"):
            state["email"] = account["email"]
        if account.get("team_id"):
            state["team_id"] = account["team_id"]
        self._send(200, {
            "service": SERVICE_NAME,
            "version": __version__,
            "bundle_id": EMSTORE_BUNDLE_ID,
            "repo": EMSTORE_REPO,
            "account": state,
            "ipa": [str(path) for path in local_candidates()],
            "jobs": [
                {
                    "job_id": job["job_id"],
                    "action": job["action"],
                    "status": job["status"],
                    "created_at": job["created_at"],
                }
                for job in self.server.jobs.list()[:5]
            ],
        })

    def _get_devices(self) -> None:
        rows: list[dict[str, Any]] = []
        seen: set[str] = set()
        for entry in device.list_devices():
            serial = str(entry.get("serial") or "")
            if not serial or serial in seen:
                continue
            seen.add(serial)
            row: dict[str, Any] = {
                "udid": serial,
                "connection": entry.get("connection_type"),
            }
            try:
                info = device.get_device_info(serial)
                row["name"] = info.get("DeviceName")
                row["model"] = info.get("ProductType")
                row["os_version"] = info.get("ProductVersion")
            except Exception:  # noqa: BLE001 - unpaired devices can't answer
                pass
            rows.append(row)
        self._send(200, {"devices": rows})

    def _get_apps(self, query: dict[str, list[str]]) -> None:
        udid = query.get("udid", [None])[0]
        try:
            serial = udid or device.resolve_serial()
        except device.DeviceError as exc:
            raise HttpError(400, str(exc)) from exc
        installed = apps.list_installed(serial)
        self._send(200, {
            "udid": serial,
            "apps": [
                {
                    "bundle_id": bundle_id,
                    "name": meta.get("name"),
                    "version": meta.get("version"),
                }
                for bundle_id, meta in sorted(installed.items())
            ],
        })

    def _get_job(self, job_id: str) -> None:
        job = self.server.jobs.get(job_id)
        if job is None:
            self._send_error(404, f"no such job '{job_id}'")
        else:
            self._send(200, job)

    # ------------------------------------------------------------------ #
    # POST routing
    # ------------------------------------------------------------------ #
    def do_POST(self) -> None:
        path, _query = _url_parts(self.path)
        try:
            if path == "/api/refresh":
                self._post_refresh()
            elif path == "/api/install":
                self._post_install()
            else:
                self._send_error(404, f"unknown endpoint '{path}'")
        except HttpError as exc:
            self._send_error(exc.code, exc.message)
        except EmLoadError as exc:
            self._send_error(400, str(exc))

    def _post_refresh(self) -> None:
        body = self._read_json_body()
        udid = body.get("udid") or None
        if udid is not None and not isinstance(udid, str):
            raise HttpError(400, "'udid' must be a string")
        bundle_ids = body.get("bundle_ids") or []
        if not isinstance(bundle_ids, list) or not all(
            isinstance(item, str) for item in bundle_ids
        ):
            raise HttpError(400, "'bundle_ids' must be a list of strings")
        try:
            within_days = float(body.get("within_days", 2.0))
        except (TypeError, ValueError) as exc:
            raise HttpError(400, "'within_days' must be a number") from exc
        job = self.server.worker.submit("refresh", {
            "udid": udid,
            "bundle_ids": bundle_ids,
            "all": bool(body.get("all")),
            "within_days": within_days,
        })
        self._send(202, job)

    def _post_install(self) -> None:
        body = self._read_json_body()
        udid = body.get("udid") or None
        if udid is not None and not isinstance(udid, str):
            raise HttpError(400, "'udid' must be a string")
        allowed = {
            "udid", "force", "ipa", "download", "channel", "display_name",
            "bundle_id", "keep_signed", "signed_dir",
        }
        params = {key: body[key] for key in allowed if key in body}
        job = self.server.worker.submit("install", params)
        self._send(202, job)


# --------------------------------------------------------------------------- #
# Lifecycle
# --------------------------------------------------------------------------- #
def _url_parts(path: str) -> tuple[str, dict[str, list[str]]]:
    """Split a request path into (route, parsed query)."""
    parsed = urlparse(path)
    return parsed.path, parse_qs(parsed.query)


def create_server(
    host: str = "127.0.0.1",
    port: int = 0,
    jobs: JobStore | None = None,
    worker: JobWorker | None = None,
    log: Callable[[str], None] | None = None,
) -> EmStoreHTTPServer:
    """A ready-to-serve EmStoreHTTPServer (won't listen yet)."""
    store = jobs or JobStore()
    w = worker or JobWorker(store, log=log)
    w.start()
    return EmStoreHTTPServer((host, port), store, w, log=log)


def run_server(
    host: str = "127.0.0.1",
    port: int = DEFAULT_PORT,
    jobs: JobStore | None = None,
    worker: JobWorker | None = None,
    log: Callable[[str], None] | None = None,
) -> None:
    """Serve the API until interrupted (Ctrl+C); the CLI calls this directly."""
    httpd = create_server(host, port, jobs=jobs, worker=worker, log=log)
    actual_port = httpd.server_address[1]
    say: Callable[[str], None] = log or (
        lambda message: print(message, file=sys.stderr)
    )
    say(
        f"{SERVICE_NAME} listening on http://{host}:{actual_port} - the "
        "EmStore app's AltServer alternative.\n"
        "No authentication: keep it on a trusted network, or bind to 127.0.0.1.\n"
        "Press Ctrl+C to stop."
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        worker = httpd.worker
        worker.stop()