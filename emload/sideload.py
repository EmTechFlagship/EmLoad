"""End-to-end sideload orchestration.

A single reusable ``run_sideload`` that provisions, signs, installs, and records
an IPA - used both by the ``sideload`` command and by ``refresh`` (which replays
a recorded install with its original options). Progress is reported through a
callback so callers can stream ``provision -> sign -> install`` phases to a UI.

Also owns the lifetime of what signing produces: the ``<source>_Signed.ipa`` that
can optionally be kept, the throwaway scratch directory beside it, and the
reporting/cleanup of a folder full of kept IPAs.
"""

from __future__ import annotations

import datetime
import ctypes
import os
import shutil
import stat
import tempfile
from pathlib import Path
from typing import Any, Callable

from . import apps, developer, device, gsa, ipa as ipa_module, paths, provision, registry, signing
from .errors import EmLoadError

# (phase, percent, step-text) - any of percent/step may be None.
ProgressFn = Callable[[str, Any, "str | None"], None]

# The signed IPA is named after the IPA it came from, so re-signing the same app
# overwrites its own output instead of piling up numbered copies.
SIGNED_SUFFIX = "_Signed.ipa"

# Sign-time scratch: one throwaway directory per run, created inside the same
# folder as the signed output so the heavy I/O follows the user's chosen disk.
SCRATCH_PREFIX = "eml_"

# Windows caps paths at MAX_PATH for the ANSI file APIs zsign uses, and every
# character spent here is one an app bundle cannot use. zsign also writes
# temporary `<binary>.archo.N` files beside every Mach-O it re-signs, so the
# scratch directory's own path length decides whether an app can be signed at all.
_MAX_PATH = 259
_ZSIGN_HEADROOM = 34

# When installd refuses an app because its signature/profile failed verification,
# the cure is a fresh provisioning profile (a new UUID), not more of the same
# bytes. Bound the automatic re-issue so a device stuck in a bad state cannot
# burn Apple's profile downloads forever: 1 initial attempt + 2 regenerations.
MAX_PROFILE_REGENERATIONS = 2

# Errors that indicate the provisioning profile is stale/broken and a fresh one
# should be generated.  Broadened beyond the original verification-only check to
# also catch "could not provision", profile install failures, and similar issues
# where the profile itself is the problem rather than the device or IPA.
_PROVISIONING_ERROR_HINTS = (
    "could not provision",
    "could not be verified",
    "couldn't be verified",
    "failed to verify",
    "verification failed",
    "does not verify",
    "integrity",
    "applicationverificationfailed",
    "profile",
    "provision",
    "signing",
    "certificate",
)


def is_provisioning_error(exc: Exception) -> bool:
    """True when ``exc`` is a provisioning or profile problem that a fresh profile may fix.

    Broader than ``apps.is_verification_failure``: catches "could not provision",
    profile install failures, stale certificate issues, and similar errors where
    the signing assets (profile, certificate) are the likely culprit.
    """
    text = str(exc).lower()
    return any(hint in text for hint in _PROVISIONING_ERROR_HINTS)


class SideloadError(EmLoadError):
    """A sideload could not be completed (device, IPA, or option problem)."""


# installd's raw Status codes -> friendly, present-tense sub-steps shown in the UI.
_INSTALL_STEPS = {
    "CreatingStagingDirectory": "Staging on device\u2026",
    "ExtractingPackage": "Extracting package\u2026",
    "InspectingPackage": "Inspecting package\u2026",
    "PreflightingApplication": "Preflighting\u2026",
    "InstallingApplication": "Installing\u2026",
    "VerifyingApplication": "Verifying\u2026",
    "CreatingContainer": "Creating container\u2026",
    "InstallingEmbeddedProfile": "Installing profile\u2026",
    "SandboxingApplication": "Sandboxing\u2026",
    "PostflightingApplication": "Postflighting\u2026",
    "GeneratingApplicationMap": "Finalizing\u2026",
}

_INSTALL_DONE = {"Complete", "InstallComplete"}


def _humanize_install(status: str | None) -> str:
    if not status:
        return "Installing\u2026"
    if status in _INSTALL_DONE:
        return "Installed"
    return _INSTALL_STEPS.get(status, status)


