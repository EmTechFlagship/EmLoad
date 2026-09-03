"""EmLoad command-line interface.

``emload`` mirrors what the GUI can do, so the same engine serves both:

    emload doctor                check the environment for sideloading readiness
    emload devices               list connected iOS devices
    emload device-info           show details for one device
    emload login                 sign in with an Apple ID (--email/--password/--code)
    emload logout                sign out
    emload account               show the signed-in account
    emload teams                 list Apple developer teams
    emload provision <bundle_id> provision, then install the team's profile
                                 on the connected device (needs sign-in)
    emload inspect <ipa>         read an IPA's identity without extracting it
    emload sideload <ipa>        provision + sign + install in one step
    emload refresh [--all]       re-sign + reinstall recorded apps before expiry
    emload installs              list recorded sideloads with days left
    emload forget <bundle_id>    stop tracking a sideload
    emload apps                  list apps installed on the device
    emload uninstall <bundle_id> remove an app from the device
    emload profiles              list provisioning profiles on the device
    emload unprovision <uuid>    remove a provisioning profile from the device
    emload signed [--clean]      report / delete kept signed IPAs
    emload setup                 download zsign (needed for signing)
    emload gui                   launch the desktop app

Every command accepts ``--json`` for machine-readable output, and device
commands accept ``--udid`` and ``--connection usb|wifi|auto``.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Callable

from . import __version__, anisette, apps, device, doctor, gsa, ipa, paths, provision, registry, sideload, signing
from .errors import EmLoadError


def _force_utf8() -> None:
    """Make stdout/stderr UTF-8 on Windows (EmLoad prints app names, arrows, ...).

    Safe under ``pythonw`` where the streams are ``None``.
    """
    for stream in (sys.stdout, sys.stderr):
        encoding = getattr(stream, "encoding", None)
        if encoding and encoding.lower() not in ("utf-8", "utf8"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except (AttributeError, ValueError):
                pass


def _emit(args: argparse.Namespace, payload: Any) -> None:
    if getattr(args, "json", False):
        print(json.dumps(payload, ensure_ascii=False, default=str))
    elif isinstance(payload, dict):
        for key, value in payload.items():
            if isinstance(value, (dict, list)):
                print(f"{key}: {json.dumps(value, ensure_ascii=False, default=str)}")
            else:
                print(f"{key}: {value}")
    else:
        print(payload)


def _progress(args: argparse.Namespace) -> Callable[[str, Any, str | None], None]:
    def on_progress(phase: str, percent: Any, step: str | None) -> None:
        if getattr(args, "json", False):
            sys.stderr.write(
                json.dumps({"phase": phase, "percent": percent, "step": step})
                + "\n"
            )
            sys.stderr.flush()
        elif step:
            print(f"  [{phase}] {step}", file=sys.stderr)
    return on_progress


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #
def cmd_doctor(args: argparse.Namespace) -> int:
    _emit(args, doctor.check())
    return 0


def cmd_devices(args: argparse.Namespace) -> int:
    rows = device.list_devices()
    out = []
    for row in rows:
        info = {}
        try:
            info = device.get_device_info(row["serial"], prefer_usb=False)
        except Exception:  # noqa: BLE001 - paired/trusted devices may not answer
            pass
        out.append(
            {
                "udid": row.get("serial"),
                "connection": row.get("connection_type"),
                "name": info.get("DeviceName"),
                "model": info.get("ProductType"),
                "os_version": info.get("ProductVersion"),
            }
        )
    _emit(args, out)
    return 0


def cmd_device_info(args: argparse.Namespace) -> int:
    _emit(args, device.get_device_info(args.udid))
    return 0


def cmd_version(args: argparse.Namespace) -> int:
    _emit(args, {"version": __version__})
    return 0


def cmd_login(args: argparse.Namespace) -> int:
    # Sub-actions on already-signed-in state.
    if args.status:
        _emit(args, gsa.status())
        return 0
    if args.use:
        _emit(args, gsa.use_account(args.use))
        return 0
    if args.logout:
        _emit(args, gsa.logout(args.logout if args.logout != "all" else None))
        return 0

    if not args.email:
        print("error: login needs --email (or use --status/--use/--logout)", file=sys.stderr)
        return 2

    password = args.password
    if not password:
        try:
            password = getpass()
        except KeyboardInterrupt:
            return 130
    if not password:
        print("error: a password is required", file=sys.stderr)
        return 2

    if args.code:
        _emit(args, gsa.complete_2fa(args.email, password, args.code))
        return 0

    result = gsa.begin_login(args.email, password)
    if result["status"] == "2fa_required":
        if getattr(args, "json", False):
            _emit(args, result)
        else:
            method = "trusted device" if result["method"] == "trusteddevice" else "SMS"
            print(
                f"A verification code was sent to your {method}. Run:\n"
                f"  emload login --email {args.email} --password <password> --code <code>"
            )
        return 0
    _emit(args, result)
    return 0


def cmd_account(args: argparse.Namespace) -> int:
    _emit(args, gsa.status())
    return 0


def cmd_logout(args: argparse.Namespace) -> int:
    _emit(args, gsa.logout(args.email))
    return 0


def cmd_teams(args: argparse.Namespace) -> int:
    _emit(args, developer_list_teams())
    return 0


def cmd_provision(args: argparse.Namespace) -> int:
    app_name = args.name or args.bundle_id.rpartition(".")[2] or "EmLoad App"
    result = provision.provision_device(
        args.bundle_id,
        args.udid,
        app_name=app_name,
        on_step=lambda message: _progress(args)("provision", None, message),
    )
    _emit(args, result)
    return 0


def developer_list_teams() -> list[dict[str, Any]]:
    from . import developer
    return developer.list_teams()


def cmd_inspect(args: argparse.Namespace) -> int:
    _emit(args, ipa.inspect(args.ipa))
    return 0


def cmd_sideload(args: argparse.Namespace) -> int:
    result = sideload.run_sideload(
        args.ipa,
        args.udid,
        bundle_id=args.bundle_id,
        display_name=args.display_name,
        bundle_version=args.bundle_version,
        remove_extensions=not args.keep_extensions,
        remove_uisd=not args.keep_uisd,
        enable_file_sharing=args.file_sharing,
        keep_signed=args.keep_signed,
        signed_dir=args.signed_dir,
        allow_other_platform=args.allow_other_platform,
        on_progress=_progress(args),
    )
    _emit(args, result)
    return 0


def cmd_refresh(args: argparse.Namespace) -> int:
    targets = (
        [registry.get(bundle_id) for bundle_id in args.bundle_id]
        if args.bundle_id
        else (registry.records() if args.all else registry.due(args.within_days))
    )
    targets = [t for t in targets if t]
    if not targets:
        _emit(args, {"status": "nothing_to_refresh"})
        return 0

    results = []
    failed = 0
    for entry in targets:
        try:
            result = sideload.refresh_record(
                entry,
                on_progress=_progress(args),
                keep_signed=args.keep_signed,
                signed_dir=args.signed_dir,
            )
            results.append({"bundle_id": entry["bundle_id"], "status": "ok", **result})
        except EmLoadError as exc:
            failed += 1
            results.append({"bundle_id": entry["bundle_id"], "status": "error", "error": str(exc)})
    _emit(args, {"results": results, "failed": failed})
    return 1 if failed else 0


def cmd_installs(args: argparse.Namespace) -> int:
    _emit(args, registry.records())
    return 0


def cmd_forget(args: argparse.Namespace) -> int:
    removed = registry.forget(args.bundle_id)
    _emit(args, {"bundle_id": args.bundle_id, "forgotten": removed})
    return 0 if removed else 1


def cmd_apps(args: argparse.Namespace) -> int:
    installed = apps.list_installed(args.udid, args.type)
    rows = [
        {"bundle_id": bundle_id, "name": meta.get("name"), "version": meta.get("version")}
        for bundle_id, meta in sorted(installed.items())
    ]
    _emit(args, rows)
    return 0


def cmd_uninstall(args: argparse.Namespace) -> int:
    apps.uninstall(args.bundle_id, args.udid)
    _emit(args, {"bundle_id": args.bundle_id, "uninstalled": True})
    return 0


def cmd_profiles(args: argparse.Namespace) -> int:
    _emit(args, provision.list_profiles(args.udid))
    return 0


def cmd_unprovision(args: argparse.Namespace) -> int:
    if args.all:
        result = provision.clear_profiles(args.udid)
    else:
        result = provision.remove_profile(args.uuid, args.udid)
    _emit(args, result)
    return 0


def cmd_signed(args: argparse.Namespace) -> int:
    if args.clean:
        _emit(args, sideload.clean_signed(args.directory))
    else:
        _emit(args, sideload.signed_status(args.directory))
    return 0


def cmd_setup(args: argparse.Namespace) -> int:
    if args.force is False and (checked := signing.signing_status())["available"]:
        _emit(args, {"status": "already_installed", **checked})
        return 0
    _emit(args, signing.download_zsign())
    return 0


def cmd_gui(args: argparse.Namespace) -> int:
    from .gui.app import run_gui

    run_gui()
    return 0


# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="machine-readable JSON output")
    common.add_argument("--data-dir", default=None, help="override the data directory")

    transport = argparse.ArgumentParser(add_help=False)
    transport.add_argument(
        "--connection", choices=["auto", "usb", "wifi"], default=None,
        help="how to reach the device (default: prefer USB, fall back to Wi-Fi)",
    )

    target = argparse.ArgumentParser(add_help=False, parents=[transport])
    target.add_argument("--udid", default=None, help="target device UDID")

    signed_output = argparse.ArgumentParser(add_help=False)
    signed_output.add_argument("--keep-signed", action="store_true",
                               help="keep the signed .ipa on disk")
    signed_output.add_argument("--signed-dir", default=None,
                               help="folder for signed .ipa files and scratch")

    parser = argparse.ArgumentParser(
        prog="emload",
        description="Sideload iOS apps with a free Apple ID (AltServer-style).",
        parents=[common],
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("doctor", parents=[common], help="check the environment")
    sub.add_parser("devices", parents=[common], help="list connected iOS devices")
    sub.add_parser("device-info", parents=[common, target], help="show details for one device")
    sub.add_parser("version", parents=[common], help="print the version")

    login_parser = sub.add_parser("login", parents=[common], help="sign in with an Apple ID")
    login_parser.add_argument("--email", default=None, help="Apple ID email")
    login_parser.add_argument("--password", default=None, help="Apple ID password (omit to prompt)")
    login_parser.add_argument("--code", default=None, help="2FA code (complete a pending login)")
    login_parser.add_argument("--status", action="store_true", help="show sign-in status")
    login_parser.add_argument("--use", default=None, metavar="EMAIL", help="make this account active")
    login_parser.add_argument("--logout", nargs="?", const="all", metavar="EMAIL",
                              help="sign out one account, or all")

    sub.add_parser("account", parents=[common], help="show the signed-in account")
    logout_parser = sub.add_parser("logout", parents=[common], help="sign out")
    logout_parser.add_argument("--email", default=None, help="account to sign out (default: all)")

    sub.add_parser("teams", parents=[common], help="list Apple developer teams")

    provision_parser = sub.add_parser(
        "provision", parents=[common, target],
        help="provision, then install the team's profile on the connected device",
    )
    provision_parser.add_argument("bundle_id", help="bundle identifier to provision")
    provision_parser.add_argument("--name", default=None,
                                  help="App ID name to register (default: derived from the bundle id)")

    inspect_parser = sub.add_parser("inspect", parents=[common], help="read an IPA's identity")
    inspect_parser.add_argument("ipa", help="path to an .ipa file")

    sideload_parser = sub.add_parser(
        "sideload", parents=[common, target, signed_output],
        help="provision + sign + install an IPA",
    )
    sideload_parser.add_argument("ipa", help="path to an .ipa file")
    sideload_parser.add_argument("-b", "--bundle-id", default=None, help="override bundle id")
    sideload_parser.add_argument("-n", "--display-name", default=None, help="override display name")
    sideload_parser.add_argument("-r", "--bundle-version", default=None, help="override version")
    sideload_parser.add_argument("--keep-extensions", action="store_true",
                                 help="keep app extensions (uses extra App ID slots)")
    sideload_parser.add_argument("--keep-uisd", action="store_true",
                                 help="keep UISupportedDevices device restrictions")
    sideload_parser.add_argument("--file-sharing", action="store_true",
                                 help="enable Files-app sharing (UIFileSharingEnabled)")
    sideload_parser.add_argument("--allow-other-platform", action="store_true",
                                 help="allow installing to a mismatched platform")

    refresh_parser = sub.add_parser(
        "refresh", parents=[common, signed_output],
        help="re-sign + reinstall recorded apps before their profiles expire",
    )
    refresh_parser.add_argument("bundle_id", nargs="*", help="apps to refresh (default: due)")
    refresh_parser.add_argument("--all", action="store_true", help="refresh every recorded app")
    refresh_parser.add_argument("--within-days", type=float, default=2.0,
                                help="refresh apps expiring within N days (default 2)")

    sub.add_parser("installs", parents=[common], help="list recorded sideloads with expiry")

    forget_parser = sub.add_parser("forget", parents=[common], help="stop tracking a sideload")
    forget_parser.add_argument("bundle_id", help="bundle identifier")

    apps_parser = sub.add_parser("apps", parents=[common, target], help="list installed apps")
    apps_parser.add_argument("--type", default="User", choices=["User", "System", "Any"])

    uninstall_parser = sub.add_parser("uninstall", parents=[common, target],
                                      help="uninstall an app by bundle id")
    uninstall_parser.add_argument("bundle_id", help="bundle identifier to remove")

    sub.add_parser("profiles", parents=[common, target],
                   help="list provisioning profiles installed on the device")

    unprovision_parser = sub.add_parser(
        "unprovision", parents=[common, target],
        help="remove a provisioning profile from the device",
    )
    unprovision_parser.add_argument("uuid", nargs="?", default=None,
                                    help="profile UUID to remove (or use --all)")
    unprovision_parser.add_argument("--all", action="store_true",
                                    help="remove every provisioning profile on the device")

    signed_parser = sub.add_parser("signed", parents=[common], help="report kept signed IPAs")
    signed_parser.add_argument("--clean", action="store_true", help="delete them")
    signed_parser.add_argument("--directory", default=None, help="folder to inspect")

    setup_parser = sub.add_parser("setup", parents=[common], help="download zsign (required to sign)")
    setup_parser.add_argument("--force", action="store_true", help="re-download even if present")

    sub.add_parser("gui", parents=[common], help="launch the desktop app")

    return parser


def getpass(prompt: str = "Apple ID password (hidden): ") -> str:
    """Password prompt that works in a plain console on Windows."""
    import getpass as _getpass

    return _getpass.getpass(prompt)


def _apply_connection(args: argparse.Namespace) -> None:
    import os

    if getattr(args, "connection", None):
        os.environ["EMLOAD_CONNECTION"] = args.connection


def dispatch(args: argparse.Namespace) -> int:
    _apply_connection(args)
    if getattr(args, "data_dir", None):
        # Re-point every paths.* helper at the override by patching the single
        # factory they all call.
        import pathlib

        override = pathlib.Path(args.data_dir).expanduser().resolve()
        override.mkdir(parents=True, exist_ok=True)
        paths.data_dir = lambda: override  # type: ignore[assignment]

    commands: dict[str, Callable[[argparse.Namespace], int]] = {
        "doctor": cmd_doctor,
        "devices": cmd_devices,
        "device-info": cmd_device_info,
        "version": cmd_version,
        "login": cmd_login,
        "account": cmd_account,
        "logout": cmd_logout,
        "teams": cmd_teams,
        "provision": cmd_provision,
        "inspect": cmd_inspect,
        "sideload": cmd_sideload,
        "refresh": cmd_refresh,
        "installs": cmd_installs,
        "forget": cmd_forget,
        "apps": cmd_apps,
        "uninstall": cmd_uninstall,
        "profiles": cmd_profiles,
        "unprovision": cmd_unprovision,
        "signed": cmd_signed,
        "setup": cmd_setup,
        "gui": cmd_gui,
    }
    return commands[args.command](args)


def main(argv: list[str] | None = None) -> int:
    _force_utf8()
    args = build_parser().parse_args(argv)
    try:
        return dispatch(args)
    except EmLoadError as exc:
        # An EmLoadError is a situation, not a bug: the phone is unplugged, Apple
        # said no, the IPA is encrypted. Its message is written to be read, so
        # print that and nothing else.
        if getattr(args, "json", False):
            print(json.dumps({"status": "error", "error": str(exc)}, ensure_ascii=False))
        else:
            print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except OSError:
            pass
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)