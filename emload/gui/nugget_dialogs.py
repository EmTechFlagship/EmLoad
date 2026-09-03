"""Dialogs for the Miscellaneous menu (SpringBoard / Daemons / Liquid Glass).

Ports the Nugget27 tool pages (``src/gui/pages/tools/springboard.py``,
``.../daemons.py``, ``.../liquidglass.py`` and ``.../page.py``, AGPL-3.0)
from .ui-file based pages to plain PySide6 dialogs. Controls mutate the
shared tweak registry (``emload.nugget.tweaks``) live; Apply runs
:func:`emload.nugget.apply.apply_tweaks` on a worker thread.
"""

from __future__ import annotations

from typing import Any

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QButtonGroup,
    QCheckBox,
    QComboBox,
    QDialog,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QRadioButton,
    QScrollArea,
    QSpinBox,
    QVBoxLayout,
    QWidget,
)

from .. import nugget
from ..nugget import Daemon, TweakID, tweaks
from .workers import TaskWorker


# --------------------------------------------------------------------------- #
# Shared helpers
# --------------------------------------------------------------------------- #
def _add_radio_row(
    layout: QVBoxLayout,
    label_text: str,
    key: TweakID,
    invert_values: bool = False,
) -> None:
    """A Default/Enabled/Disabled row wired to ``tweaks[key]``.

    Ported from Nugget27's ``Page.createRadioBtns`` (AGPL-3.0).
    """
    row = QHBoxLayout()
    label = QLabel(label_text)
    label.setMinimumWidth(230)
    row.addWidget(label)
    group = QButtonGroup(layout.parentWidget())
    default_btn = QRadioButton("Default")
    default_btn.setChecked(True)
    enabled_btn = QRadioButton("Enabled")
    disabled_btn = QRadioButton("Disabled")
    for btn in (default_btn, enabled_btn, disabled_btn):
        group.addButton(btn)
        row.addWidget(btn)
    row.addStretch()
    layout.addLayout(row)

    default_btn.clicked.connect(lambda _=False, k=key: tweaks[k].set_enabled(False))
    enabled_btn.clicked.connect(
        lambda _=False, k=key, inv=invert_values: tweaks[k].set_value(not inv)
    )
    disabled_btn.clicked.connect(
        lambda _=False, k=key, inv=invert_values: tweaks[k].set_value(inv)
    )