def _install_relay(update: dict[str, Any], target_name: str = "iPhone") -> tuple[int, str]:
    """Map an ``apps.install`` progress update to ``(overall_percent, step_label)``.

    One monotonic 0-100 bar for the whole install: the upload (the long haul)
    drives 0-80%, installd's on-device phases drive 80-100%.
    """
    if update.get("phase") == "upload":
        overall = round((update.get("percent") or 0) * 0.8)
        total, sent = update.get("total") or 0, update.get("sent") or 0
        step = (
            f"Uploading to {target_name} \u00b7 {sent // (1 << 20)} / {total // (1 << 20)} MB"
            if total else f"Uploading to {target_name}\u2026"
        )
        return overall, step
    status = update.get("status")
    if status in _INSTALL_DONE:  # completion may arrive without a percent - pin to 100%
        return 100, "Installed"
    return 80 + round((update.get("percent") or 0) * 0.2), _humanize_install(status)


def resolve_udid(udid: str | None) -> str:
    """The device to sideload to, as a ``SideloadError`` if it cannot be settled."""
    try:
        return device.resolve_serial(udid)
    except device.DeviceError as exc:
        raise SideloadError(str(exc)) from exc


def _as_signed_dir(directory: str | None) -> Path:
    """The folder signed IPAs live in: the caller's choice, or the app's own."""
    if not directory or not directory.strip():
        return paths.signed_dir()
    return Path(directory).expanduser().resolve()


def _scratch_roots(target: Path, deepest: int) -> list[Path]:
    """Candidate scratch locations, shortest usable Windows location first.

    zsign uses legacy path handling, so the user's Temp folder can itself be too
    deep. ``C:\\eml`` leaves enough room for almost every IPA and is created only
    when needed. Windows Temp and the regular Temp folder remain fallbacks for
    machines where creating a directory at the drive root is not permitted.
    """
    budget = _MAX_PATH - _ZSIGN_HEADROOM - deepest - len(SCRATCH_PREFIX) - 8
    candidates = [target] if deepest <= 0 or len(str(target)) <= budget else []
    if os.name == "nt":
        drive_root = Path(tempfile.gettempdir()).anchor
        if drive_root:
            candidates.extend((Path(drive_root) / "eml", Path(os.environ.get("SystemRoot", r"C:\\Windows")) / "Temp"))
        # A normal user cannot always create C:\\eml, while their Temp folder
        # is writable but often too long for deeply nested app bundles. Use
        # its 8.3 alias when Windows has one.
        short_temp = _short_windows_path(Path(tempfile.gettempdir()))
        if short_temp is not None:
            candidates.append(short_temp)
    elif target not in candidates:
        # MAX_PATH is specific to zsign's Windows file handling. On macOS and
        # other platforms, keep scratch beside the chosen output directory.
        candidates.insert(0, target)
    candidates.append(Path(tempfile.gettempdir()))

    unique: list[Path] = []
    for candidate in candidates:
        if candidate not in unique:
            unique.append(candidate)
    return unique


def _short_windows_path(path: Path) -> Path | None:
    """Return a Windows 8.3 alias for an existing path when available."""
    if os.name != "nt":
        return None
    try:
        get_short_path = ctypes.windll.kernel32.GetShortPathNameW
        get_short_path.argtypes = (ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint)
        get_short_path.restype = ctypes.c_uint
        source = str(path)
        required = get_short_path(source, None, 0)
        if not required:
            return None
        buffer = ctypes.create_unicode_buffer(required)
        written = get_short_path(source, buffer, required)
        if not written or written >= required:
            return None
        alias = Path(buffer.value)
        return alias if len(str(alias)) < len(source) else None
    except (AttributeError, OSError, TypeError, ValueError):
        return None


