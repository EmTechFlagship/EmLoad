"""EmLoad desktop app (PySide6).

A main window with a sidebar covering the whole sideload workflow:

- Devices: what's connected (live, via a usbmux watch thread)
- Sideload: drop an .ipa, pick options, pick device, watch it install
- Library: every sideload this machine has done, with expiry countdown and
  one-click refresh
- Account: Apple ID sign-in / sign-out (2FA-aware)
- Settings: connection, signed-IPA folder, zsign
- Diagnostics: ``doctor`` results rendered

All engine calls (including device info reads) run on worker threads (see
:mod:`emload.gui.workers`), so the UI never freezes during a sign-in or install.
"""

from __future__ import annotations

import base64
import json
import logging
import sys
import traceback
from datetime import datetime
from pathlib import Path
from typing import Any

from PySide6.QtCore import QSize, Qt, Signal
from PySide6.QtGui import QColor, QDragEnterEvent, QDropEvent, QIcon, QPixmap
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QFileDialog,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QCheckBox,
    QStackedWidget,
    QStyle,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from .. import __version__, apps, device, doctor, gsa, ipa, paths, provision, registry, sideload, signing
from ..nugget import respring_device
from .dialogs import LoginDialog
from .nugget_dialogs import DaemonsDialog, LiquidGlassDialog, SpringBoardDialog
from .workers import TaskWorker, UsbmuxWatchThread


def _pixmap_from_data_uri(uri: str | None, size: int = 64) -> QPixmap:
    """A QPixmap from a ``data:image/png;base64,...`` URI, or a blank one."""
    pix = QPixmap(size, size)
    pix.fill(Qt.transparent)
    if uri and uri.startswith("data:image/png;base64,"):
        try:
            raw = base64.b64decode(uri.split(",", 1)[1])
            loaded = QPixmap()
            if loaded.loadFromData(raw):
                return loaded.scaled(
                    size, size, Qt.KeepAspectRatio, Qt.SmoothTransformation
                )
        except Exception:  # noqa: BLE001 - a broken icon is not worth a crash
            pass
    return pix


def _days_left_text(days: float | None, expired: bool = False) -> str:
    if days is None:
        return "-"
    if expired:
        return "expired"
    if days < 1:
        hours = max(0, int(days * 24))
        return f"{hours}h left"
    return f"{days:.1f}d left"


def _app_icon() -> QIcon:
    """The EmLoad window/taskbar icon (bundled ``gui/assets/E.png``).

    Returns an empty icon (QIcon()) if the asset is missing, so the app still
    runs with the default icon rather than crashing.
    """
    icon_file = paths.resource_dir() / "gui" / "assets" / "E.png"
    icon = QIcon()
    if icon_file.is_file():
        icon.addFile(str(icon_file))
    return icon


