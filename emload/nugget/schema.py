"""Front-end-agnostic description of the Misc tweak dialogs.

The PySide6 GUI builds the SpringBoard / Daemons / Liquid Glass dialogs by hand
(``emload.gui.nugget_dialogs``). A non-Qt front end cannot import that module,
so this module describes the same dialogs as plain data:

    {"group": "springboard", "title": "...", "subtitle": "...",
     "controls": [{"id": ..., "kind": "tri"|"check"|"text"|"number",
                   "label": ..., "state"|"value": ...}, ...]}

and applies edits back onto the shared tweak registry
(:data:`emload.nugget.tweaks.tweaks`). The UI stays a dumb renderer; every
tweak semantic (radio defaults, inverted values, daemon groups, master toggles)
lives here in Python.

Ported behavior from Nugget27 (AGPL-3.0) via
``emload.gui.nugget_dialogs``.
"""

from __future__ import annotations

from typing import Any

from .daemons import Daemon
from .tweak_names import TweakID
from .tweaks import (
    load_daemons,
    load_liquidglass,
    load_springboard,
    tweaks,
)

#: Which loader builds which family (dialogs call these before rendering).
_LOADERS = {
    "springboard": load_springboard,
    "daemons": load_daemons,
    "liquidglass": load_liquidglass,
}

_GROUP_TITLES = {
    "springboard": (
        "SpringBoard Options",
        "SpringBoard preferences applied via sparserestore.",
    ),
    "daemons": (
        "Daemons",
        "Disable/enable daemons by editing "
        "/var/db/com.apple.xpc.launchd/disabled.plist.",
    ),
    "liquidglass": (
        "Liquid Glass",
        "Liquid Glass (Solarium) behavior toggles.",
    ),
}

#: The radio rows, in dialog order: (label, tweak id, inverted value).
_SPRINGBOARD_TRI_ROWS: list[tuple[str, TweakID, bool]] = [
    ("AirDrop: disable time limit", TweakID.AirDropDisableTimeLimit, False),
    ("Don't lock after crash", TweakID.SBDontLockAfterCrash, False),
    ("Don't dim or lock on AC", TweakID.SBDontDimOrLockOnAC, False),
    ("Hide low power alerts", TweakID.SBHideLowPowerAlerts, False),
    ("Hide AC power", TweakID.SBHideACPower, False),
    ("Disable breadcrumbs", TweakID.SBNeverBreadcrumb, False),
    ("Supervision text on Lock Screen", TweakID.SBShowSupervisionTextOnLockScreen, False),
    ("Enable AirPlay support", TweakID.AirplaySupport, False),
    ("Show Dynamic Island in screenshots", TweakID.SBAlwaysShowSystemApertureInSnapshots, False),
    ("Hide Dynamic Island completely", TweakID.HideDICompletely, False),
    ("Show authentication engineering UI", TweakID.SBShowAuthenticationEngineeringUI, False),
    ("Use floating tab bar", TweakID.UseFloatingTabBar, True),
]

_LIQUIDGLASS_TRI_ROWS: list[tuple[str, TweakID, bool]] = [
    ("Force Solarium fallback", TweakID.ForceSolariumFallback, False),
    ("Disable Solarium", TweakID.DisableSolarium, False),
    ("Ignore Solarium linked-on check", TweakID.IgnoreSolariumLinkedOnCheck, False),
    ("No Liquid Clock", TweakID.NoLiquidClock, False),
    ("No Liquid Dock", TweakID.NoLiquidDock, False),
    ("Disable specular motion", TweakID.DisableSpecularMotion, False),
    ("Disable outer refraction", TweakID.DisableOuterRefraction, False),
    ("Disable Solarium HDR", TweakID.DisableSolariumHDR, True),
]

