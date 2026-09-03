"""Apply enabled tweaks to a device (sparserestore + BookRestore, Qt-free).

Adapted from Nugget27 (AGPL-3.0): ``src/devicemanagement/device_manager.py``
(``apply_changes`` / ``get_domain_for_path`` / ``concat_file``) and
``src/restore/__init__.py``.

Routing:

- iOS < 18.2 (or the unpatched betas ``22C5109p`` / ``22C5125e``) is applied
  with sparserestore (exploit + domain backup restores), the historical path.
- iOS 18.2+ (``Device.has_bookrestore()``) uses BookRestore: the AFC method by
  default (no reboot, needs Developer Mode) or the Restore method (a regular
  MobileBackup2 restore of a crafted Books database).
- **iOS 27 is hard-blocked** (including 27 Beta 4, build ``24A5390f``):
  Apple's changed setup flow does not honor the skip-setup files, so applies
  can leave the device on the white "Swipe up to upgrade" screen.
- Fully patched devices (neither) raise :class:`NuggetError`.
"""

from __future__ import annotations

import asyncio
import os
import plistlib
from typing import Any, Callable

from .. import lockdown
from .._asyncutil import maybe_await, run
from .bookrestore import (
    BookRestoreFileTransferMethod,
    BooksContainerUuid,
    cleanup_server_folder,
    close_dl_connection,
    create_local_server,
    create_server_folder,
    generate_bldbmanager,
    perform_bookrestore_async,
)
from .constants import MAX_VERSION, MIN_VERSION, Device, Version
from .errors import NuggetError
from .restore import FileToRestore, reboot_device, restore_files
from .respring import trigger_respring_async
from .tweaks import tweaks
from .tweak_classes import BasicPlistTweak, NullifyFileTweak

ProgressFn = Callable[[str, Any, str | None], None]


def _progress(on_progress: ProgressFn | None, phase: str, percent: Any, step: str | None) -> None:
    if on_progress:
        on_progress(phase, percent, step)


# --------------------------------------------------------------------------- #
# Skip setup (prevents the "Swipe up to upgrade" / Setup Assistant reset)
# --------------------------------------------------------------------------- #
#: Setup steps and flags the device should skip after a restore reboot.
#: Ported from Nugget27 ``device_manager.add_skip_setup`` (AGPL-3.0).
SKIP_SETUP_STEPS: list[str] = [
    "Location", "Restore", "SIMSetup", "Android", "AppleID", "IntendedUser",
    "TOS", "Siri", "ScreenTime", "Diagnostics", "SoftwareUpdate", "Passcode",
    "Biometric", "Payment", "Zoom", "DisplayTone", "MessagingActivationUsingPhoneNumber",
    "HomeButtonSensitivity", "CloudStorage", "ScreenSaver", "TapToSetup", "Keyboard",
    "PreferredLanguage", "SpokenLanguage", "WatchMigration", "OnBoarding",
    "TVProviderSignIn", "TVHomeScreenSync", "Privacy", "TVRoom", "iMessageAndFaceTime",
    "AppStore", "Safety", "Multitasking", "ActionButton", "TermsOfAddress",
    "AccessibilityAppearance", "Welcome", "Appearance", "RestoreCompleted",
    "UpdateCompleted", "WiFi", "Display", "Tone", "LanguageAndLocale", "TouchID",
    "TrueToneDisplay", "FileVault", "iCloudStorage", "iCloudDiagnostics", "Registration",
    "DeviceToDeviceMigration", "UnlockWithWatch", "Accessibility", "All",
    "ExpressLanguage", "Language", "N/A", "Region", "Avatar", "DeviceProtection",
    "Key", "LockdownMode", "Wallpaper", "PrivacySubtitle", "SecuritySubtitle",
    "DataSubtitle", "AppleIDSubtitle", "AppearanceSubtitle", "PreferredLang",
    "OnboardingSubtitle", "AppleTVSubtitle", "Intelligence", "WebContentFiltering",
    "CameraButton", "AdditionalPrivacySettings", "EnableLockdownMode", "OSShowcase",
    "SafetyAndHandling", "Tips", "AgeBasedSafetySettings",
]