def _install_excepthook() -> None:
    """Keep the GUI alive when something unexpected happens in a Qt slot.

    Under ``pythonw`` (``run.bat``) there is no console, so an unhandled
    exception in the event loop - e.g. right after a sideload finishes - would
    close the app without a trace. Log it to ``%LOCALAPPDATA%\\EmLoad\\gui-errors.log``
    instead, and keep the window open.
    """
    log_path = paths.data_dir() / "gui-errors.log"
    logging.basicConfig(
        filename=log_path,
        level=logging.WARNING,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    logger = logging.getLogger("emload.gui")

    def hook(exc_type, exc_value, exc_tb) -> None:  # noqa: ANN001 - sys.excepthook signature
        logger.error(
            "Unhandled exception (keeping the app open):\n%s",
            "".join(traceback.format_exception(exc_type, exc_value, exc_tb)),
        )

    sys.excepthook = hook


class MainWindow(QMainWindow):
    # Progress from the sideload worker thread, forwarded to the UI thread.
    # Widgets must never be touched from a worker thread - PySide6 crashes
    # natively (access violation, no popup, no traceback), so the worker only
    # emits this signal and the slot below updates the UI.
    sideload_progress = Signal(str, object, object)  # phase, percent, step

    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle(f"EmLoad {__version__} - iOS Sideloading")
        self.setWindowIcon(_app_icon())
        self.resize(1020, 720)

        self.devices: list[dict[str, Any]] = []
        self._workers: list[TaskWorker] = []
        self._watch_thread: UsbmuxWatchThread | None = None
        self._current_ipa: str | None = None
        self._current_info: dict[str, Any] | None = None
        self._login_dialog: LoginDialog | None = None
        self._login_email: str | None = None
        self._nugget_dialog: Any | None = None

        # Sidebar navigation + stacked pages (instead of a tab bar).
        # Colors come from the active palette (palette(...) roles), so the
        # sidebar follows the system light/dark theme just like the page body.
        self.sidebar = QListWidget()
        self.sidebar.setObjectName("sidebar")
        self.sidebar.setFixedWidth(200)
        self.sidebar.setSpacing(2)
        self.sidebar.setIconSize(QSize(18, 18))
        self.sidebar.setStyleSheet(
            """
            QListWidget#sidebar {
                background: palette(window);
                border: none;
                border-right: 1px solid palette(mid);
                outline: none;
                padding-top: 8px;
                font-size: 14px;
            }
            QListWidget#sidebar::item {
                color: palette(window-text);
                padding-left: 14px;
            }
            QListWidget#sidebar::item:hover {
                background: palette(midlight);
            }
            QListWidget#sidebar::item:selected {
                background: palette(highlight);
                color: palette(highlighted-text);
            }
            """
        )

        self.stack = QStackedWidget()

        # Theme-aware standard icons (they render with the active palette).
        sidebar_icons = {
            "Devices": QStyle.StandardPixmap.SP_ComputerIcon,
            "Sideload": QStyle.StandardPixmap.SP_DialogOpenButton,
            "Library": QStyle.StandardPixmap.SP_DirOpenIcon,
            "Miscellaneous": QStyle.StandardPixmap.SP_MessageBoxQuestion,
            "Account": QStyle.StandardPixmap.SP_MessageBoxInformation,
            "Settings": QStyle.StandardPixmap.SP_FileDialogDetailedView,
            "Diagnostics": QStyle.StandardPixmap.SP_MessageBoxWarning,
        }

        pages = [
            self._build_devices_tab(),
            self._build_sideload_tab(),
            self._build_library_tab(),
            self._build_misc_tab(),
            self._build_account_tab(),
            self._build_settings_tab(),
            self._build_diagnostics_tab(),
        ]
        for page, label in pages:
            self.stack.addWidget(page)
            item = QListWidgetItem(self.style().standardIcon(sidebar_icons[label]), label)
            item.setSizeHint(QSize(0, 42))
            self.sidebar.addItem(item)

        self.sidebar.currentRowChanged.connect(self.stack.setCurrentIndex)
        self.sidebar.setCurrentRow(0)

        central = QWidget()
        shell = QHBoxLayout(central)
        shell.setContentsMargins(0, 0, 0, 0)
        shell.setSpacing(0)
        shell.addWidget(self.sidebar)
        shell.addWidget(self.stack, 1)
        self.setCentralWidget(central)

        self.statusBar().showMessage("Starting\u2026")
        self._start_watch()
        self.refresh_devices()
        self.refresh_account()
        self.refresh_library()

    # ------------------------------------------------------------------ #
    # Worker plumbing
    # ------------------------------------------------------------------ #
    def run_task(self, fn, *args, on_done=None, on_error=None, **kwargs):
        """Run ``fn`` on a worker thread; ``on_done(result)`` on success.

        ``on_error(worker, message)``, when given, replaces the default error
        dialog - used for background niceties that must not shout at the user.
        """
        worker = TaskWorker(fn, *args, **kwargs)
        self._workers.append(worker)
        worker.finished_ok.connect(
            lambda result: self._task_done(worker, result, on_done)
        )
        worker.failed.connect(
            lambda msg: (
                self._task_failed(worker, msg)
                if on_error is None
                else on_error(worker, msg)
            )
        )
        worker.start()
        return worker

    def _task_done(self, worker, result, on_done) -> None:
        self._prune_workers(worker)
        if on_done:
            try:
                on_done(result)
            except Exception as exc:  # noqa: BLE001 - a UI bug must never close the app
                self.log(f"Error after task finished: {exc}")
                self.statusBar().showMessage("Finished, but the UI hit an error", 8000)

    def _task_failed(self, worker, message: str) -> None:
        self._prune_workers(worker)
        self.log(f"Error: {message}")
        self.statusBar().showMessage("Failed", 5000)
        QMessageBox.critical(self, "EmLoad", message)

    def _prune_workers(self, done: TaskWorker) -> None:
        self._workers = [w for w in self._workers if w is not done]

    def closeEvent(self, event) -> None:  # noqa: D102 - QMainWindow override
        if self._watch_thread is not None:
            self._watch_thread.stop()
            self._watch_thread.wait(2000)
        for worker in self._workers:
            worker.wait(2000)
        super().closeEvent(event)

    # ------------------------------------------------------------------ #
    # Devices tab
    # ------------------------------------------------------------------ #
    def _build_devices_tab(self) -> tuple[QWidget, str]:
        page = QWidget()
        layout = QVBoxLayout(page)
        header = QHBoxLayout()
        title = QLabel("Connected devices")
        title.setStyleSheet("font-size: 16px; font-weight: bold;")
        header.addWidget(title)
        header.addStretch()
        self.devices_refresh_button = QPushButton("Refresh")
        self.devices_refresh_button.clicked.connect(self.refresh_devices)
        header.addWidget(self.devices_refresh_button)
        layout.addLayout(header)

        self.devices_table = QTableWidget(0, 5)
        self.devices_table.setHorizontalHeaderLabels(
            ["Name", "Model", "iOS", "UDID", "Connection"]
        )
        self.devices_table.horizontalHeader().setSectionResizeMode(3, QHeaderView.Stretch)
        self.devices_table.setSelectionBehavior(QTableWidget.SelectRows)
        layout.addWidget(self.devices_table)

        hint = QLabel(
            "Plug in your iPhone, unlock it, and tap \"Trust This Computer\" when "
            "prompted. Wi-Fi devices appear too when reachable."
        )
        hint.setWordWrap(True)
        layout.addWidget(hint)
        return page, "Devices"

    def refresh_devices(self) -> None:
        self.statusBar().showMessage("Looking for devices\u2026")
        self.run_task(device.list_devices, on_done=self._devices_changed)

    def _devices_changed(self, entries: list[dict[str, Any]]) -> None:
        previous = {str(e.get("serial")) for e in self.devices if e.get("serial")}
        current = {str(e.get("serial")) for e in entries if e.get("serial")}
        self.devices = entries
        self.refresh_target_combo()
        self.refresh_misc_combo()
        # Enriching every device needs a lockdown read per device - keep it off
        # the UI thread.
        self.run_task(self._enrich_devices, entries, on_done=self._populate_devices)

        # A device just plugged in: if the cached certificate + profile belong to
        # a different phone, delete them and provision fresh ones for this one.
        # Silent when not signed in / nothing cached / already up to date - the
        # engine says so in its result and only "reprovisioned" is worth showing.
        for serial in sorted(current - previous):
            self.run_task(
                provision.ensure_provisioned_for_device,
                serial,
                on_done=lambda result, s=serial: self._auto_provision_done(s, result),
                on_error=lambda _worker, msg, s=serial: self.statusBar().showMessage(
                    f"Could not provision {s}: {msg}", 8000
                ),
            )

    def _auto_provision_done(self, serial: str, result: dict[str, Any]) -> None:
        if result.get("status") != "reprovisioned":
            return
        name = result.get("device_name") or serial
        message = f"Provisioned {name} with a fresh certificate + profile"
        if not result.get("profile_installed"):
            message += " (profile not installed on the device)"
        warning = result.get("warning")
        if warning:
            self.log(f"Auto-provision: {warning}")
        self.statusBar().showMessage(message, 8000)

    @staticmethod
    def _enrich_devices(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
        seen: list[dict[str, Any]] = []
        for entry in entries:
            serial = entry.get("serial")
            if not serial or serial in [s.get("serial") for s in seen]:
                continue
            info = {}
            try:
                info = device.get_device_info(serial, prefer_usb=False)
            except Exception:  # noqa: BLE001 - unpaired/untrusted devices may not answer
                pass
            seen.append({**entry, "info": info})
        return seen

    def _populate_devices(self, enriched: list[dict[str, Any]]) -> None:
        table = self.devices_table
        table.setRowCount(0)
        for row in enriched:
            info = row.get("info") or {}
            i = table.rowCount()
            table.insertRow(i)
            values = [
                info.get("DeviceName") or "Unnamed device",
                info.get("ProductType") or "-",
                info.get("ProductVersion") or "-",
                row.get("serial") or "-",
                row.get("connection_type") or "-",
            ]
            for c, value in enumerate(values):
                item = QTableWidgetItem(str(value))
                if c == 3:
                    item.setToolTip(str(row.get("serial")))
                if c == 0 and not info:
                    item.setForeground(QColor("#b58900"))
                table.setItem(i, c, item)

        if enriched:
            self.statusBar().showMessage(f"{len(enriched)} device(s) connected", 5000)
        else:
            self.statusBar().showMessage("No device connected", 5000)

    @staticmethod
    def connected_udids(devices: list[dict[str, Any]]) -> list[str]:
        udids: list[str] = []
        for entry in devices:
            serial = entry.get("serial")
            if serial and str(serial) not in udids:
                udids.append(str(serial))
        return udids

    # ------------------------------------------------------------------ #
    # Sideload tab
    # ------------------------------------------------------------------ #
    def _build_sideload_tab(self) -> tuple[QWidget, str]:
        page = QWidget()
        layout = QVBoxLayout(page)

        self.drop_area = QLabel("Drag & drop an .ipa here, or click Browse\n\nIPA: none")
        self.drop_area.setAlignment(Qt.AlignCenter)
        self.drop_area.setMinimumHeight(120)
        self.drop_area.setStyleSheet(
            "border: 2px dashed #888; border-radius: 8px; padding: 8px;"
        )
        self.drop_area.setAcceptDrops(True)
        self.drop_area.mousePressEvent = lambda _e: self.browse_ipa()
        layout.addWidget(self.drop_area)

        self.app_info_row = QHBoxLayout()
        self.app_icon_label = QLabel()
        self.app_icon_label.setFixedSize(64, 64)
        self.app_info_row.addWidget(self.app_icon_label)
        self.app_info_text = QLabel("No app selected")
        self.app_info_text.setWordWrap(True)
        self.app_info_row.addWidget(self.app_info_text, 1)
        layout.addLayout(self.app_info_row)

        options = QGroupBox("Options")
        form = QFormLayout(options)
        self.display_name_edit = QLineEdit()
        self.bundle_id_edit = QLineEdit()
        self.version_edit = QLineEdit()
        form.addRow("Display name", self.display_name_edit)
        form.addRow("Bundle ID (blank = team-scoped)", self.bundle_id_edit)
        form.addRow("Version", self.version_edit)
        self.strip_ext_check = QCheckBox("Remove app extensions (free accounts can't sign them)")
        self.strip_ext_check.setChecked(True)
        self.strip_uisd_check = QCheckBox("Remove device restrictions (UISupportedDevices)")
        self.strip_uisd_check.setChecked(True)
        self.file_sharing_check = QCheckBox("Enable Files-app sharing")
        self.keep_signed_check = QCheckBox("Keep the signed .ipa on disk")
        for box in (
            self.strip_ext_check,
            self.strip_uisd_check,
            self.file_sharing_check,
            self.keep_signed_check,
        ):
            form.addRow("", box)
        layout.addWidget(options)

        target_row = QHBoxLayout()
        target_row.addWidget(QLabel("Install to:"))
        self.target_combo = QComboBox()
        self.target_combo.setMinimumWidth(320)
        target_row.addWidget(self.target_combo, 1)
        self.refresh_devices_button = QPushButton("Refresh")
        self.refresh_devices_button.clicked.connect(self.refresh_devices)
        target_row.addWidget(self.refresh_devices_button)
        layout.addLayout(target_row)

        self.sideload_button = QPushButton("Sideload to iPhone")
        self.sideload_button.setEnabled(False)
        self.sideload_button.clicked.connect(self.start_sideload)
        layout.addWidget(self.sideload_button)

        self.progress_bar = QProgressBar()
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(0)
        layout.addWidget(self.progress_bar)

        self.log_view = QPlainTextEdit()
        self.log_view.setReadOnly(True)
        self.log_view.setMaximumBlockCount(3000)
        layout.addWidget(self.log_view, 1)

        self.sideload_progress.connect(self._on_sideload_progress)
        return page, "Sideload"

    def browse_ipa(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "Choose an .ipa", "", "iOS Apps (*.ipa)")
        if path:
            self.load_ipa(path)

    def dragEnterEvent(self, event: QDragEnterEvent) -> None:  # noqa: D102
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event: QDropEvent) -> None:  # noqa: D102
        urls = event.mimeData().urls()
        if urls:
            path = urls[0].toLocalFile()
            if path.lower().endswith(".ipa"):
                self.load_ipa(path)

    def load_ipa(self, path: str) -> None:
        self._current_ipa = path
        self.log(f"Reading {Path(path).name}\u2026")
        self.run_task(ipa.inspect, path, on_done=self._ipa_loaded)

    def _ipa_loaded(self, info: dict[str, Any]) -> None:
        self._current_info = info
        app_bundle = info.get("app_bundle") or "app"
        self.drop_area.setText(f"IPA: {app_bundle}\n(click to change)")
        self.drop_area.setStyleSheet("border: 2px solid #4a9; border-radius: 8px; padding: 8px;")
        self.app_icon_label.setPixmap(_pixmap_from_data_uri(info.get("icon")))
        name = info.get("display_name") or info.get("bundle_id") or "Unknown"
        detail = (
            f"{name}\n"
            f"bundle: {info.get('bundle_id')}\n"
            f"version: {info.get('version')} ({info.get('build')})  "
            f"min iOS: {info.get('minimum_os') or '-'}"
        )
        if info.get("has_sc_info"):
            detail += "\nWARNING: App Store-encrypted (FairPlay) - cannot be sideloaded"
        if info.get("extensions"):
            detail += f"\nextensions: {', '.join(info['extensions'])} (will be removed)"
        self.app_info_text.setText(detail)
        self.display_name_edit.setText(str(info.get("display_name") or ""))
        self.bundle_id_edit.setText("")
        self.version_edit.setText(str(info.get("version") or ""))
        self.refresh_target_combo()

    def refresh_target_combo(self) -> None:
        combo = self.target_combo
        current = combo.currentData()
        combo.clear()
        udids = self.connected_udids(self.devices)
        if not udids:
            combo.addItem("No device connected", None)
            self.sideload_button.setEnabled(False)
            return
        for udid in udids:
            combo.addItem(f"{udid[:8]}\u2026  ({udid})", udid)
        if current in udids:
            combo.setCurrentIndex(combo.findData(current))
        self.sideload_button.setEnabled(bool(self._current_info))

    def start_sideload(self) -> None:
        if not self._current_info or not self._current_ipa:
            return
        udid = self.target_combo.currentData()
        if not udid:
            QMessageBox.warning(self, "EmLoad", "Connect a device first.")
            return

        self.sideload_button.setEnabled(False)
        self.progress_bar.setValue(0)
        self.log("Starting sideload\u2026")

        def on_progress(phase: str, percent: Any, step: str | None) -> None:
            # Runs on the worker thread: only forward through the signal - the
            # slot updates widgets on the UI thread.
            self.sideload_progress.emit(phase, percent, step)

        keep_signed = self.keep_signed_check.isChecked() or self.keep_signed_default.isChecked()

        def run():
            return sideload.run_sideload(
                self._current_ipa,
                udid,
                bundle_id=self.bundle_id_edit.text().strip() or None,
                display_name=self.display_name_edit.text().strip() or None,
                bundle_version=self.version_edit.text().strip() or None,
                remove_extensions=self.strip_ext_check.isChecked(),
                remove_uisd=self.strip_uisd_check.isChecked(),
                enable_file_sharing=self.file_sharing_check.isChecked(),
                keep_signed=keep_signed,
                signed_dir=self.signed_dir_setting() or None,
                on_progress=on_progress,
            )

        self.run_task(run, on_done=self._sideload_done, on_error=self._sideload_failed)

    def _on_sideload_progress(self, phase: str, percent: Any, step: str | None) -> None:
        """UI-thread slot for sideload progress (see :attr:`sideload_progress`)."""
        if percent is not None:
            self.progress_bar.setValue(int(percent))
        if step:
            self.log(f"[{phase}] {step}")

    def _sideload_failed(self, worker, message: str) -> None:
        """A sideload worker raised: tell the user in an explicit error popup."""
        if worker is not None:
            self._prune_workers(worker)
        self.sideload_button.setEnabled(True)
        self.log(f"Sideload failed: {message}")
        self.statusBar().showMessage("Sideload failed", 8000)
        app_name = (self._current_info or {}).get("display_name") or (
            self._current_info or {}
        ).get("bundle_id") or "the app"
        udid = self.target_combo.currentData() or "your device"
        QMessageBox.critical(
            self,
            "Sideload failed",
            f"{app_name} did not install on {udid}.\n\n{message}",
        )

    def _sideload_done(self, result: dict[str, Any]) -> None:
        if result.get("status") != "installed":
            # The engine returned without raising but still did not install the
            # app - surface it the same way as a raised failure.
            detail = result.get("error") or result.get("status") or str(result)
            self._sideload_failed(None, str(detail))
            return
        self.sideload_button.setEnabled(True)
        self.progress_bar.setValue(100)
        self.log(
            f"Installed {result.get('name')} ({result.get('bundle_id')}) on "
            f"{result.get('udid')}."
        )
        regenerated = result.get("profile_regenerations") or 0
        if regenerated:
            self.log(
                f"Device verification failed {regenerated} time(s); re-issued a fresh "
                "provisioning profile and retired the old one."
            )
        expires = result.get("expires_at")
        if expires:
            try:
                when = datetime.fromisoformat(expires)
                self.log(f"Profile expires {when:%Y-%m-%d %H:%M} - refresh before then.")
            except ValueError:
                pass
        self.statusBar().showMessage("Installed", 5000)
        self.refresh_library()

    # ------------------------------------------------------------------ #
    # Library tab
    # ------------------------------------------------------------------ #
    def _build_library_tab(self) -> tuple[QWidget, str]:
        page = QWidget()
        layout = QVBoxLayout(page)
        header = QHBoxLayout()
        title = QLabel("Sideloaded apps (7-day refresh)")
        title.setStyleSheet("font-size: 16px; font-weight: bold;")
        header.addWidget(title)
        header.addStretch()
        self.refresh_all_button = QPushButton("Refresh All")
        self.refresh_all_button.clicked.connect(
            lambda: self.refresh_records([r["bundle_id"] for r in registry.records()])
        )
        header.addWidget(self.refresh_all_button)
        self.library_refresh_button = QPushButton("Reload")
        self.library_refresh_button.clicked.connect(self.refresh_library)
        header.addWidget(self.library_refresh_button)
        layout.addLayout(header)

        self.library_table = QTableWidget(0, 6)
        self.library_table.setHorizontalHeaderLabels(
            ["App", "Bundle ID", "Installed", "Expires", "Time left", "Actions"]
        )
        self.library_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.Stretch)
        self.library_table.setSelectionBehavior(QTableWidget.SelectRows)
        layout.addWidget(self.library_table)
        hint = QLabel(
            "Free Apple ID signatures expire after 7 days. Refresh an app to re-sign "
            "and reinstall it before it stops opening."
        )
        hint.setWordWrap(True)
        layout.addWidget(hint)
        return page, "Library"

    def refresh_library(self) -> None:
        records = registry.records()
        table = self.library_table
        table.setRowCount(0)
        for entry in records:
            i = table.rowCount()
            table.insertRow(i)
            installed_at = entry.get("installed_at", "")
            try:
                installed = datetime.fromisoformat(installed_at).strftime("%Y-%m-%d")
            except (ValueError, TypeError):
                installed = "-"
            expires_at = entry.get("expires_at", "")
            try:
                expires = datetime.fromisoformat(expires_at).strftime("%Y-%m-%d")
            except (ValueError, TypeError):
                expires = "-"
            days = entry.get("days_left")
            expired = bool(entry.get("expired"))

            cells = [
                QTableWidgetItem(entry.get("name") or entry.get("bundle_id") or "-"),
                QTableWidgetItem(entry.get("bundle_id", "")),
                QTableWidgetItem(installed),
                QTableWidgetItem(expires),
                QTableWidgetItem(_days_left_text(days, expired)),
            ]
            for c, cell in enumerate(cells):
                if c == 0:
                    cell.setIcon(_pixmap_from_data_uri(entry.get("icon"), 24))
                elif c == 4 and expired:
                    cell.setForeground(QColor("#c0392b"))
                table.setItem(i, c, cell)

            actions = QWidget()
            row = QHBoxLayout(actions)
            row.setContentsMargins(0, 0, 0, 0)
            bundle_id = entry.get("bundle_id", "")
            refresh = QPushButton("Refresh")
            refresh.clicked.connect(lambda _=False, b=bundle_id: self.refresh_records([b]))
            uninstall = QPushButton("Uninstall")
            uninstall.clicked.connect(lambda _=False, b=bundle_id: self.uninstall_app(b))
            forget = QPushButton("Forget")
            forget.clicked.connect(lambda _=False, b=bundle_id: self.forget_app(b))
            row.addWidget(refresh)
            row.addWidget(uninstall)
            row.addWidget(forget)
            row.addStretch()
            table.setCellWidget(i, 5, actions)

        if not records:
            self.statusBar().showMessage("No sideloads recorded yet", 5000)
        else:
            self.statusBar().showMessage(f"{len(records)} recorded sideload(s)", 5000)

    def refresh_records(self, bundle_ids: list[str]) -> None:
        ids = [b for b in bundle_ids if b]
        if not ids:
            self.log("Nothing to refresh.")
            return
        done = [0]

        def refresh_one(idx: int) -> None:
            if idx >= len(ids):
                self.statusBar().showMessage(f"Refreshed {done[0]} app(s)", 5000)
                self.refresh_library()
                return
            bundle_id = ids[idx]
            entry = registry.get(bundle_id)
            if entry is None:
                refresh_one(idx + 1)
                return
            self.log(f"Refreshing {entry.get('name') or bundle_id}\u2026")
            self.run_task(
                sideload.refresh_record,
                entry,
                on_done=lambda _r: (done.__setitem__(0, done[0] + 1), refresh_one(idx + 1))[1],
            )

        refresh_one(0)

    def uninstall_app(self, bundle_id: str) -> None:
        if QMessageBox.question(
            self, "EmLoad", f"Uninstall {bundle_id} from the device?"
        ) != QMessageBox.Yes:
            return
        self.run_task(
            apps.uninstall,
            bundle_id,
            on_done=lambda _r: (self.log(f"Uninstalled {bundle_id}."), self.refresh_library())[1],
        )

    def forget_app(self, bundle_id: str) -> None:
        registry.forget(bundle_id)
        self.log(f"Forgetting {bundle_id}.")
        self.refresh_library()

    # ------------------------------------------------------------------ #
    # Misc tab (Nugget-style tweaks)
    # ------------------------------------------------------------------ #
    def _build_misc_tab(self) -> tuple[QWidget, str]:
        page = QWidget()
        layout = QVBoxLayout(page)
        title = QLabel("Miscellaneous tweaks")
        title.setStyleSheet("font-size: 16px; font-weight: bold;")
        layout.addWidget(title)
        hint = QLabel(
            "Apply SpringBoard options, daemon toggles and Liquid Glass settings "
            "with the sparserestore backup restore (iOS 17.0 - 18.1). "
            "Based on Nugget (AGPL-3.0)."
        )
        hint.setWordWrap(True)
        layout.addWidget(hint)

        target_row = QHBoxLayout()
        target_row.addWidget(QLabel("Apply to:"))
        self.misc_target_combo = QComboBox()
        self.misc_target_combo.setMinimumWidth(320)
        target_row.addWidget(self.misc_target_combo, 1)
        misc_refresh = QPushButton("Refresh")
        misc_refresh.clicked.connect(self.refresh_devices)
        target_row.addWidget(misc_refresh)
        layout.addLayout(target_row)

        springboard_button = QPushButton("SpringBoard\u2026")
        springboard_button.clicked.connect(self.open_springboard_dialog)
        daemons_button = QPushButton("Daemons\u2026")
        daemons_button.clicked.connect(self.open_daemons_dialog)
        liquidglass_button = QPushButton("Liquid Glass\u2026")
        liquidglass_button.clicked.connect(self.open_liquidglass_dialog)
        for button in (springboard_button, daemons_button, liquidglass_button):
            button.setMinimumHeight(34)
            layout.addWidget(button)

        self.respring_button = QPushButton("Respring Device")
        self.respring_button.setMinimumHeight(34)
        self.respring_button.clicked.connect(self.respring_device_now)
        layout.addWidget(self.respring_button)

        note = QLabel(
            "A respring crashes SpringBoard (WebKit backdrop-filter overload) so "
            "changes apply without a full reboot. Needs Web Inspector / Remote "
            "Automation enabled in Safari settings on the device."
        )
        note.setWordWrap(True)
        note.setStyleSheet("color: palette(mid);")
        layout.addWidget(note)
        layout.addStretch()
        return page, "Miscellaneous"

    def refresh_misc_combo(self) -> None:
        combo = self.misc_target_combo
        current = combo.currentData()
        combo.clear()
        udids = self.connected_udids(self.devices)
        if not udids:
            combo.addItem("No device connected", None)
            return
        for udid in udids:
            combo.addItem(f"{udid[:8]}\u2026  ({udid})", udid)
        if current in udids:
            combo.setCurrentIndex(combo.findData(current))

    def misc_serial(self) -> str | None:
        return self.misc_target_combo.currentData()

    def open_springboard_dialog(self) -> None:
        self._nugget_dialog = SpringBoardDialog(self, serial=self.misc_serial())
        self._nugget_dialog.show()

    def open_daemons_dialog(self) -> None:
        self._nugget_dialog = DaemonsDialog(self, serial=self.misc_serial())
        self._nugget_dialog.show()

    def open_liquidglass_dialog(self) -> None:
        self._nugget_dialog = LiquidGlassDialog(self, serial=self.misc_serial())
        self._nugget_dialog.show()

    def respring_device_now(self) -> None:
        serial = self.misc_serial()
        if not serial:
            QMessageBox.warning(self, "EmLoad", "Connect a device first.")
            return
        self.statusBar().showMessage("Respringing\u2026")
        self.log("Respringing device\u2026")

        def run(on_progress=None):
            return respring_device(serial, on_progress=on_progress)

        worker = TaskWorker(run, parent=self)
        self._workers.append(worker)
        worker.progress.connect(lambda _phase, _percent, step: self.log(f"[respring] {step}") if step else None)
        worker.finished_ok.connect(lambda result: self._task_done(worker, result, self._respring_done))
        worker.failed.connect(lambda msg: self._task_failed(worker, msg))
        worker.start()

    def _respring_done(self, result: dict[str, Any]) -> None:
        self.log("Respring triggered.")
        self.statusBar().showMessage("Respring triggered", 5000)

    # ------------------------------------------------------------------ #
    # Account tab
    # ------------------------------------------------------------------ #
    def _build_account_tab(self) -> tuple[QWidget, str]:
        page = QWidget()
        layout = QVBoxLayout(page)
        title = QLabel("Apple ID")
        title.setStyleSheet("font-size: 16px; font-weight: bold;")
        layout.addWidget(title)

        self.account_status = QLabel("Checking\u2026")
        self.account_status.setWordWrap(True)
        layout.addWidget(self.account_status)

        self.sign_in_button = QPushButton("Sign In\u2026")
        self.sign_in_button.clicked.connect(self.show_login_dialog)
        self.sign_out_button = QPushButton("Sign Out")
        self.sign_out_button.setEnabled(False)
        self.sign_out_button.clicked.connect(self.sign_out)
        layout.addWidget(self.sign_in_button)
        layout.addWidget(self.sign_out_button)

        note = QLabel(
            "EmLoad signs in directly with Apple (GrandSlam over pinned TLS) and "
            "keeps only short-lived session tokens in your user profile. The "
            "password is never stored or sent anywhere but Apple."
        )
        note.setWordWrap(True)
        note.setStyleSheet("color: #666;")
        layout.addWidget(note)
        layout.addStretch()
        return page, "Account"

    def refresh_account(self) -> None:
        self.run_task(gsa.status, on_done=self._account_status)

    def _account_status(self, status: dict[str, Any]) -> None:
        if not status.get("authenticated") and status.get("account_count", 0) > 0:
            # A saved Apple session exists but none is marked active - resume the
            # most recent one so opening the app signs you back in automatically.
            self.account_status.setText("Resuming saved session\u2026")
            self.run_task(
                self._resume_saved_session,
                on_done=self._session_resumed,
                on_error=lambda _w, _m: self.refresh_account(),
            )
            return
        if not status.get("authenticated"):
            self.account_status.setText("Not signed in.")
            self.sign_in_button.setEnabled(True)
            self.sign_out_button.setEnabled(False)
        else:
            email = status.get("email")
            team = status.get("team_id") or "not provisioned yet"
            self.account_status.setText(
                f"Signed in as {email}\nteam: {team}\n"
                f"developer token: {'yes' if status.get('has_auth_token') else 'no'}"
            )
            self.sign_in_button.setEnabled(True)
            self.sign_out_button.setEnabled(True)

    @staticmethod
    def _resume_saved_session() -> dict[str, Any]:
        """Pick the most recent session that still has a developer token."""
        for account in gsa.list_accounts():
            if account.get("has_auth_token"):
                return gsa.use_account(account["email"])
        return {"status": "nothing_to_resume"}

    def _session_resumed(self, result: dict[str, Any]) -> None:
        if result.get("status") == "active":
            email = result.get("email")
            self.log(f"Auto signed in as {email}.")
            self.statusBar().showMessage(f"Auto signed in as {email}", 8000)
        self.refresh_account()

    def show_login_dialog(self) -> None:
        self._login_dialog = LoginDialog(self)
        self._login_dialog.submit_credentials.connect(self._login_credentials)
        self._login_dialog.submit_code.connect(self._login_code)
        self._login_dialog.show()

    def _login_credentials(self, payload: tuple[str, str]) -> None:
        email, password = payload
        self._login_email = email
        self.run_task(gsa.begin_login, email, password, on_done=self._login_result)

    def _login_code(self, code: str) -> None:
        email = self._login_email or ""
        password = self._login_dialog.password() if self._login_dialog else ""
        self.run_task(gsa.complete_2fa, email, password, code, on_done=self._login_done)

    def _login_result(self, result: dict[str, Any]) -> None:
        if result.get("status") == "2fa_required":
            if self._login_dialog is not None:
                self._login_dialog.show_2fa(result.get("method", "trusteddevice"))
            return
        self._login_done(result)

    def _login_done(self, result: dict[str, Any]) -> None:
        self.refresh_account()
        if result.get("status") == "authenticated":
            self.log("Signed in with your Apple ID.")
            self.statusBar().showMessage("Signed in", 5000)
            if self._login_dialog is not None:
                self._login_dialog.accept()
                self._login_dialog = None
        else:
            self.log(f"Sign-in status: {result}")

    def sign_out(self) -> None:
        if QMessageBox.question(
            self, "EmLoad", "Sign out of EmLoad? This does not uninstall your apps."
        ) != QMessageBox.Yes:
            return
        self.run_task(gsa.logout, None, on_done=lambda _r: self.refresh_account())

    # ------------------------------------------------------------------ #
    # Settings tab
    # ------------------------------------------------------------------ #
    def _build_settings_tab(self) -> tuple[QWidget, str]:
        page = QWidget()
        layout = QVBoxLayout(page)
        title = QLabel("Settings")
        title.setStyleSheet("font-size: 16px; font-weight: bold;")
        layout.addWidget(title)

        form = QFormLayout()
        self.connection_combo = QComboBox()
        self.connection_combo.addItems(["Automatic (USB then Wi-Fi)", "USB only", "Wi-Fi only"])
        self.connection_combo.currentIndexChanged.connect(self._connection_changed)
        form.addRow("Connection", self.connection_combo)

        self.signed_dir_edit = QLineEdit()
        self.signed_dir_edit.setPlaceholderText("(default: data dir\\signed)")
        self.signed_dir_button = QPushButton("Browse\u2026")
        self.signed_dir_button.clicked.connect(self._pick_signed_dir)
        dir_row = QHBoxLayout()
        dir_row.addWidget(self.signed_dir_edit, 1)
        dir_row.addWidget(self.signed_dir_button)
        form.addRow("Signed IPA folder", dir_row)
        layout.addLayout(form)

        self.zsign_label = QLabel()
        self.zsign_label.setWordWrap(True)
        self.zsign_button = QPushButton("Download zsign")
        self.zsign_button.clicked.connect(self.download_zsign)
        layout.addWidget(self.zsign_label)
        layout.addWidget(self.zsign_button)

        self.data_dir_label = QLabel(f"Data directory:\n{paths.data_dir()}")
        self.data_dir_label.setWordWrap(True)
        layout.addWidget(self.data_dir_label)

        self.keep_signed_default = QCheckBox("Keep signed .ipa files by default")
        self.keep_signed_default.toggled.connect(self._save_settings)
        layout.addWidget(self.keep_signed_default)

        layout.addStretch()
        return page, "Settings"

    def _load_settings(self) -> None:
        try:
            config = json.loads(paths.config_file().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            config = {}
        conn = config.get("connection", "auto")
        self.connection_combo.blockSignals(True)
        self.connection_combo.setCurrentIndex({"auto": 0, "usb": 1, "wifi": 2}.get(conn, 0))
        self.connection_combo.blockSignals(False)
        self.signed_dir_edit.setText(config.get("signed_dir", ""))
        self.keep_signed_default.setChecked(bool(config.get("keep_signed")))
        self.refresh_zsign_status()

    def _save_settings(self) -> None:
        config = {
            "connection": {0: "auto", 1: "usb", 2: "wifi"}[self.connection_combo.currentIndex()],
            "signed_dir": self.signed_dir_edit.text().strip(),
            "keep_signed": self.keep_signed_default.isChecked(),
        }
        paths.config_file().write_text(json.dumps(config, indent=2), encoding="utf-8")

    def _connection_changed(self) -> None:
        import os

        value = {0: "auto", 1: "usb", 2: "wifi"}[self.connection_combo.currentIndex()]
        if value == "auto":
            os.environ.pop("EMLOAD_CONNECTION", None)
        else:
            os.environ["EMLOAD_CONNECTION"] = value
        self._save_settings()

    def signed_dir_setting(self) -> str:
        return self.signed_dir_edit.text().strip()

    def _pick_signed_dir(self) -> None:
        chosen = QFileDialog.getExistingDirectory(self, "Folder for signed IPAs")
        if chosen:
            self.signed_dir_edit.setText(chosen)
            self._save_settings()

    def refresh_zsign_status(self) -> None:
        self.run_task(signing.signing_status, on_done=self._zsign_status)

    def _zsign_status(self, status: dict[str, Any]) -> None:
        if status.get("available"):
            self.zsign_label.setText(f"zsign: {status['path']}\n({status.get('version') or '?'})")
            self.zsign_button.setEnabled(False)
            self.zsign_button.setText("zsign installed")
        else:
            self.zsign_label.setText(f"zsign not found: {status.get('error')}")
            self.zsign_button.setEnabled(True)
            self.zsign_button.setText("Download zsign")

    def download_zsign(self) -> None:
        self.zsign_button.setEnabled(False)
        self.zsign_label.setText("Downloading zsign\u2026")
        self.run_task(signing.download_zsign, on_done=lambda _r: self.refresh_zsign_status())

    # ------------------------------------------------------------------ #
    # Diagnostics tab
    # ------------------------------------------------------------------ #
    def _build_diagnostics_tab(self) -> tuple[QWidget, str]:
        page = QWidget()
        layout = QVBoxLayout(page)
        title = QLabel("Diagnostics")
        title.setStyleSheet("font-size: 16px; font-weight: bold;")
        layout.addWidget(title)
        self.diagnostics_list = QListWidget()
        layout.addWidget(self.diagnostics_list, 1)
        run_button = QPushButton("Run checks")
        run_button.clicked.connect(self.run_diagnostics)
        layout.addWidget(run_button)
        return page, "Diagnostics"

    def run_diagnostics(self) -> None:
        self.diagnostics_list.clear()
        self.diagnostics_list.addItem("Running checks\u2026")
        self.run_task(doctor.check, on_done=self._diagnostics_done)

    def _diagnostics_done(self, checks: list[dict[str, Any]]) -> None:
        self.diagnostics_list.clear()
        for check in checks:
            icon = {"ok": "\u2714 ", "warn": "\u26a0 ", "error": "\u2716 "}.get(
                check.get("status"), "? "
            )
            self.diagnostics_list.addItem(f"{icon}{check['name']}: {check['message']}")

    # ------------------------------------------------------------------ #
    # Misc
    # ------------------------------------------------------------------ #
    def log(self, message: str) -> None:
        self.log_view.appendPlainText(message)

    def _start_watch(self) -> None:
        self._watch_thread = UsbmuxWatchThread(self)
        self._watch_thread.devices_changed.connect(self._devices_changed)
        self._watch_thread.watch_error.connect(
            lambda msg: self.statusBar().showMessage(f"Device watch: {msg}", 5000)
        )
        self._watch_thread.start()

    def showEvent(self, event) -> None:  # noqa: D102 - QMainWindow override
        super().showEvent(event)
        self._load_settings()
        self.run_diagnostics()


def run_gui() -> int:
    _install_excepthook()
    app = QApplication(sys.argv)
    app.setApplicationName("EmLoad")
    app.setOrganizationName("EmLoad")
    app.setWindowIcon(_app_icon())
    window = MainWindow()
    window.show()
    return app.exec()


def main() -> int:
    return run_gui()


if __name__ == "__main__":
    sys.exit(main())