def _open_signed_dir(directory: str | None, deepest: int = 0) -> tuple[Path, Path]:
    """Return ``(signed folder, this run's scratch folder)``, creating both."""
    try:
        target = _as_signed_dir(directory)
        target.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise SideloadError(
            f"Cannot use '{directory or exc.filename}' as the folder for signed IPAs: "
            f"{exc.strerror or exc}"
        ) from exc

    failures: list[str] = []
    for root in _scratch_roots(target, deepest):
        try:
            root.mkdir(parents=True, exist_ok=True)
            scratch = Path(tempfile.mkdtemp(prefix=SCRATCH_PREFIX, dir=root))
        except OSError as exc:
            failures.append(f"{root}: {exc.strerror or exc}")
            continue
        if os.name != "nt" or not deepest or len(str(scratch)) + _ZSIGN_HEADROOM + deepest <= _MAX_PATH:
            return target, scratch
        shutil.rmtree(scratch, ignore_errors=True)

    tried = "; ".join(failures) or "all available working folders were too long"
    raise SideloadError(
        f"This app's files are nested too deeply to sign on this machine: the longest path "
        f"inside it is {deepest} characters. EmLoad could not create a short enough working "
        f"folder within the {_MAX_PATH}-character Windows path limit ({tried})."
    )


def run_sideload(
    ipa_path: str,
    udid: str | None = None,
    *,
    bundle_id: str | None = None,
    display_name: str | None = None,
    bundle_version: str | None = None,
    remove_extensions: bool = True,
    remove_uisd: bool = True,
    enable_file_sharing: bool = False,
    keep_signed: bool = False,
    signed_dir: str | None = None,
    record: bool = True,
    allow_other_platform: bool = False,
    on_progress: ProgressFn | None = None,
) -> dict[str, Any]:
    """Provision + sign + install an IPA, then record it for refresh.

    ``keep_signed`` leaves the signed ``<source>_Signed.ipa`` on disk and reports
    it as ``signed_ipa``; otherwise it is deleted once the install is over.
    ``signed_dir`` overrides where that file - and the sign-time scratch - is written.
    """
    progress: ProgressFn = on_progress or (lambda *_args: None)
    udid = resolve_udid(udid)

    info = ipa_module.inspect(ipa_path)
    if info.get("encrypted") is True:
        raise signing.SigningError(
            "This IPA is App Store-encrypted (FairPlay) and cannot be sideloaded; "
            "use a decrypted IPA."
        )

    device_class, target_name = _describe_target(udid)
    if not allow_other_platform:
        _check_platform_matches_device(ipa_path, info, device_class)

    app_name = display_name or info.get("display_name") or info.get("bundle_id")

    progress("provision", None, "Contacting Apple\u2026")
    # A free account can't register a real App Store id, so default to a
    # team-scoped id; honor an explicit override when given.
    target_bundle_id = bundle_id or provision.team_scoped_bundle_id(info.get("bundle_id"))

    bundle = provision.ensure_signing_assets(
        target_bundle_id, udid,
        app_name=app_name,
        on_step=lambda message: progress("provision", None, message),
    )

    progress("sign", None, "Signing the app\u2026")
    target_dir, scratch = _open_signed_dir(signed_dir, ipa_module.deepest_entry(ipa_path))
    output = str(target_dir / f"{Path(ipa_path).stem}{SIGNED_SUFFIX}")
    profile_regenerations = 0
    try:
        # Installd can reject the signed app because its provisioning profile did
        # not verify on the device (stale/corrupt profile). When that happens,
        # retire the old profile and re-issue + re-sign + reinstall with a fresh
        # one, automatically, up to MAX_PROFILE_REGENERATIONS times.
        for attempt in range(MAX_PROFILE_REGENERATIONS + 1):
            try:
                signing.sign_ipa(
                    ipa_path, output,
                    p12_path=bundle["p12_path"],
                    p12_password=bundle["p12_password"],
                    profile_path=bundle["profile_path"],
                    bundle_id=target_bundle_id,
                    display_name=display_name,
                    bundle_version=bundle_version,
                    remove_extensions=remove_extensions,
                    remove_uisd=remove_uisd,
                    enable_file_sharing=enable_file_sharing,
                    temp_folder=str(scratch),
                )

                progress("install", 0, f"Uploading to {target_name}\u2026")
                apps.install(
                    output,
                    udid,
                    progress=lambda u: progress("install", *_install_relay(u, target_name)),
                )
                break
            except Exception as exc:
                if attempt >= MAX_PROFILE_REGENERATIONS or not (
                    apps.is_verification_failure(exc) or is_provisioning_error(exc)
                ):
                    raise
                profile_regenerations += 1
                progress(
                    "install", None,
                    "Provisioning issue detected \u2014 issuing a fresh "
                    f"provisioning profile ({profile_regenerations}/{MAX_PROFILE_REGENERATIONS})\u2026",
                )
                bundle = provision.regenerate_profile(
                    target_bundle_id,
                    udid,
                    app_name=app_name,
                    on_step=lambda message: progress("provision", None, message),
                )
    finally:
        # Scratch always goes, kept signed IPA or not: it is an unpacked copy of the
        # whole app, worth hundreds of MB, and nothing reads it after signing.
        shutil.rmtree(scratch, ignore_errors=True)
        # Unless the user asked to keep it, so does the signed IPA - install reads it
        # once, refresh re-signs from the recorded *source* IPA, and a retry re-signs
        # anyway, so it is never read again.
        if not keep_signed:
            Path(output).unlink(missing_ok=True)

    expires_at: str | None = None
    try:
        expiry = registry.profile_expiration(Path(bundle["profile_path"]).read_bytes())
        expires_at = expiry.isoformat() if expiry else None
    except OSError:
        pass

    result = {
        "status": "installed",
        "bundle_id": target_bundle_id,
        "name": app_name,
        "icon": info.get("icon"),
        "udid": udid,
        "team_id": bundle.get("team_id"),
        "source_ipa": str(Path(ipa_path).resolve()),
        "signed_ipa": output if keep_signed else None,
        "installed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "expires_at": expires_at,
    }
    if profile_regenerations:
        result["profile_regenerations"] = profile_regenerations
    if record:
        registry.record({
            **{key: value for key, value in result.items()
               if key not in ("signed_ipa", "profile_regenerations")},
            "options": {
                "bundle_id": bundle_id,
                "display_name": display_name,
                "bundle_version": bundle_version,
                "remove_extensions": remove_extensions,
                "remove_uisd": remove_uisd,
                "enable_file_sharing": enable_file_sharing,
            },
        })
    return result


