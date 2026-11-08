"""BookRestore: apply tweaks on iOS 18.2+ (patched devices).

Ported from Nugget27 (AGPL-3.0): ``src/restore/bookrestore.py``.

BookRestore abuses the Books app's download manager to write arbitrary files
to the device. There are two apply methods (see :class:`BookRestoreApplyMethod`):

- **AFC** (default): stream a crafted ``downloads.28.sqlitedb`` + 
  ``BLDatabaseManager.sqlite`` into the Books container over AFC, let
  ``bookassetd`` "download" the payload files (from a localhost HTTP server or
  from the device itself), then kill ``backboardd`` to apply without rebooting.
  Requires Developer Mode and the Books app on the device.
- **Restore**: bundle the payload into a ``BLDatabaseManager.sqlite`` that is
  restored into the Books container through the regular MobileBackup2 restore,
  then respring/reboot.

Adaptations for pymobiledevice3 11.3.1 (AGPL source is written against an
older release):

- ``DvtSecureSocketProxyService`` no longer exists -> :class:`DvtProvider` is
  used as an async context manager over the RSD tunnel.
- ``ProcessControl`` methods are coroutines (awaited here).
- ``OsTraceService.syslog()`` is an async generator and ``get_pid_list()`` is a
  coroutine.
- ``AfcService.set_file_contents`` is a coroutine (awaited via ``maybe_await``).
- The device UDID is passed explicitly (``LockdownClient.udid`` is gone).
- The macOS ``sudo`` prompt path is dropped; tunnels run unprivileged
  (``start-tunnel`` uses the userspace tunnel on Windows).
"""

from __future__ import annotations

import asyncio
import atexit
import contextlib
import functools
import os
import posixpath
import queue
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from enum import Enum
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from typing import Any, Callable

from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.afc import AfcService
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
from pymobiledevice3.services.os_trace import OsTraceService

from .._asyncutil import maybe_await
from .errors import NuggetError
from .restore import FileToRestore, reboot_device

#: Directory shipped with this package holding the crafted BookRestore files.
BOOKRESTORE_ASSET_DIR = Path(__file__).resolve().parent / "assets" / "bookrestore"


class BookRestoreApplyMethod(Enum):
    AFC = 0
    Restore = 1


class BookRestoreFileTransferMethod(Enum):
    LocalHost = 0
    OnDevice = 1


class BooksContainerUuid:
    """Callable holder for the Books container UUID (matches Nugget's callback)."""

    def __init__(self) -> None:
        self.uuid = ""

    def __call__(self, uuid: str | None = None) -> str | None:
        if uuid is None:
            return self.uuid
        self.uuid = (uuid or "").strip()
        return self.uuid


# --------------------------------------------------------------------------- #
# Local HTTP server (serves payload files to the device)
# --------------------------------------------------------------------------- #
def get_lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    finally:
        s.close()


def _start_http_server(directory: str, info_queue: queue.Queue) -> None:
    handler = functools.partial(SimpleHTTPRequestHandler, directory=directory)
    httpd = HTTPServer(("0.0.0.0", 0), handler)
    info_queue.put((get_lan_ip(), httpd.server_port))
    httpd.serve_forever()


