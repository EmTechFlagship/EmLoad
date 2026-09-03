"""Tweak registry and per-family loaders (Qt-free port).

Ported from Nugget27 (AGPL-3.0): ``src/tweaks/tweaks.py`` and
``src/tweaks/tweak_loader.py``, reduced to the families EmLoad ships today
(SpringBoard, Daemons, Liquid Glass). Loaders are idempotent: the registry
is a module-level dict shared by every dialog.
"""

from __future__ import annotations

from .locations import FileLocation
from .tweak_classes import AdvancedPlistTweak, BasicPlistTweak, NullifyFileTweak
from .tweak_names import TweakID

#: Global registry of loaded tweaks. Dialogs flip ``enabled``/``value`` on
#: these objects; :func:`emload.nugget.apply.build_files_to_restore` turns the
#: enabled ones into files for the restore.
tweaks: dict[TweakID, object] = {}


def reset_tweaks() -> None:
    """Drop every loaded tweak (fresh state for a new session)."""
    tweaks.clear()


def load_springboard() -> None:
    """Register the SpringBoard options family (idempotent)."""
    if TweakID.LockScreenFootnote in tweaks:
        return
    additional_tweaks = {
        TweakID.LockScreenFootnote: BasicPlistTweak(
            FileLocation.footnote,
            key="LockScreenFootnote",
            value="",
        ),
        TweakID.WatchOSCompatibility: AdvancedPlistTweak(
            file_location=FileLocation.nanoregistry,
            key_values={
                "IOS_PAIRING_EOL_MIN_PAIRING_COMPATIBILITY_VERSION_CHIPIDS": "",
                "maxPairingCompatibilityVersion": 37,
                "lastRestoreIdentifier": "CD97EEB8-BCD2-486B-BC13-C384E6B916C4",
                "minPairingCompatibilityVersionWithChipID": 1,
                "lastRestoreIdentifier_state": 0,
                "AdvertisingIdentifierSeed": "85E70251-1960-4DA0-A321-B68AC118FAB5",
                "minPairingCompatibilityVersion": 1,
            },
        ),
        TweakID.AirDropDisableTimeLimit: BasicPlistTweak(
            FileLocation.airdrop,
            "OverrideTimeLimitEveryoneMode",
        ),
        TweakID.SBDontLockAfterCrash: BasicPlistTweak(
            FileLocation.springboard,
            "SBDontLockAfterCrash",
        ),
        TweakID.SBDontDimOrLockOnAC: BasicPlistTweak(
            FileLocation.springboard,
            "SBDontDimOrLockOnAC",
        ),
        TweakID.SBHideLowPowerAlerts: BasicPlistTweak(
            FileLocation.springboard,
            "SBHideLowPowerAlerts",
        ),
        TweakID.SBHideACPower: BasicPlistTweak(
            FileLocation.springboard,
            "SBHideACPower",
        ),
        TweakID.SBNeverBreadcrumb: BasicPlistTweak(
            FileLocation.springboard,
            "SBNeverBreadcrumb",
        ),
        TweakID.SBShowSupervisionTextOnLockScreen: BasicPlistTweak(
            FileLocation.springboard,
            "SBShowSupervisionTextOnLockScreen",
        ),
        TweakID.AirplaySupport: BasicPlistTweak(
            FileLocation.springboard,
            "SBExtendedDisplayOverrideSupportForAirPlayAndDontFileRadars",
        ),
        TweakID.SBMinimumLockscreenIdleTime: BasicPlistTweak(
            FileLocation.springboard,
            key="SBMinimumLockscreenIdleTime",
            value=5,
        ),
        TweakID.SBAlwaysShowSystemApertureInSnapshots: BasicPlistTweak(
            FileLocation.springboard,
            "SBAlwaysShowSystemApertureInSnapshots",
        ),
        TweakID.HideDICompletely: BasicPlistTweak(
            FileLocation.springboard,
            "SBSuppressDynamicIslandCompletely",
        ),
        TweakID.SBShowAuthenticationEngineeringUI: BasicPlistTweak(
            FileLocation.springboard,
            "SBShowAuthenticationEngineeringUI",
        ),
        TweakID.UseFloatingTabBar: BasicPlistTweak(
            FileLocation.uikit,
            key="UseFloatingTabBar",
            value=False,
        ),
    }
    tweaks.update(additional_tweaks)


def load_daemons() -> None:
    """Register the daemons family (idempotent)."""
    if TweakID.Daemons in tweaks:
        return
    additional_tweaks = {
        TweakID.Daemons: AdvancedPlistTweak(
            FileLocation.disabledDaemons,
            {
                "com.apple.magicswitchd.companion": True,
                "com.apple.security.otpaird": True,
                "com.apple.dhcp6d": True,
                "com.apple.bootpd": True,
                "com.apple.ftp-proxy-embedded": False,
                "com.apple.relevanced": True,
            },
            owner=0,
            group=0,
        ),
        TweakID.ClearScreenTimeAgentPlist: NullifyFileTweak(FileLocation.screentime),
    }
    tweaks.update(additional_tweaks)


def load_liquidglass() -> None:
    """Register the Liquid Glass family (idempotent)."""
    if TweakID.DisableSolarium in tweaks:
        return
    additional_tweaks = {
        TweakID.ForceSolariumFallback: BasicPlistTweak(
            FileLocation.globalPreferences,
            "SolariumForceFallback",
        ),
        TweakID.DisableSolarium: BasicPlistTweak(
            FileLocation.globalPreferences,
            "com.apple.SwiftUI.DisableSolarium",
        ),
        TweakID.IgnoreSolariumLinkedOnCheck: BasicPlistTweak(
            FileLocation.globalPreferences,
            "com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck",
        ),
        TweakID.NoLiquidClock: BasicPlistTweak(
            FileLocation.globalPreferences,
            "SBDisallowGlassTime",
        ),
        TweakID.NoLiquidDock: BasicPlistTweak(
            FileLocation.globalPreferences,
            "SBDisableGlassDock",
        ),
        TweakID.DisableSpecularMotion: BasicPlistTweak(
            FileLocation.globalPreferences,
            "SBDisableSpecularEverywhereUsingLSSAssertion",
        ),
        TweakID.DisableOuterRefraction: BasicPlistTweak(
            FileLocation.globalPreferences,
            "SolariumDisableOuterRefraction",
        ),
        TweakID.DisableSolariumHDR: BasicPlistTweak(
            FileLocation.globalPreferences,
            "SolariumAllowHDR",
            value=False,
        ),
    }
    tweaks.update(additional_tweaks)