# What lockdown's DeviceClass means in terms of the platform an app is built for.
_DEVICE_CLASS_PLATFORM = {
    "iphone": "ios",
    "ipad": "ios",
    "ipod": "ios",
    "appletv": "tvos",
    "realitydevice": "visionos",
    "watch": "watchos",
}

_DEVICE_LABELS = {
    "ios": "an iPhone or iPad",
    "tvos": "an Apple TV",
    "watchos": "an Apple Watch",
    "visionos": "an Apple Vision Pro",
}


def _describe_target(udid: str) -> tuple[str, str]:
    """``(device_class, name)`` for the target, both lowercased/blank if unreachable."""
    try:
        values = device.get_device_info(udid)
    except Exception:  # noqa: BLE001
        return "", "iPhone"
    device_class = str(values.get("DeviceClass") or "").strip().lower()
    name = str(values.get("DeviceName") or "").strip()
    if not name:
        name = _DEVICE_LABELS.get(_DEVICE_CLASS_PLATFORM.get(device_class, ""), "iPhone")
    return device_class, name


def _check_platform_matches_device(
    ipa_path: str, info: dict[str, Any], device_class: str
) -> None:
    """Refuse an app built for a different kind of device than the one selected.

    Only a genuine mismatch is refused; anything we cannot read confidently is
    allowed through, because "the Info.plist did not say" is not evidence of the
    wrong platform.
    """
    app_platform = info.get("platform")
    if not app_platform:
        return

    device_platform = _DEVICE_CLASS_PLATFORM.get(device_class)
    if not device_platform or device_platform == app_platform:
        return

    app_label = ipa_module.PLATFORM_LABELS.get(app_platform, f"{app_platform} devices")
    target = _DEVICE_LABELS.get(device_platform, device_class or "this device")
    raise SideloadError(
        f"{Path(ipa_path).name} is built for {app_label}, and the selected device is "
        f"{target}. It would install and then refuse to launch. Use a build made for "
        f"{target}, or pass --allow-other-platform to try it anyway."
    )


