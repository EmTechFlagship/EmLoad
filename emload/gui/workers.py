"""Worker threads for the EmLoad GUI.

PySide6 owns the event loop on the main thread; every blocking engine call
(usbmux listing, Apple auth, provisioning/signing/installing) runs in a
``TaskWorker`` on a background thread and reports progress/result/error back
through Qt signals, so the UI never freezes.
"""

from __future__ import annotations

import threading
from typing import Any, Callable

from PySide6.QtCore import QThread, Signal

from .. import device
from .._asyncutil import run
from ..sideload import ProgressFn


class TaskWorker(QThread):
    """Run ``fn(*args, **kwargs)`` in a thread, delivering progress + outcome.

    ``fn`` may take an optional ``on_progress`` keyword: a callback invoked from
    the worker thread with ``(phase, percent, step)`` tuples, forwarded to the
    main thread via :attr:`progress`.
    """

    progress = Signal(str, object, object)  # phase, percent, step
    finished_ok = Signal(object)            # result (dict)
    failed = Signal(str)                    # user-facing error message

    def __init__(
        self,
        fn: Callable[..., Any],
        *args: Any,
        parent: Any = None,
        **kwargs: Any,
    ):
        super().__init__(parent)
        self._fn = fn
        self._args = args
        self._kwargs = kwargs

    def run(self) -> None:  # noqa: D102 - QThread override
        def on_progress(phase: str, percent: Any, step: str | None) -> None:
            self.progress.emit(phase, percent, step)

        try:
            kwargs = dict(self._kwargs)
            if _accepts_on_progress(self._fn, kwargs):
                kwargs["on_progress"] = on_progress
            result = self._fn(*self._args, **kwargs)
        except Exception as exc:  # noqa: BLE001 - report every failure to the UI
            self.failed.emit(str(exc))
            return
        self.finished_ok.emit(result if result is not None else {})


def _accepts_on_progress(fn: Callable[..., Any], kwargs: dict[str, Any]) -> bool:
    """True if ``fn`` can take an ``on_progress`` keyword (engine callables vary)."""
    import inspect

    try:
        signature = inspect.signature(fn)
    except (TypeError, ValueError):
        return False
    return "on_progress" in signature.parameters or any(
        p.kind == inspect.Parameter.VAR_KEYWORD
        for p in signature.parameters.values()
    )


class UsbmuxWatchThread(QThread):
    """Watch usbmux for device attach/detach and emit the full entry list."""

    devices_changed = Signal(list)
    watch_error = Signal(str)

    def __init__(self, parent: Any = None):
        super().__init__(parent)
        self._stop = threading.Event()

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:  # noqa: D102 - QThread override
        def emit(entry: dict[str, Any]) -> None:
            if entry.get("name") == "devices":
                self.devices_changed.emit(list(entry.get("data") or []))

        try:
            device.run_usbmux_watch(emit, self._stop)
        except Exception as exc:  # noqa: BLE001
            if not self._stop.is_set():
                self.watch_error.emit(str(exc))


def run_coro(coro: Any) -> Any:
    """Run a coroutine to completion (for small one-shot GUI helper calls)."""
    return run(coro)