async def _add_skip_setup(client: Any, files_to_restore: list[FileToRestore]) -> None:
    """Add the skip-setup configuration files to the restore list.

    Without these, a device rebooted after a (sparserestore/BookRestore) apply
    can show the white "Swipe up to upgrade" screen and then run Setup
    Assistant, which looks like a reset. Restoring the CloudConfiguration
    + purplebuddy markers makes iOS skip that flow and keep on-device data.
    Ported from Nugget27 (AGPL-3.0) ``add_skip_setup`` (without supervision).
    """
    cloud_config_plist: dict = {}
    try:
        from pymobiledevice3.services.mobile_config import MobileConfigService

        existing = await maybe_await(
            MobileConfigService(lockdown=client).get_cloud_configuration()
        )
        if isinstance(existing, dict):
            cloud_config_plist = existing
    except Exception:  # noqa: BLE001 - a fresh default config is fine
        cloud_config_plist = {}

    cloud_config_plist["SkipSetup"] = SKIP_SETUP_STEPS
    cloud_config_plist["AllowPairing"] = True
    cloud_config_plist["ConfigurationWasApplied"] = True
    cloud_config_plist["CloudConfigurationUIComplete"] = True
    cloud_config_plist["IsSupervised"] = False
    cloud_config_plist["ConfigurationSource"] = 0
    cloud_config_plist["PostSetupProfileWasInstalled"] = True
    files_to_restore.append(
        FileToRestore(
            contents=plistlib.dumps(cloud_config_plist),
            restore_path="Library/ConfigurationProfiles/CloudConfigurationDetails.plist",
            domain="SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles",
        )
    )

    purplebuddy_plist: dict = {
        "SetupDone": True,
        "SetupFinishedAllSteps": True,
        "UserChoseLanguage": True,
    }
    files_to_restore.append(
        FileToRestore(
            contents=plistlib.dumps(purplebuddy_plist),
            restore_path="mobile/com.apple.purplebuddy.plist",
            domain="ManagedPreferencesDomain",
        )
    )
    print(
        f"[skip-setup] added CloudConfigurationDetails.plist "
        f"(skip {len(cloud_config_plist.get('SkipSetup', []))} steps) "
        f"+ com.apple.purplebuddy.plist"
    )


# --------------------------------------------------------------------------- #
# Device connection
# --------------------------------------------------------------------------- #
async def _device_from_client(serial: str, client: Any) -> Device:
    values = await lockdown.all_values(client)
    return Device(
        udid=serial,
        usb=True,
        name=values.get("DeviceName", ""),
        version=values.get("ProductVersion", ""),
        build=values.get("BuildVersion", ""),
        model=values.get("ProductType", ""),
        hardware=values.get("HardwareModel", ""),
        cpu=values.get("HardwarePlatform", ""),
        locale=None,
        books_container_uuid="",
        ld=client,
    )