def _refresh_account(entry: dict[str, Any]) -> str | None:
    """The Apple ID to re-sign this record under, or None to use the active one.

    A refresh has to run as the account that signed the app. Under a different one
    it is re-signed by a different team, and iOS will not install that over the
    copy already on the phone.
    """
    team_id = entry.get("team_id")
    if not team_id:
        return None

    account = gsa.account_for_team(team_id)
    if account:
        return account

    # No signed-in account is *known* to provision for that team, but the active one
    # may simply never have been mapped - it is only learned by provisioning. Ask
    # once before giving up, and remember the answer either way.
    session = gsa.load_session()
    email = session.get("email")
    try:
        active_team = developer.list_teams()[0]["teamId"]
    except Exception:  # noqa: BLE001 - offline or Apple unreachable
        return None  # Let the refresh itself fail with the real reason.

    if email:
        gsa.remember_team(email, active_team)
    if active_team == team_id:
        return None

    name = entry.get("name") or entry.get("bundle_id") or "This app"
    raise SideloadError(
        f"{name} was signed by a different Apple ID (team {team_id}), and that "
        f"account is not signed in - {email or 'the current account'} is on team "
        f"{active_team}. Sign in as the Apple ID that installed it to refresh it, "
        f"or sideload it again with this one."
    )


def refresh_record(
    entry: dict[str, Any],
    on_progress: ProgressFn | None = None,
    *,
    keep_signed: bool = False,
    signed_dir: str | None = None,
) -> dict[str, Any]:
    """Re-sign + reinstall a previously recorded sideload using its saved options."""
    source = entry.get("source_ipa")
    if not source:
        raise SideloadError(
            f"{entry.get('name') or 'This app'} has no recorded source IPA, so it "
            "cannot be refreshed. Sideload it again to start tracking it."
        )
    if not Path(source).exists():
        raise ipa_module.missing_ipa_error(source)
    options = entry.get("options") or {}

    account = _refresh_account(entry)
    with gsa.acting_as(account):
        return run_sideload(
            source,
            entry.get("udid"),
            bundle_id=entry.get("bundle_id"),
            display_name=options.get("display_name"),
            bundle_version=options.get("bundle_version"),
            remove_extensions=options.get("remove_extensions", True),
            remove_uisd=options.get("remove_uisd", True),
            enable_file_sharing=bool(options.get("enable_file_sharing")),
            keep_signed=keep_signed,
            signed_dir=signed_dir,
            on_progress=on_progress,
        )


def _kept_signed_ipas(directory: Path) -> list[tuple[Path, object]]:
    """The signed IPAs in ``directory``, newest first, as ``(path, lstat)`` pairs.

    Only matches files we know we wrote: regular files (never symlinks/junctions)
    whose name ends with ``_Signed.ipa``, directly inside the folder - never a
    recursive walk, so a user's own IPAs in subfolders are out of scope.
    """
    try:
        entries = list(directory.iterdir())
    except OSError:
        return []

    suffix = SIGNED_SUFFIX.lower()
    found: list[tuple[Path, object]] = []
    for entry in entries:
        if not entry.name.lower().endswith(suffix):
            continue
        try:
            info = entry.lstat()
        except OSError:
            continue
        if stat.S_ISREG(info.st_mode):
            found.append((entry, info))
    found.sort(key=lambda item: item[1].st_mtime, reverse=True)
    return found


def signed_status(directory: str | None = None) -> dict[str, Any]:
    """Report the signed IPAs kept in ``directory`` (default: the app's own folder)."""
    target = _as_signed_dir(directory)
    found = _kept_signed_ipas(target)
    return {
        "directory": str(target),
        "count": len(found),
        "bytes": sum(info.st_size for _path, info in found),
        "files": [
            {
                "name": path.name,
                "bytes": info.st_size,
                "modified": datetime.datetime.fromtimestamp(
                    info.st_mtime, datetime.timezone.utc
                ).isoformat(),
            }
            for path, info in found
        ],
    }


def clean_signed(directory: str | None = None) -> dict[str, Any]:
    """Delete the signed IPAs in ``directory``, and only those (see ``_kept_signed_ipas``)."""
    target = _as_signed_dir(directory)
    removed, freed = 0, 0
    for path, info in _kept_signed_ipas(target):
        try:
            path.unlink()
        except OSError:
            continue
        removed += 1
        freed += info.st_size
    return {"directory": str(target), "removed": removed, "bytes_freed": freed}