# --------------------------------------------------------------------------- #
# Base dialog
# --------------------------------------------------------------------------- #
class TweakDialog(QDialog):
    """A scrollable tweak dialog with an Apply that restores the device."""

    def __init__(
        self,
        parent: QWidget | None,
        title: str,
        subtitle: str,
        serial: str | None,
    ):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.resize(540, 640)
        self.serial = serial
        self._worker: TaskWorker | None = None

        root = QVBoxLayout(self)

        sub = QLabel(subtitle)
        sub.setWordWrap(True)
        root.addWidget(sub)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QScrollArea.NoFrame)
        content = QWidget()
        self.rows_layout = QVBoxLayout(content)
        self.rows_layout.setContentsMargins(4, 4, 4, 4)
        scroll.setWidget(content)
        root.addWidget(scroll, 1)

        self.status_label = QLabel(f"Apply to {serial or 'no device'}.")
        self.status_label.setWordWrap(True)
        root.addWidget(self.status_label)

        self.progress_bar = QProgressBar()
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(0)
        root.addWidget(self.progress_bar)

        self.respring_check = QCheckBox("Respring after apply (instead of a full reboot)")
        self.reboot_check = QCheckBox("Reboot after apply")
        self.reboot_check.setChecked(True)
        self.respring_check.toggled.connect(self._on_respring_toggled)
        self.reboot_check.toggled.connect(self._on_reboot_toggled)
        root.addWidget(self.respring_check)
        root.addWidget(self.reboot_check)

        self.skip_setup_check = QCheckBox(
            "Skip setup after apply (prevents the \"Swipe up to upgrade\" reset screen)"
        )
        self.skip_setup_check.setChecked(True)
        self.skip_setup_check.setToolTip(
            "Restores the skip-setup configuration so iOS skips the "
            "\"Swipe up to upgrade\" / Setup Assistant flow after rebooting, "
            "keeping your on-device settings and data.\n\n"
            "Best-effort: on BookRestore devices this forces the Restore "
            "method (full system restore + reboot) and Apple does not always "
            "honor the skip-setup files. If you see \"Swipe up to upgrade\" "
            "after applying, do NOT swipe - force-off the phone instead.\n\n"
            "Note: applies are hard-blocked on iOS 27 (it does not honor "
            "skip-setup and can leave the device stuck on that white screen)."
        )
        root.addWidget(self.skip_setup_check)

        br_row = QHBoxLayout()
        br_row.addWidget(QLabel("Apply method:"))
        self.apply_method_combo = QComboBox()
        self.apply_method_combo.addItem("Automatic", "auto")
        self.apply_method_combo.addItem("BookRestore (AFC)", "afc")
        self.apply_method_combo.addItem("BookRestore (Restore)", "restore")
        self.apply_method_combo.setToolTip(
            "Automatic: sparserestore on iOS < 18.2, BookRestore AFC on 18.2+, "
            "or BookRestore Restore when root-owned files (Daemons) are enabled."
        )
        br_row.addWidget(self.apply_method_combo, 1)
        root.addLayout(br_row)

        br_row = QHBoxLayout()
        br_row.addWidget(QLabel("BookRestore transfer:"))
        self.transfer_mode_combo = QComboBox()
        self.transfer_mode_combo.addItem("LocalHost (served from this PC)", "localhost")
        self.transfer_mode_combo.addItem("On Device", "ondevice")
        self.transfer_mode_combo.setToolTip(
            "How BookRestore payload files reach the device: served over your "
            "LAN by EmLoad, or fetched from on-device/upstream assets."
        )
        br_row.addWidget(self.transfer_mode_combo, 1)
        root.addLayout(br_row)

        buttons = QHBoxLayout()
        self.apply_button = QPushButton("Apply")
        self.apply_button.setDefault(True)
        self.apply_button.clicked.connect(self.run_apply)
        cancel_button = QPushButton("Close")
        cancel_button.clicked.connect(self.reject)
        buttons.addWidget(self.apply_button)
        buttons.addWidget(cancel_button)
        root.addLayout(buttons)

        if not serial:
            self.apply_button.setEnabled(False)
            self.status_label.setText("Connect a device first, then open this dialog again.")

    # ------------------------------------------------------------------ #
    def _on_respring_toggled(self, checked: bool) -> None:
        if checked:
            self.reboot_check.setChecked(False)

    def _on_reboot_toggled(self, checked: bool) -> None:
        if checked:
            self.respring_check.setChecked(False)

    def run_apply(self) -> None:
        if not self.serial:
            QMessageBox.warning(self, "EmLoad", "Connect a device first.")
            return
        self.apply_button.setEnabled(False)
        self.progress_bar.setValue(0)
        self.status_label.setText("Starting\u2026")

        worker = TaskWorker(
            nugget.apply_tweaks,
            self.serial,
            respring_after=self.respring_check.isChecked(),
            reboot=self.reboot_check.isChecked(),
            apply_method=self.apply_method_combo.currentData(),
            transfer_mode=self.transfer_mode_combo.currentData(),
            skip_setup=self.skip_setup_check.isChecked(),
            parent=self,
        )
        self._worker = worker
        worker.progress.connect(self._on_progress)
        worker.finished_ok.connect(self._on_done)
        worker.failed.connect(self._on_failed)
        worker.start()

    def _on_progress(self, phase: str, percent: Any, step: str | None) -> None:
        if percent is not None:
            self.progress_bar.setValue(int(percent))
        if step:
            self.status_label.setText(f"[{phase}] {step}")

    def _on_done(self, result: dict) -> None:
        self.apply_button.setEnabled(True)
        self.progress_bar.setValue(100)
        warning = result.get("warning")
        message = "Tweaks applied."
        if warning:
            message += f"\n\n{warning}"
        QMessageBox.information(self, "EmLoad", message)
        self.status_label.setText("Done.")
        self.accept()

    def _on_failed(self, message: str) -> None:
        self.apply_button.setEnabled(True)
        self.status_label.setText("Failed.")
        QMessageBox.critical(self, "EmLoad", message)

    def closeEvent(self, event) -> None:  # noqa: D102 - QDialog override
        if self._worker is not None and self._worker.isRunning():
            # destroy a running worker and the dialog gets deleted under it -
            # tell the user to wait instead
            event.ignore()
            self.status_label.setText("Applying\u2026 wait for it to finish.")
            return
        super().closeEvent(event)