def _add_firewall_rule(port: int) -> str | None:
    """Open *port* for inbound TCP (Windows). Returns the rule name or None."""
    if os.name != "nt":
        return None
    rule_name = f"EmLoad_BookRestore_{port}"
    try:
        subprocess.run(
            f'netsh advfirewall firewall add rule name="{rule_name}" '
            f"dir=in action=allow protocol=TCP localport={port}",
            shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return rule_name
    except Exception as e:  # noqa: BLE001 - firewall rules are best-effort
        print(f"Warning: Could not add firewall rule: {e}")
        return None


def _remove_firewall_rule(rule_name: str | None) -> None:
    if not rule_name:
        return
    try:
        subprocess.run(
            f"netsh advfirewall firewall delete rule name=\"{rule_name}\"",
            shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception:  # noqa: BLE001
        pass


#: Currently active BookRestore temp server (served to the device).
_server_folder: str | None = None
#: Name of the firewall rule opened for the local server, if any.
_firewall_rule_name: str | None = None


def create_server_folder() -> str:
    """Create the temp folder that also acts as the HTTP server document root."""
    global _server_folder
    _server_folder = tempfile.mkdtemp(prefix="emload_bookrestore_")
    return _server_folder


def cleanup_server_folder() -> None:
    global _server_folder, _firewall_rule_name
    if _server_folder:
        shutil.rmtree(_server_folder, ignore_errors=True)
        _server_folder = None
    if _firewall_rule_name:
        _remove_firewall_rule(_firewall_rule_name)
        _firewall_rule_name = None


def create_local_server() -> str:
    """Start a one-shot LAN HTTP server for the current ``server_folder``."""
    global _firewall_rule_name
    q: queue.Queue = queue.Queue()
    directory = _server_folder or tempfile.gettempdir()
    thread = threading.Thread(target=_start_http_server, args=(directory, q), daemon=True)
    thread.start()
    ip, port = q.get()
    prefix = f"http://{ip}:{port}"
    print(f"Hosting temporary http server on: {prefix}/")
    _firewall_rule_name = _add_firewall_rule(port)
    return prefix


# --------------------------------------------------------------------------- #
# RSD tunnel
# --------------------------------------------------------------------------- #
def _exit_func(tunnel_proc: subprocess.Popen) -> None:
    with contextlib.suppress(Exception):
        tunnel_proc.terminate()


def create_tunnel(udid: str, progress_callback: Callable[[str], None] | None = None) -> dict:
    """Start ``pymobiledevice3 lockdown start-tunnel`` and return its RSD endpoint.

    With ``--script-mode`` the CLI prints ``ADDRESS PORT`` on stdout once the
    tunnel is up (userspace tunnel on Windows - no admin needed).
    """
    cmd = (
        f'"{sys.executable}" -m pymobiledevice3 lockdown start-tunnel '
        f"--script-mode --udid {udid}"
    )
    try:
        tunnel_process = subprocess.Popen(
            cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
    except OSError as e:
        raise NuggetError(f"Could not start the tunnel process: {e}") from e

    atexit.register(_exit_func, tunnel_process)

    rsd_val: str | None = None
    while True:
        output = tunnel_process.stdout.readline()  # type: ignore[union-attr]
        if output:
            line = output.decode(errors="replace").strip()
            if line:
                rsd_val = line
                break
        if tunnel_process.poll() is not None:
            error = (tunnel_process.stderr.read() or b"").decode(errors="replace")
            if error:
                if "connected" in error:
                    raise NuggetError(
                        "Device not connected.",
                    ) from None
                elif "admin" in error or "permission" in error.lower():
                    raise NuggetError("Admin privileges required for the tunnel.") from None
                else:
                    raise NuggetError(
                        "Error creating the tunnel.\n\n"
                        "If this continues, try the \"BookRestore Restore\" apply method "
                        "in the Miscellaneous dialogs.\n\n" + error
                    ) from None
            break

    if rsd_val is None:
        raise NuggetError(
            "Tunnel process ended without returning connection details. "
            "Check if the device is connected and trusted."
        )

    print(f"Successfully created tunnel: {rsd_val}")
    try:
        address, port_str = rsd_val.split(" ")[0], rsd_val.split(" ")[1]
        return {"address": address, "port": int(port_str)}
    except (IndexError, ValueError) as e:
        raise NuggetError(
            f"Failed to parse tunnel output: '{rsd_val}'. Expected 'Address Port'."
        ) from e


# --------------------------------------------------------------------------- #
# SQLite craft + download tracking
# --------------------------------------------------------------------------- #
_dl_connection: sqlite3.Connection | None = None


def close_dl_connection() -> None:
    global _dl_connection
    if _dl_connection is not None:
        with contextlib.suppress(Exception):
            _dl_connection.close()
        _dl_connection = None


def remove_db_files(db_path: str) -> None:
    for ext in ("", "-shm", "-wal"):
        fpath = db_path + ext
        if os.path.exists(fpath):
            try:
                os.remove(fpath)
            except Exception:  # noqa: BLE001
                pass


async def generate_bldbmanager(
    files: list[FileToRestore],
    out_file: str,
    afc: AfcService,
    server_prefix: str | None = None,
    server_folder: str | None = None,
) -> int:
    """Build a crafted ``BLDatabaseManager.sqlite`` describing the payload.

    Returns the number of payload rows (``z_id``) written.
    """
    global _dl_connection
    dl_manager = BOOKRESTORE_ASSET_DIR / "BLDatabaseManager.sqlite"
    shutil.copyfile(dl_manager, out_file)
    _dl_connection = sqlite3.connect(out_file)
    dl_cursor = _dl_connection.cursor()
    # make sure to clear the rows so it doesn't error
    dl_cursor.execute("DELETE FROM ZBLDOWNLOADINFO")
    file_attr_path = BOOKRESTORE_ASSET_DIR / "zfileattributes.plist"
    with open(file_attr_path, "rb") as attr_file:
        attr_data = attr_file.read()
        print(len(attr_data))

    z_id = 0
    for file in files:
        if file.domain not in ("", None):
            continue
        path, file_name = os.path.split(file.restore_path)
        print(f"including {file.restore_path}")
        media_folder = file_name
        # local files go through the HTTP server; everything else via AFC media + path traversal
        if file.restore_path.startswith("/var/mobile") or file.restore_path.startswith("/private/var/mobile"):
            if server_prefix is None:
                continue
            zassetpath = file.restore_path
            zplistpath = zassetpath
            zdownloadid = zassetpath
            zurl = f"{server_prefix}/{file_name}"
            # copy file to the server
            with open(os.path.join(server_folder, file_name), "wb") as temp_write:
                temp_write.write(file.contents)
        else:
            zurl = "https://www.google.com/robots.txt"
            if len(file.contents) > 0:
                zdownloadid = "../../../../../.."
                zassetpath = f"{file.restore_path}.zassetpath"
                media_folder = file_name
                zplistpath = f"/var/mobile/Media/{media_folder}"
                await maybe_await(afc.set_file_contents(media_folder, file.contents))
            else:
                zdownloadid = ""
                zassetpath = file.restore_path
                zplistpath = file.restore_path
            if path.startswith("/"):
                zdownloadid += file.restore_path
            else:
                zdownloadid += f"/{file.restore_path}"
        z_id += 1
        dl_cursor.execute(
            f"""
            INSERT INTO ZBLDOWNLOADINFO (Z_PK, Z_ENT, Z_OPT, ZACCOUNTIDENTIFIER, ZCLEANUPPENDING, ZFAMILYACCOUNTIDENTIFIER, ZISAUTOMATICDOWNLOAD, ZISLOCALCACHESERVER, ZNUMBEROFBYTESTOHASH, ZPERSISTENTIDENTIFIER, ZPUBLICATIONVERSION, ZSIZE, ZSTATE, ZSTOREIDENTIFIER, ZLASTSTATECHANGETIME, ZSTARTTIME, ZASSETPATH, ZBUYPARAMETERS, ZCANCELDOWNLOADURL, ZCLIENTIDENTIFIER, ZCOLLECTIONARTISTNAME, ZCOLLECTIONTITLE, ZDOWNLOADID, ZGENRE, ZKIND, ZPLISTPATH, ZSUBTITLE, ZTHUMBNAILIMAGEURL, ZTITLE, ZTRANSACTIONIDENTIFIER, ZURL, ZFILEATTRIBUTES)
            VALUES ({z_id}, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 765107108, 767991550.119197, 767991353.245275, '{zassetpath}', 'productType=PUB&price=0&salableAdamId=765107106&pricingParameters=PLUS&pg=default&mtApp=com.apple.iBooks&mtEventTime=1746298553233&mtOsVersion=18.4.1&mtPageId=SearchIncrementalTopResults&mtPageType=Search&mtPageContext=search&mtTopic=xp_amp_bookstore&mtRequestId=35276ff6-5c8b-4136-894e-b6d8fc7677b3', 'https://p19-buy.itunes.apple.com/WebObjects/MZFastFinance.woa/wa/songDownloadDone?download-id=J19N_PUB_190099164604738&cancel=1', '4GG2695MJK.com.apple.iBooks', 'idk', '{file_name} file', '{zdownloadid}', 'Contemporary Romance', 'ebook', '{zplistpath}', 'Cartas de Amor a la Luna', 'https://is1-ssl.mzstatic.com/image/thumb/Publication126/v4/3d/b6/0a/3db60a65-b1a5-51c3-b306-c58870663fd3/Portada.jpg/200x200bb.jpg', 'Cartas de Amor a la Luna', 'J19N_PUB_190099164604738', '{zurl}', (?));
            """,
            (sqlite3.Binary(attr_data),),
        )
    _dl_connection.commit()
    return z_id


# --------------------------------------------------------------------------- #
# Core apply (runs inside the RSD + DVT session)
# --------------------------------------------------------------------------- #
async def apply_bookrestore_files(
    files: list[FileToRestore],
    rsd: RemoteServiceDiscoveryService,
    dvt: DvtProvider,
    books_uuid_callback: BooksContainerUuid,
    progress_callback: Callable[[str], None] | None = None,
    transfer_mode: BookRestoreFileTransferMethod = BookRestoreFileTransferMethod.LocalHost,
    do_full_reboot: bool = False,
) -> None:
    if progress_callback is None:
        progress_callback = lambda x: None

    server_prefix: str | None = None
    if transfer_mode == BookRestoreFileTransferMethod.LocalHost:
        server_prefix = create_local_server()

    afc = AfcService(lockdown=rsd)
    pc = ProcessControl(dvt)

    # --- Get the Books container UUID (from a prior download or ask the user) ---
    uuid = (books_uuid_callback() or "").strip()
    if len(uuid) < 10:
        try:
            await pc.launch("com.apple.iBooks")
        except Exception as e:  # noqa: BLE001
            raise NuggetError(f"Error launching the Books app: {e!r}") from e
        progress_callback("Please open the Books app and download a book to continue.")
        os_trace = OsTraceService(lockdown=rsd)
        async for syslog_entry in os_trace.syslog():
            if (posixpath.basename(syslog_entry.filename) != "bookassetd") or \
                    "/Documents/BLDownloads/" not in syslog_entry.message:
                continue
            uuid = syslog_entry.message.split("/var/containers/Shared/SystemGroup/")[1] \
                .split("/Documents/BLDownloads")[0]
            books_uuid_callback(uuid)
            break

    sqlite_path = BOOKRESTORE_ASSET_DIR / "downloads.28.sqlitedb"
    bldb_local_prefix = (
        f"/private/var/containers/Shared/SystemGroup/{uuid}/Documents/"
        "BLDatabaseManager/BLDatabaseManager.sqlite"
    )

    temp_dir = tempfile.gettempdir()
    temp_db_path = os.path.join(temp_dir, f"emload_db_{uuid}.sqlite")
    temp_dl_manager: str | None = None
    if transfer_mode == BookRestoreFileTransferMethod.LocalHost:
        temp_dl_manager = os.path.join(_server_folder, "tmp.BLDatabaseManager.sqlite")
        remove_db_files(temp_dl_manager)

    try:
        shutil.copyfile(sqlite_path, temp_db_path)

        connection = sqlite3.connect(temp_db_path)
        cursor = connection.cursor()
        cursor.execute(
            f"""
            UPDATE asset
            SET local_path = CASE
                WHEN local_path LIKE '%/BLDatabaseManager.sqlite'
                    THEN '{bldb_local_prefix}'
                WHEN local_path LIKE '%/BLDatabaseManager.sqlite-shm'
                    THEN '{bldb_local_prefix}-shm'
                WHEN local_path LIKE '%/BLDatabaseManager.sqlite-wal'
                    THEN '{bldb_local_prefix}-wal'
            END
            WHERE local_path LIKE '/private/var/containers/Shared/SystemGroup/%/Documents/BLDatabaseManager/BLDatabaseManager.sqlite%'
            """
        )
        if transfer_mode == BookRestoreFileTransferMethod.LocalHost:
            bldb_server_prefix = f"{server_prefix}/tmp.BLDatabaseManager.sqlite"
        else:
            bldb_server_prefix = (
                "https://github.com/leminlimez/Nugget/raw/refs/heads/main/"
                ".on_device_remote_files/BLDatabaseManager"
            )
            # On-device mode needs a pre-built db variant; MobileGestalt and
            # Feature Flags variants exist upstream, so build that suffix here.
            combine_char = "-"
            if any(file.restore_path.endswith("com.apple.MobileGestalt.plist") for file in files):
                bldb_server_prefix += f"{combine_char}mga"
                combine_char = "+"
                if any(file.restore_path.endswith("com.apple.iokit.IOMobileGraphicsFamily.plist") for file in files):
                    bldb_server_prefix += f"{combine_char}iokit"
            if any(file.restore_path.endswith("Global.plist") for file in files):
                bldb_server_prefix += f"{combine_char}ff"
            bldb_server_prefix += ".sqlite"
        cursor.execute(
            f"""
            UPDATE asset
            SET url = CASE
                WHEN url LIKE '%/BLDatabaseManager.sqlite'
                    THEN '{bldb_server_prefix}'
                WHEN url LIKE '%/BLDatabaseManager.sqlite-shm'
                    THEN '{bldb_server_prefix}-shm'
                WHEN url LIKE '%/BLDatabaseManager.sqlite-wal'
                    THEN '{bldb_server_prefix}-wal'
            END
            WHERE url LIKE '%/BLDatabaseManager.sqlite%'
            """
        )
        connection.commit()

        procs = (await OsTraceService(lockdown=rsd).get_pid_list()).get("Payload")
        pid_bookassetd = next(
            (pid for pid, p in procs.items() if p["ProcessName"] == "bookassetd"), None
        )
        pid_books = next((pid for pid, p in procs.items() if p["ProcessName"] == "Books"), None)
        if pid_bookassetd:
            await pc.signal(pid_bookassetd, 19)
        if pid_books:
            await pc.kill(pid_books)

        progress_callback("Uploading files...")

        # Update the download db
        if transfer_mode == BookRestoreFileTransferMethod.LocalHost:
            z_id = await generate_bldbmanager(
                files, temp_dl_manager, afc, server_prefix=server_prefix, server_folder=_server_folder
            )
        else:
            for file in files:
                if file.domain not in ("", None):
                    continue
                _, file_name = os.path.split(file.restore_path)
                print(f"including {file.restore_path}")
                await maybe_await(afc.set_file_contents(file_name, file.contents))

        async def fast_upload(local_path: str, remote_path: str) -> None:
            content = b""
            if os.path.exists(local_path):
                try:
                    with open(local_path, "rb") as f:
                        content = f.read()
                except OSError:
                    content = b""
            await maybe_await(afc.set_file_contents(remote_path, content))

        await fast_upload(temp_db_path, "Downloads/downloads.28.sqlitedb")
        await fast_upload(temp_db_path + "-shm", "Downloads/downloads.28.sqlitedb-shm")
        await fast_upload(temp_db_path + "-wal", "Downloads/downloads.28.sqlitedb-wal")
        connection.close()

    finally:
        remove_db_files(temp_db_path)
        cleanup_server_folder()

    procs = (await OsTraceService(lockdown=rsd).get_pid_list()).get("Payload")
    pid_itunesstored = next(
        (pid for pid, p in procs.items() if p["ProcessName"] == "itunesstored"), None
    )
    if pid_itunesstored:
        await pc.kill(pid_itunesstored)

    timeout = time.time() + 120
    progress_callback("Waiting for itunesstored to finish download...\n(This might take a minute)")
    os_trace = OsTraceService(lockdown=rsd)
    async for syslog_entry in os_trace.syslog():
        if time.time() > timeout:
            raise NuggetError("Timed out waiting for the download. Please try again.")
        if (posixpath.basename(syslog_entry.filename) == "itunesstored") and \
                "Install complete for download: 6936249076851270152 result: Failed" in syslog_entry.message:
            break

    procs = (await OsTraceService(lockdown=rsd).get_pid_list()).get("Payload")
    pid_bookassetd = next(
        (pid for pid, p in procs.items() if p["ProcessName"] == "bookassetd"), None
    )
    pid_books = next((pid for pid, p in procs.items() if p["ProcessName"] == "Books"), None)
    if pid_bookassetd:
        await pc.kill(pid_bookassetd)
    if pid_books:
        await pc.kill(pid_books)

    try:
        await pc.launch("com.apple.iBooks")
    except Exception as e:  # noqa: BLE001
        raise NuggetError(f"Error launching the Books app: {e!r}") from e

    progress_callback("Waiting for file overwrite to complete...\n(This might take a minute)")
    success_message = "[Install-Mgr]: Marking download as [finished]"
    num_replaced = 0
    z_id: int | None = None
    timeout_amt = 90
    if transfer_mode == BookRestoreFileTransferMethod.LocalHost:
        timeout_amt = 20
    timeout2 = time.time() + timeout_amt
    os_trace = OsTraceService(lockdown=rsd)
    async for syslog_entry in os_trace.syslog():
        if (syslog_entry.filename.endswith("bookassetd")) and success_message in syslog_entry.message:
            num_replaced += 1
            print(f"files found: {num_replaced}\nmsg: {syslog_entry.message}")
            if transfer_mode != BookRestoreFileTransferMethod.LocalHost or (z_id is not None and num_replaced >= z_id):
                break
        elif time.time() > timeout2:
            # respring anyway even if it is not detected that all files overwrote
            break

    if pid_bookassetd:
        await pc.kill(pid_bookassetd)
    if transfer_mode == BookRestoreFileTransferMethod.LocalHost:
        close_dl_connection()
        if temp_dl_manager:
            remove_db_files(temp_dl_manager)

    if do_full_reboot:
        progress_callback("Rebooting")
        await reboot_device(True, lockdown_client=rsd)
    else:
        progress_callback("Respringing")
        procs = (await OsTraceService(lockdown=rsd).get_pid_list()).get("Payload")
        pid = next((pid for pid, p in procs.items() if p["ProcessName"] == "backboardd"), None)
        if pid:
            await pc.kill(pid)


# --------------------------------------------------------------------------- #
# Connection management (tunnel + retry) and public entry point
# --------------------------------------------------------------------------- #
async def _create_connection_context(
    files: list[FileToRestore],
    udid: str,
    books_uuid_callback: BooksContainerUuid,
    progress_callback: Callable[[str], None] | None = None,
    transfer_mode: BookRestoreFileTransferMethod = BookRestoreFileTransferMethod.LocalHost,
    do_full_reboot: bool = False,
) -> None:
    available_address = await asyncio.to_thread(create_tunnel, udid, progress_callback)
    if not available_address:
        raise NuggetError("An error occurred getting the tunnel address...")

    if transfer_mode == BookRestoreFileTransferMethod.LocalHost:
        create_server_folder()

    max_retries = 10
    for i in range(max_retries):
        try:
            async with RemoteServiceDiscoveryService(
                (available_address["address"], available_address["port"])
            ) as rsd:
                async with DvtProvider(rsd) as dvt:
                    await apply_bookrestore_files(
                        files, rsd, dvt, books_uuid_callback,
                        progress_callback, transfer_mode, do_full_reboot,
                    )
            return  # success
        except OSError as e:
            if isinstance(e, PermissionError) or e.errno == 13:
                raise NuggetError(
                    "You must run the application as an administrator to use "
                    "BookRestore (AFC). Try the Restore apply method instead."
                ) from e
            print(f"Connection attempt {i + 1}/{max_retries} failed: {e}")
            if i == max_retries - 1:
                raise
            await asyncio.sleep(1.5)
        finally:
            cleanup_server_folder()


async def perform_bookrestore_async(
    files: list[FileToRestore],
    lockdown_client: Any,
    udid: str,
    books_uuid_callback: BooksContainerUuid | None = None,
    progress_callback: Callable[[str], None] | None = None,
    transfer_mode: BookRestoreFileTransferMethod = BookRestoreFileTransferMethod.LocalHost,
    do_full_reboot: bool = False,
) -> None:
    """Apply *files* with the BookRestore AFC method.

    Async form of :func:`perform_bookrestore` for callers that already run an
    event loop (``lockdown_client`` must belong to that loop). Requires
    Developer Mode on the device (prompts to reveal the setting otherwise).
    *udid* is the device UDID used for the RSD tunnel.
    """
    dev_mode = await maybe_await(lockdown_client.get_developer_mode_status())
    if not dev_mode:
        if progress_callback:
            progress_callback("Enabling Developer Mode...")
        await maybe_await(
            AmfiService(lockdown=lockdown_client).reveal_developer_mode_option_in_ui()
        )
        raise NuggetError(
            "You must enable Developer Mode on your device. You can do it in the "
            "Settings app.\n\n"
            "BookRestore with the AFC method requires Developer Mode to apply, "
            "which you can enable at the bottom of Settings > Privacy & Security "
            "> Developer Mode on your iPhone or iPad. Alternatively, use the "
            "\"BookRestore Restore\" apply method."
        )
    if books_uuid_callback is None:
        books_uuid_callback = BooksContainerUuid()
    await _create_connection_context(
        files, udid, books_uuid_callback, progress_callback, transfer_mode, do_full_reboot
    )


def perform_bookrestore(
    files: list[FileToRestore],
    lockdown_client: Any,
    udid: str,
    books_uuid_callback: BooksContainerUuid | None = None,
    progress_callback: Callable[[str], None] | None = None,
    transfer_mode: BookRestoreFileTransferMethod = BookRestoreFileTransferMethod.LocalHost,
    do_full_reboot: bool = False,
) -> None:
    """Apply *files* with the BookRestore AFC method (blocking).

    Runs its own event loop, so only pass a ``lockdown_client`` that was
    created inside this call (or one owned by a still-running loop). Prefer
    :func:`perform_bookrestore_async` from code that already owns a loop.
    """
    if os.name == "nt":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    asyncio.run(
        perform_bookrestore_async(
            files, lockdown_client, udid, books_uuid_callback,
            progress_callback, transfer_mode, do_full_reboot,
        )
    )