# --------------------------------------------------------------------------- #
# File list building (from the enabled tweak registry)
# --------------------------------------------------------------------------- #
def get_domain_for_path(
    dev: Device, path: str, owner: int = 501, use_bookrestore: bool = False
) -> tuple[str, str]:
    """Return (path, domain) for a file to restore.

    On sparserestore (partially supported) devices most files go through the
    SysContainer path-traversal exploit (empty domain). On BookRestore devices
    the payload files use the full absolute path with an empty domain so the
    Books download manager can write them; files that keep a backup domain
    (e.g. root-owned daemon plists) are restored the regular way.
    """
    if (
        (
            dev.partially_supported()
            and not path.startswith("/var/mobile/")
        )
        or (
            not dev.has_partial_sparserestore()
            and dev.has_bookrestore()
            and use_bookrestore
        )
    ) and not owner == 0:
        # don't do anything on sparserestore versions
        return path, ""
    fully_patched = not dev.has_partial_sparserestore()
    # just make the Sys Containers to use the regular way (won't work for mga)
    sysSharedContainer = "SysSharedContainerDomain-"
    sysContainer = "SysContainerDomain-"
    if not fully_patched:
        sysSharedContainer += "."
        sysContainer += "."
    mappings: dict = {
        "/var/Managed Preferences/": "ManagedPreferencesDomain",
        "/var/root/": "RootDomain",
        "/var/preferences/": "SystemPreferencesDomain",
        "/var/MobileDevice/": "MobileDeviceDomain",
        "/var/mobile/": "HomeDomain",
        "/var/db/": "DatabaseDomain",
        "/var/containers/Shared/SystemGroup/": sysSharedContainer,
        "/var/containers/Data/SystemGroup/": sysContainer,
    }
    for mapping in mappings.keys():
        if path.startswith(mapping):
            new_path = path.replace(mapping, "")
            new_domain = mappings[mapping]
            # if patched, include the next part of the path in the domain
            if fully_patched and (new_domain == sysSharedContainer or new_domain == sysContainer):
                parts = new_path.split("/")
                new_domain += parts[0]
                new_path = new_path.replace(parts[0] + "/", "")
            return new_path, new_domain
    return path, ""


def concat_file(
    dev: Device,
    contents: bytes,
    path: str,
    files_to_restore: list[FileToRestore],
    owner: int = 501,
    group: int = 501,
    use_bookrestore: bool = False,
) -> None:
    file_path, domain = get_domain_for_path(
        dev, path, owner=owner, use_bookrestore=use_bookrestore
    )
    files_to_restore.append(
        FileToRestore(
            contents=contents,
            restore_path=file_path,
            domain=domain,
            owner=owner,
            group=group,
        )
    )


def build_files_to_restore(dev: Device, use_bookrestore: bool = False) -> list[FileToRestore]:
    """Turn every enabled entry in the global tweak registry into restore files."""
    files_to_restore: list[FileToRestore] = []
    basic_plists: dict = {}
    basic_plists_ownership: dict = {}
    files_data: dict = {}

    for tweak in tweaks.values():
        if isinstance(tweak, BasicPlistTweak):  # BasicPlistTweak + AdvancedPlistTweak
            basic_plists = tweak.apply_tweak(basic_plists, risky_allowed=False)
            basic_plists_ownership[tweak.file_location] = tweak.owner
        elif isinstance(tweak, NullifyFileTweak):
            tweak.apply_tweak(files_data)

    for location, plist in basic_plists.items():
        ownership = basic_plists_ownership.get(location, 501)
        concat_file(
            dev,
            contents=plistlib.dumps(plist),
            path=location.value,
            files_to_restore=files_to_restore,
            owner=ownership,
            group=ownership,
            use_bookrestore=use_bookrestore,
        )
    for location, data in files_data.items():
        concat_file(
            dev,
            contents=data,
            path=location.value,
            files_to_restore=files_to_restore,
            use_bookrestore=use_bookrestore,
        )
    return files_to_restore