# --------------------------------------------------------------------------- #
# SpringBoard
# --------------------------------------------------------------------------- #
class SpringBoardDialog(TweakDialog):
    def __init__(self, parent: QWidget | None, serial: str | None):
        nugget.load_springboard()
        super().__init__(
            parent,
            "SpringBoard Options",
            "SpringBoard preferences applied via sparserestore.",
            serial,
        )
        rows = self.rows_layout

        # Lock Screen footnote
        footnote_row = QHBoxLayout()
        footnote_row.addWidget(QLabel("Lock Screen footnote"))
        self.footnote_edit = QLineEdit()
        self.footnote_edit.setPlaceholderText("(empty = default)")
        self.footnote_edit.textEdited.connect(self._on_footnote)
        footnote_row.addWidget(self.footnote_edit, 1)
        rows.addLayout(footnote_row)

        # Auto-Lock
        autolock_row = QHBoxLayout()
        autolock_row.addWidget(QLabel("Auto-Lock idle time (seconds)"))
        self.autolock_spin = QSpinBox()
        self.autolock_spin.setRange(1, 600)
        self.autolock_spin.setValue(5)
        self.autolock_spin.valueChanged.connect(self._on_autolock)
        autolock_row.addWidget(self.autolock_spin)
        autolock_row.addStretch()
        rows.addLayout(autolock_row)

        # WatchOS compatibility
        self.watchos_check = QCheckBox("WatchOS compatibility")
        self.watchos_check.toggled.connect(
            lambda checked: tweaks[TweakID.WatchOSCompatibility].set_enabled(checked)
        )
        rows.addWidget(self.watchos_check)

        rows.addWidget(_separator())
        rows.addWidget(QLabel("Options"))

        _add_radio_row(rows, "AirDrop: disable time limit", TweakID.AirDropDisableTimeLimit)
        _add_radio_row(rows, "Don't lock after crash", TweakID.SBDontLockAfterCrash)
        _add_radio_row(rows, "Don't dim or lock on AC", TweakID.SBDontDimOrLockOnAC)
        _add_radio_row(rows, "Hide low power alerts", TweakID.SBHideLowPowerAlerts)
        _add_radio_row(rows, "Hide AC power", TweakID.SBHideACPower)
        _add_radio_row(rows, "Disable breadcrumbs", TweakID.SBNeverBreadcrumb)
        _add_radio_row(rows, "Supervision text on Lock Screen", TweakID.SBShowSupervisionTextOnLockScreen)
        _add_radio_row(rows, "Enable AirPlay support", TweakID.AirplaySupport)
        _add_radio_row(rows, "Show Dynamic Island in screenshots", TweakID.SBAlwaysShowSystemApertureInSnapshots)
        _add_radio_row(rows, "Hide Dynamic Island completely", TweakID.HideDICompletely)
        _add_radio_row(rows, "Show authentication engineering UI", TweakID.SBShowAuthenticationEngineeringUI)
        _add_radio_row(rows, "Use floating tab bar", TweakID.UseFloatingTabBar, invert_values=True)

    # ------------------------------------------------------------------ #
    def _on_footnote(self, text: str) -> None:
        tweaks[TweakID.LockScreenFootnote].set_value(text, toggle_enabled=True)

    def _on_autolock(self, value: int) -> None:
        tweaks[TweakID.SBMinimumLockscreenIdleTime].set_value(value, toggle_enabled=True)