#: Daemon groups shown in the dialog, in order: (label, daemon enum member).
_DAEMON_ROWS: list[tuple[str, Daemon]] = [
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


def _tri_state(tweak: Any, invert: bool) -> str:
    """Translate a tweak's (enabled, value) pair into Default/Enabled/Disabled."""
    if not tweak.enabled:
        return "default"
    on = bool(tweak.value)
    if invert:
        on = not on
    return "enabled" if on else "disabled"


def _tri_control(label: str, tweak_id: TweakID, invert: bool) -> dict[str, Any]:
    return {
        "id": tweak_id.name,
        "kind": "tri",
        "label": label,
        "invert": invert,
        "state": _tri_state(tweaks[tweak_id], invert),
    }


def describe(group: str) -> dict[str, Any]:
    """Return the full control description for one tweak family."""
    try:
        loader = _LOADERS[group]
    except KeyError:
        raise ValueError(f"unknown tweak group: {group!r}") from None
    loader()
    title, subtitle = _GROUP_TITLES[group]

    controls: list[dict[str, Any]] = []
    if group == "springboard":
        footnote = tweaks[TweakID.LockScreenFootnote]
        controls.append({
            "id": TweakID.LockScreenFootnote.name,
            "kind": "text",
            "label": "Lock Screen footnote",
            "placeholder": "(empty = default)",
            "value": str(footnote.value or ""),
        })
        autolock = tweaks[TweakID.SBMinimumLockscreenIdleTime]
        controls.append({
            "id": TweakID.SBMinimumLockscreenIdleTime.name,
            "kind": "number",
            "label": "Auto-Lock idle time (seconds)",
            "value": int(autolock.value or 5),
            "min": 1,
            "max": 600,
        })
        controls.append({
            "id": TweakID.WatchOSCompatibility.name,
            "kind": "check",
            "label": "WatchOS compatibility",
            "value": bool(tweaks[TweakID.WatchOSCompatibility].enabled),
        })
        controls.append({"kind": "separator"})
        controls.append({"kind": "label", "text": "Options"})
        controls.extend(
            _tri_control(label, tweak_id, invert)
            for label, tweak_id, invert in _SPRINGBOARD_TRI_ROWS
        )
    elif group == "daemons":
        master = tweaks[TweakID.Daemons]
        controls.append({
            "id": TweakID.Daemons.name,
            "kind": "master",
            "label": "Modify Daemons",
            "value": bool(master.enabled),
        })
        values = master.value or {}
        for label, daemon in _DAEMON_ROWS:
            keys = list(daemon.value)
            controls.append({
                "id": f"Daemon.{daemon.name}",
                "kind": "daemon",
                "label": label,
                "keys": keys,
                # A group counts as disabled when every key it owns is disabled.
                "value": all(values.get(key) is True for key in keys),
            })
        controls.append({"kind": "separator"})
        controls.append({
            "id": TweakID.ClearScreenTimeAgentPlist.name,
            "kind": "check",
            "label": "Clear Screen Time Agent plist",
            "value": bool(tweaks[TweakID.ClearScreenTimeAgentPlist].enabled),
        })
    else:  # liquidglass
        controls.extend(
            _tri_control(label, tweak_id, invert)
            for label, tweak_id, invert in _LIQUIDGLASS_TRI_ROWS
        )

    return {
        "group": group,
        "title": title,
        "subtitle": subtitle,
        "controls": controls,
    }


def _require(group: str, control_id: str) -> Any:
    if group not in _LOADERS:
        raise ValueError(f"unknown tweak group: {group!r}")
    _LOADERS[group]()
    if control_id.startswith("Daemon."):
        name = control_id.split(".", 1)[1]
        try:
            return Daemon[name]
        except KeyError:
            raise ValueError(f"unknown daemon group: {name!r}") from None
    try:
        return tweaks[TweakID[control_id]]
    except KeyError:
        raise ValueError(f"unknown tweak id: {control_id!r}") from None


def _tri_invert(group: str, control_id: str) -> bool:
    rows = _SPRINGBOARD_TRI_ROWS if group == "springboard" else _LIQUIDGLASS_TRI_ROWS
    for _label, tweak_id, invert in rows:
        if tweak_id.name == control_id:
            return invert
    return False


def set_control(
    group: str,
    control_id: str,
    *,
    state: str | None = None,
    value: Any = None,
    checked: bool | None = None,
) -> dict[str, Any]:
    """Apply one control edit, mirroring the PySide6 dialog handlers.

    ``state`` is for radio rows (``default``/``enabled``/``disabled``),
    ``value`` for text/number/check controls, ``checked`` for daemon groups.
    Returns the refreshed control so the caller can re-render without a
    second round trip.
    """
    target = _require(group, control_id)

    if control_id.startswith("Daemon."):
        # ``Daemon`` is an enum member: toggling a group writes every key it
        # owns and, when enabling, also switches on the master "Modify Daemons"
        # toggle (matches the PySide6 dialog's _on_daemon).
        master = tweaks[TweakID.Daemons]
        enabled = bool(checked)
        master.set_multiple_values(list(target.value), value=enabled)
        if enabled:
            master.set_enabled(True)
    elif control_id == TweakID.Daemons.name:
        target.set_enabled(bool(value if value is not None else checked))
    elif state is not None:
        invert = _tri_invert(group, control_id)
        if state not in ("default", "enabled", "disabled"):
            raise ValueError(f"invalid tri state: {state!r}")
        if state == "default":
            target.set_enabled(False)
        else:
            # "Enabled" means value True, unless the row is inverted (e.g.
            # "Use floating tab bar", where False is the enabled state).
            target.set_value((state == "enabled") != invert)
    elif control_id == TweakID.LockScreenFootnote.name:
        target.set_value(str(value or ""), toggle_enabled=True)
    elif control_id in (
        TweakID.SBMinimumLockscreenIdleTime.name,
    ):
        target.set_value(int(value), toggle_enabled=True)
    else:
        # Plain checkboxes: WatchOSCompatibility, ClearScreenTimeAgentPlist.
        target.set_enabled(bool(value if value is not None else checked))

    # Echo back the control's new state.
    for control in describe(group)["controls"]:
        if control.get("id") == control_id:
            return control
    return {"id": control_id}


def apply_options(
    *,
    respring: bool = False,
    reboot: bool = True,
    apply_method: str = "auto",
    transfer_mode: str = "localhost",
    skip_setup: bool = True,
) -> dict[str, Any]:
    """Validate and normalize the Apply-sheet options for ``apply_tweaks``."""
    if apply_method not in ("auto", "afc", "restore"):
        raise ValueError(f"invalid apply method: {apply_method!r}")
    if transfer_mode not in ("localhost", "ondevice"):
        raise ValueError(f"invalid transfer mode: {transfer_mode!r}")
    return {
        "respring_after": bool(respring),
        # Respring and reboot are mutually exclusive in the dialogs.
        "reboot": bool(reboot) and not bool(respring),
        "apply_method": apply_method,
        "transfer_mode": transfer_mode,
        "skip_setup": bool(skip_setup),
    }