# --------------------------------------------------------------------------- #
# Public entry points
# --------------------------------------------------------------------------- #
def apply_tweaks(
    serial: str,
    *,
    respring_after: bool = False,
    reboot: bool = True,
    apply_method: str = "auto",
    transfer_mode: str = "localhost",
    skip_setup: bool = True,
    on_progress: ProgressFn | None = None,
) -> dict:
    """Apply the currently enabled tweaks to ``serial``'s device.

    ``apply_method``: ``"auto"`` (sparserestore where possible, otherwise
    BookRestore AFC - or Restore when root-owned files like Daemons are
    enabled), ``"afc"`` (force BookRestore AFC), ``"restore"`` (force
    BookRestore Restore). ``transfer_mode``: ``"localhost"`` (files served
    from this PC) or ``"ondevice"`` (device fetches upstream assets).

    ``skip_setup`` (default True) adds the skip-setup configuration so iOS
    skips the "Swipe up to upgrade" / Setup Assistant flow after the reboot
    instead of appearing to reset on-device settings.

    Returns ``{"ok": True, "warning": str|None, "mode": ...}``.

    Runs everything - lockdown client creation, the apply, and cleanup - in
    one event loop: pymobiledevice3's client keeps asyncio streams bound to
    the loop that created it, so handing a client created by one
    ``asyncio.run`` to another raises "Future attached to a different loop".
    """
    if os.name == "nt":
        # The proactor loop breaks blocking-socket operations performed while
        # a socket is attached to a stream transport (WebInspector TLS
        # handshake); the selector policy must be in effect before the loop
        # is created by asyncio.run below.
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    return run(_apply_tweaks_async(
        serial,
        respring_after=respring_after,
        reboot=reboot,
        apply_method=apply_method,
        transfer_mode=transfer_mode,
        skip_setup=skip_setup,
        on_progress=on_progress,
    ))


async def _apply_tweaks_async(
    serial: str,
    *,
    respring_after: bool = False,
    reboot: bool = True,
    apply_method: str = "auto",
    transfer_mode: str = "localhost",
    skip_setup: bool = True,
    on_progress: ProgressFn | None = None,
) -> dict:
    """Async core of :func:`apply_tweaks` (runs on one event loop)."""
    client = await lockdown.create(serial, prefer_usb=True)
    try:
        dev = await _device_from_client(serial, client)
        # Hard block on iOS 27: Apple changed the setup flow there and does
        # not honor the skip-setup files, so a BookRestore apply leaves the
        # device stuck on the white "Swipe up to upgrade" screen - and
        # swiping that screen can reset the device. This covers the
        # previously-excepted iOS 27 Beta 4 (24A5390f) as well.
        if Version(dev.version).major >= 27:
            raise NuggetError(
                "EmLoad blocks tweak applies on iOS 27.\n\n"
                "Apple changed the setup flow on iOS 27 and does not honor "
                "the skip-setup files EmLoad restores after a BookRestore "
                "apply, so the device can get stuck on the white \"Swipe up "
                "to upgrade\" screen after rebooting - and swiping that "
                "screen can reset the device.\n\n"
                f"Your device: iOS {dev.version} ({dev.build}).\n"
                "This block will be lifted once a verified safe apply path "
                "exists. Please do not try to force it."
            )
        if not dev.supported() and not dev.has_bookrestore():
            raise NuggetError(
                f"Your iOS version ({dev.version} ({dev.build})) is not supported. "
                f"Supported: iOS {MIN_VERSION} - {MAX_VERSION}."
            )
        if dev.has_partial_sparserestore():
            mode = "sparserestore"
        elif dev.has_bookrestore():
            mode = "bookrestore"
        else:
            raise NuggetError(
                "This device's iOS is fully patched: neither sparserestore nor "
                "BookRestore is available for it.\n\n"
                f"Device iOS: {dev.version} ({dev.build})."
            )

        files = build_files_to_restore(dev, use_bookrestore=(mode == "bookrestore"))
        if not files:
            raise NuggetError("No tweaks are enabled.")

        print(f"Restore file list ({len(files)} files):")
        for f in files:
            print(f"  domain={f.domain!r:>64}  {f.restore_path}")

        # Add the skip-setup configuration so the post-reboot flow does not
        # reset on-device settings. On partially-supported (exploit-only)
        # devices Nugget only adds it when the restore already uses real
        # domains, because adding a domain file changes the restore mode.
        restoring_domains = mode == "bookrestore" or any(
            f.domain not in ("", None) for f in files
        )
        if skip_setup and (not dev.partially_supported() or restoring_domains):
            await _add_skip_setup(client, files)
            restoring_domains = any(f.domain not in ("", None) for f in files)
        elif skip_setup:
            print(
                "[skip-setup] NOT added: partially-supported device with "
                "exploit-only files (adding domain files would change the "
                "restore mode)"
            )

        if mode == "sparserestore":
            return await _apply_sparserestore(
                client, files, respring_after=respring_after, reboot=reboot,
                on_progress=on_progress,
            )

        # BookRestore device
        domain_files = [f for f in files if f.domain not in ("", None)]
        if apply_method == "restore" or (apply_method == "auto" and domain_files):
            return await _apply_bookrestore_restore(
                serial, client, files,
                respring_after=respring_after, reboot=reboot,
                transfer_mode=transfer_mode, on_progress=on_progress,
            )
        if apply_method == "afc" and domain_files:
            raise NuggetError(
                "Some enabled tweaks (or Skip Setup) write root-owned / "
                "domain-based files that cannot be applied with the BookRestore "
                "AFC method. Choose the \"BookRestore Restore\" apply method "
                "instead (or disable Skip Setup to keep the AFC respring flow)."
            )
        return await _apply_bookrestore_afc(
            serial, client, files,
            reboot=reboot and not respring_after,
            transfer_mode=transfer_mode, on_progress=on_progress,
        )
    finally:
        close_dl_connection()
        try:
            await lockdown.close(client)
        except Exception:  # noqa: BLE001 - the device may already be rebooting
            pass