# --------------------------------------------------------------------------- #
# Daemons
# --------------------------------------------------------------------------- #
class DaemonsDialog(TweakDialog):
    def __init__(self, parent: QWidget | None, serial: str | None):
        nugget.load_daemons()
        super().__init__(
            parent,
            "Daemons",
            "Disable/enable daemons by editing /var/db/com.apple.xpc.launchd/disabled.plist.",
            serial,
        )
        rows = self.rows_layout

        self.master_check = QCheckBox("Modify Daemons")
        self.master_check.toggled.connect(self._on_master)
        rows.addWidget(self.master_check)

        self.content = QWidget()
        content_layout = QVBoxLayout(self.content)
        content_layout.setContentsMargins(16, 0, 0, 0)

        daemon_groups: list[tuple[str, Daemon]] = [
            ("Thermal monitor", Daemon.thermalmonitord),
            ("OTA updates", Daemon.OTA),
            ("Usage tracking", Daemon.UsageTrackingAgent),
            ("Game Center", Daemon.GameCenter),
            ("Screen Time", Daemon.ScreenTime),
            ("Crash reports", Daemon.CrashReports),
            ("AT wakeup", Daemon.ATWAKEUP),
            ("Tips", Daemon.Tips),
            ("VPN (racoon)", Daemon.VPN),
            ("Location", Daemon.Location),
            ("Chinese LAN", Daemon.ChineseLAN),
            ("HealthKit", Daemon.HealthKit),
            ("AirPrint", Daemon.AirPrint),
            ("AssistiveTouch", Daemon.AssistiveTouch),
            ("iCloud", Daemon.iCloud),
            ("Internet tethering", Daemon.InternetTethering),
            ("Passbook", Daemon.PassBook),
            ("Spotlight", Daemon.Spotlight),
            ("Voice Control", Daemon.VoiceControl),
            ("Nano TimeKit", Daemon.NanoTimeKit),
            ("Diagnostics", Daemon.Diagnostics),
            ("Follow-up", Daemon.FollowUp),
        ]
        for label_text, group in daemon_groups:
            box = QCheckBox(label_text)
            box.toggled.connect(
                lambda checked, g=group: self._on_daemon(g, checked)
            )
            content_layout.addWidget(box)

        content_layout.addWidget(_separator())
        self.clear_screentime_check = QCheckBox("Clear Screen Time Agent plist")
        self.clear_screentime_check.toggled.connect(
            lambda checked: tweaks[TweakID.ClearScreenTimeAgentPlist].set_enabled(checked)
        )
        content_layout.addWidget(self.clear_screentime_check)

        rows.addWidget(self.content)
        self.content.setEnabled(False)

    # ------------------------------------------------------------------ #
    def _on_master(self, checked: bool) -> None:
        tweaks[TweakID.Daemons].set_enabled(checked)
        self.content.setEnabled(checked)

    def _on_daemon(self, group: Daemon, checked: bool) -> None:
        tweaks[TweakID.Daemons].set_multiple_values(group.value, value=checked)
        if checked:
            # make sure the master toggle is on so it actually applies
            self.master_check.setChecked(True)
            self._on_master(True)


# --------------------------------------------------------------------------- #
# Liquid Glass
# --------------------------------------------------------------------------- #
class LiquidGlassDialog(TweakDialog):
    def __init__(self, parent: QWidget | None, serial: str | None):
        nugget.load_liquidglass()
        super().__init__(
            parent,
            "Liquid Glass",
            "Liquid Glass (Solarium) behavior toggles.",
            serial,
        )
        rows = self.rows_layout

        _add_radio_row(rows, "Force Solarium fallback", TweakID.ForceSolariumFallback)
        _add_radio_row(rows, "Disable Solarium", TweakID.DisableSolarium)
        _add_radio_row(rows, "Ignore Solarium link-on check", TweakID.IgnoreSolariumLinkedOnCheck)
        _add_radio_row(rows, "No Liquid Clock", TweakID.NoLiquidClock)
        _add_radio_row(rows, "No Liquid Dock", TweakID.NoLiquidDock)
        _add_radio_row(rows, "Disable specular motion", TweakID.DisableSpecularMotion)
        _add_radio_row(rows, "Disable outer refraction", TweakID.DisableOuterRefraction)
        _add_radio_row(rows, "Disable Solarium HDR", TweakID.DisableSolariumHDR, invert_values=True)


def _separator() -> QWidget:
    line = QWidget()
    line.setFixedHeight(1)
    line.setStyleSheet("background: palette(mid);")
    return line