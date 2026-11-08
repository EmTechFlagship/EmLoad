"""Respring via WebKit compositor overload (Qt-free port).

Ported from Nugget27 (AGPL-3.0): ``src/restore/respring.py``.

The method was developed by @neonmodder123 and implemented in Erosion
(jailbreak.party) by @skadz108: it overloads WebKit's compositor with 500
backdrop-filter layers plus memory pressure, which crashes SpringBoard and
causes a respring on all iOS versions.

The device's Safari is pointed at an HTML page served over LAN from
:file:`assets/respring.html`.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import queue
import socket
import subprocess
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from pymobiledevice3.exceptions import (
    LaunchingApplicationError,
    RemoteAutomationNotEnabledError,
    WebInspectorNotEnabledError,
)
from pymobiledevice3.lockdown import LockdownClient
from pymobiledevice3.services.web_protocol.driver import WebDriver
from pymobiledevice3.services.webinspector import SAFARI, WebinspectorService

from .errors import NuggetError

#: Directory that ships with this package and holds the respring page.
RESPRING_ASSET_DIR = Path(__file__).resolve().parent / "assets"
RESPRING_FILE = "respring.html"


class RespringHTTPRequestHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(RESPRING_ASSET_DIR), **kwargs)

    def log_message(self, format, *args):  # noqa: A002 - BaseHTTPRequestHandler API
        print(f"[respring] {format % args}")


def get_lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    finally:
        s.close()


def start_respring_server() -> str:
    """Serve the respring page over LAN so the device's Safari can load it.

    Returns the http://ip:port prefix. Adds a short-lived Windows firewall
    rule when running on Windows so the device's request is not blocked.
    """
    info_queue: queue.Queue = queue.Queue()

    def serve() -> None:
        httpd = ThreadingHTTPServer(("0.0.0.0", 0), RespringHTTPRequestHandler)
        info_queue.put((get_lan_ip(), httpd.server_port))
        httpd.serve_forever()

    server_thread = threading.Thread(target=serve, daemon=True)
    server_thread.start()
    ip, port = info_queue.get()
    prefix = f"http://{ip}:{port}"
    print(f"Hosting respring page on: {prefix}/{RESPRING_FILE}")

    firewall_rule_name = f"EmLoad_Respring_{port}"
    if os.name == "nt":
        try:
            subprocess.run(
                f'netsh advfirewall firewall add rule name="{firewall_rule_name}" '
                f"dir=in action=allow protocol=TCP localport={port}",
                shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            # remove the firewall rule after the page has been loaded
            def cleanup_firewall_rule() -> None:
                time.sleep(30)
                try:
                    subprocess.run(
                        f'netsh advfirewall firewall delete rule name="{firewall_rule_name}"',
                        shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    )
                except Exception:
                    pass

            threading.Thread(target=cleanup_firewall_rule, daemon=True).start()
        except Exception as e:
            print(f"Warning: Could not add firewall rule: {e}")
    return prefix


async def _open_respring_page_via_inspector(inspector: WebinspectorService, url: str) -> None:
    """Navigate the active Safari page using the Web Inspector session.

    This is the classic method ported from Erosion (@neonmodder123 / @skadz108).
    On some iOS versions (e.g. iOS 27) the page target answers with
    "'Runtime' domain was not found", in which case we fall back to automation.
    """
    page = None
    for _ in range(10):
        application_pages = await inspector.get_open_application_pages(1)
        page = next((p for p in application_pages if p.application.bundle == SAFARI), None)
        if page is not None:
            break
        await asyncio.sleep(1)
    if page is None:
        raise NuggetError(
            "Could not find the Safari page on your device. Unlock your device and try again."
        )

    # guard the session setup and RPCs with timeouts to fail gracefully
    session = await asyncio.wait_for(inspector.inspector_session(page.application, page.page), timeout=10)
    await asyncio.wait_for(session.console_enable(), timeout=10)
    await asyncio.wait_for(session.runtime_enable(), timeout=10)
    await asyncio.wait_for(session.navigate_to_url(url), timeout=10)
    print(f"Opened respring page on device via inspector: {url}")


async def _open_respring_page_via_automation(lockdown: LockdownClient, url: str) -> None:
    """Navigate Safari using the Remote Automation (WebDriver) API.

    Does not depend on the Runtime domain, so it works on iOS 27 where the
    inspector-session path fails.
    """
    inspector = WebinspectorService(lockdown=lockdown)
    await inspector.connect()
    try:
        safari = await asyncio.wait_for(inspector.open_app(SAFARI, 10), timeout=15)
        session = await asyncio.wait_for(inspector.automation_session(safari), timeout=15)
        driver = WebDriver(session)
        await asyncio.wait_for(driver.start_session(), timeout=15)
        await asyncio.wait_for(driver.get(url), timeout=15)
        print(f"Opened respring page on device via automation: {url}")
    finally:
        with contextlib.suppress(Exception):
            await inspector.close()


async def _open_respring_page(lockdown: LockdownClient, url: str, timeout: float = 3.0) -> None:
    inspector = WebinspectorService(lockdown=lockdown)
    await inspector.connect()
    try:
        # launch Safari on the device
        _ = await inspector.open_app(SAFARI, timeout)
        # navigate Safari to the respring page
        try:
            await _open_respring_page_via_inspector(inspector, url)
        except Exception as e:
            # The inspector-session path fails on some iOS versions; close our
            # connection before retrying so webinspectord does not consider the
            # page held by us, then fall back to Remote Automation.
            print(f"Inspector-session navigation failed ({type(e).__name__}: {e}); "
                  "retrying via Remote Automation")
            with contextlib.suppress(Exception):
                await inspector.close()
            await _open_respring_page_via_automation(lockdown, url)
    finally:
        # the device may already be respringing (connection dropped); suppress any close errors
        with contextlib.suppress(Exception):
            await inspector.close()


async def trigger_respring_async(lockdown: LockdownClient, timeout: float = 3.0) -> None:
    """Crash SpringBoard on *lockdown*'s device by overloading WebKit.

    Async form of :func:`trigger_respring`, for callers that already run an
    event loop. *lockdown* must have been created on the same loop that is
    currently running; a client created by a previous (finished)
    ``asyncio.run`` cannot be reused here - its asyncio streams are bound to
    the old, closed loop and every await raises "Future attached to a
    different loop".
    """
    if lockdown is None:
        return
    url = f"{start_respring_server()}/{RESPRING_FILE}"
    try:
        await _open_respring_page(lockdown, url, timeout)
    except WebInspectorNotEnabledError:
        raise NuggetError(
            "Could not trigger a respring: Web Inspector is not enabled on your device.\n\n"
            "Enable it in Settings -> Safari -> Advanced -> Web Inspector and try again, "
            "or restart your device manually to apply the changes."
        ) from None
    except RemoteAutomationNotEnabledError:
        raise NuggetError(
            "Could not trigger a respring: Remote Automation is not enabled on your device.\n\n"
            "Enable it in Settings -> Safari -> Advanced -> Remote Automation and try again, "
            "or restart your device manually to apply the changes."
        ) from None
    except LaunchingApplicationError:
        raise NuggetError(
            "Could not launch Safari on your device. Unlock your device and try again, "
            "or restart your device manually to apply the changes."
        ) from None


def trigger_respring(lockdown: LockdownClient, timeout: float = 3.0) -> None:
    """Crash SpringBoard on *lockdown*'s device by overloading WebKit.

    Synchronous facade that runs its own event loop. Because *lockdown*'s
    asyncio streams are bound to whatever loop created them, only use this
    with a client that was created inside this very call (or one created on a
    still-running loop). Prefer :func:`trigger_respring_async` from code that
    already owns an event loop.
    """
    if lockdown is None:
        return
    if os.name == "nt":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    asyncio.run(trigger_respring_async(lockdown, timeout))