async def _apply_sparserestore(
    client: Any,
    files: list[FileToRestore],
    *,
    respring_after: bool,
    reboot: bool,
    on_progress: ProgressFn | None,
) -> dict:
    """Historical sparserestore apply (iOS < 18.2)."""
    _progress(on_progress, "apply", None, "Applying changes to files...")
    await restore_files(
        files=files,
        reboot=False,
        lockdown_client=client,
        progress_callback=lambda p: _progress(on_progress, "restore", p, None),
    )

    warning: str | None = None
    if respring_after:
        _progress(on_progress, "respring", None, "Respringing your device...")
        try:
            await trigger_respring_async(client)
            mode = "respring"
        except Exception as e:  # noqa: BLE001 - surface as a warning, not a failure
            warning = (
                f"Could not trigger a respring: {e}\n\n"
                "Please restart your device manually to see changes."
            )
            mode = "manual"
    elif reboot:
        _progress(on_progress, "apply", None, "Rebooting your device...")
        try:
            await reboot_device(reboot=True, lockdown_client=client)
        except Exception:  # noqa: BLE001 - restore may have already rebooted it
            pass
        mode = "reboot"
    else:
        mode = "manual"
    return {"ok": True, "warning": warning, "mode": mode}


async def _apply_bookrestore_afc(
    serial: str,
    client: Any,
    files: list[FileToRestore],
    *,
    reboot: bool,
    transfer_mode: str,
    on_progress: ProgressFn | None,
) -> dict:
    """BookRestore AFC method (tunnel + Books download manager)."""
    _progress(on_progress, "bookrestore", None, "Starting BookRestore (AFC)...")
    holder = BooksContainerUuid()

    def progress(msg: str) -> None:
        _progress(on_progress, "bookrestore", None, msg)

    transfer = (
        BookRestoreFileTransferMethod.LocalHost
        if transfer_mode == "localhost"
        else BookRestoreFileTransferMethod.OnDevice
    )
    await perform_bookrestore_async(
        files,
        client,
        udid=serial,
        books_uuid_callback=holder,
        progress_callback=progress,
        transfer_mode=transfer,
        do_full_reboot=reboot,
    )
    return {
        "ok": True,
        "warning": None,
        "mode": "bookrestore-reboot" if reboot else "bookrestore-respring",
    }


async def _apply_bookrestore_restore(
    serial: str,
    client: Any,
    files: list[FileToRestore],
    *,
    respring_after: bool,
    reboot: bool,
    transfer_mode: str,
    on_progress: ProgressFn | None,
) -> dict:
    """BookRestore Restore method (crafted Books DB restored via MobileBackup2).

    Empty-domain payload files are baked into a ``BLDatabaseManager.sqlite``
    that lives in the Books container; domain files (e.g. root-owned daemon
    plists) are restored normally in the same pass.
    """
    _progress(on_progress, "bookrestore", None, "Generating the BookRestore database...")

    payload = [f for f in files if f.domain in ("", None)]
    domain_files = [f for f in files if f.domain not in ("", None)]

    localhost = transfer_mode == "localhost"
    server_folder = create_server_folder()
    server_prefix = create_local_server() if localhost else None
    db_path = os.path.join(server_folder, "tmp.BLDatabaseManager.sqlite")

    async def _generate() -> int:
        from pymobiledevice3.services.afc import AfcService

        afc = AfcService(lockdown=client)
        return await generate_bldbmanager(
            payload, db_path, afc,
            server_prefix=server_prefix, server_folder=server_folder,
        )

    await _generate()

    # Keep only domain files; the payload is now inside the Books DB
    restore_list = list(domain_files)
    db_restore_path = "Documents/BLDatabaseManager/BLDatabaseManager.sqlite"
    db_restore_domain = "SysSharedContainerDomain-systemgroup.com.apple.media.shared.books"
    for suffix in ("", "-shm", "-wal"):
        restore_list.append(
            FileToRestore(
                contents=None,
                restore_path=f"{db_restore_path}{suffix}",
                contents_path=f"{db_path}{suffix}",
                domain=db_restore_domain,
            )
        )

    _progress(on_progress, "restore", None, "Restoring to the device...")
    print(f"BookRestore Restore file list ({len(restore_list)} files):")
    for f in restore_list:
        print(f"  domain={f.domain!r:>64}  {f.restore_path}")
    await restore_files(
        files=restore_list,
        reboot=False,
        lockdown_client=client,
        progress_callback=lambda p: _progress(on_progress, "restore", p, None),
    )
    # close the crafted DB connection before removing the temp folder
    # (the -shm/-wal files must survive until the restore has read them)
    close_dl_connection()
    cleanup_server_folder()

    # give the device a moment to process the restored database
    await asyncio.sleep(2)

    warning: str | None = None
    if respring_after:
        _progress(on_progress, "respring", None, "Respringing your device...")
        try:
            await trigger_respring_async(client)
            mode = "bookrestore-respring"
        except Exception as e:  # noqa: BLE001 - surface as a warning, not a failure
            warning = (
                f"Could not trigger a respring: {e}\n\n"
                "Please restart your device manually to see changes."
            )
            mode = "manual"
    elif reboot:
        _progress(on_progress, "bookrestore", None, "Rebooting your device...")
        try:
            await reboot_device(reboot=True, lockdown_client=client)
        except Exception:  # noqa: BLE001 - restore may have already rebooted it
            pass
        mode = "bookrestore-reboot"
    else:
        mode = "manual"
    return {"ok": True, "warning": warning, "mode": mode}


def respring_device(serial: str, *, on_progress: ProgressFn | None = None) -> dict:
    """Respring ``serial``'s device (best-effort; raises NuggetError otherwise).

    The lockdown client and the respring run inside one event loop: a client
    created by its own ``asyncio.run`` cannot be handed to another
    ``asyncio.run`` (each finishes by closing its loop, so reusing its
    asyncio streams raises "Future attached to a different loop").
    """

    async def _run() -> dict:
        client = await lockdown.create(serial, prefer_usb=True)
        try:
            _progress(on_progress, "respring", None, "Starting respring...")
            await trigger_respring_async(client)
            return {"ok": True}
        finally:
            try:
                await lockdown.close(client)
            except Exception:  # noqa: BLE001 - the device may already be respringing
                pass

    if os.name == "nt":
        # The proactor loop breaks blocking-socket operations performed while
        # the socket is attached to a stream transport (WebInspector TLS
        # handshake); the selector policy must be in effect before the loop
        # is created by asyncio.run below.
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    return run(_run())