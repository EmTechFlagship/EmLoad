"""Sparserestore backup restore (Qt-free port) + perform/reboot glue.

Ported from Nugget27 (AGPL-3.0): ``src/restore/__init__.py`` and
``src/restore/restore.py``.

``perform_restore`` and ``reboot_device`` (originally in ``restore/__init__``)
live here so the module graph stays acyclic.
"""

from __future__ import annotations

import os
import plistlib
import ssl
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any, Callable

from pymobiledevice3.exceptions import (
    ConnectionTerminatedError,
    PyMobileDevice3Exception,
)
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.diagnostics import DiagnosticsService
from pymobiledevice3.services.installation_proxy import InstallationProxyService
from pymobiledevice3.services.mobilebackup2 import Mobilebackup2Service

from . import backup
from .errors import NuggetError
from .mbdb import _FileMode

ProgressFn = Callable[[Any], None]


# --------------------------------------------------------------------------- #
# Device-level actions
# --------------------------------------------------------------------------- #
def reboot_device(reboot: bool = False, lockdown_client: Any = None) -> None:
    if reboot and lockdown_client is not None:
        with DiagnosticsService(lockdown_client) as diagnostics_service:
            diagnostics_service.restart()


def perform_restore(
    backup_to_restore: backup.Backup,
    reboot: bool = False,
    lockdown_client: Any = None,
    progress_callback: ProgressFn = lambda x: None,
) -> None:
    try:
        with TemporaryDirectory() as backup_dir:
            backup_to_restore.write_to_directory(Path(backup_dir))

            if lockdown_client is None:
                lockdown_client = create_using_usbmux()
            with Mobilebackup2Service(lockdown_client) as mb:
                mb.restore(
                    backup_dir,
                    system=True,
                    reboot=False,
                    copy=False,
                    source=".",
                    progress_callback=progress_callback,
                    skip_apps=True,
                )
            # reboot the device
            reboot_device(reboot, lockdown_client)
    except PyMobileDevice3Exception as e:
        if "Find My" in str(e):
            raise NuggetError(
                "Find My must be disabled in order to use this tool.\n\n"
                "Disable Find My from Settings (Settings -> [Your Name] -> Find My)"
                " and then try again."
            ) from e
        elif "crash_on_purpose" not in str(e):
            raise
        else:
            reboot_device(reboot, lockdown_client)


# --------------------------------------------------------------------------- #
# File list building
# --------------------------------------------------------------------------- #
class FileToRestore:
    def __init__(
        self,
        contents: bytes | None,
        restore_path: str,
        contents_path: str | None = None,
        domain: str = "",
        owner: int = 501,
        group: int = 501,
        mode: _FileMode | None = None,
    ):
        self.contents = contents
        self.contents_path = contents_path
        self.restore_path = restore_path
        self.domain = domain
        self.owner = owner
        self.group = group
        self.mode = mode


def concat_exploit_file(
    file: FileToRestore, files_list: list[backup.BackupFile], last_domain: str
) -> str:
    """Add *file* as a path traversal inside a SysContainer domain (exploit)."""
    base_path = ""
    # set it to work in the separate volumes (prevents a bootloop)
    if file.restore_path.startswith("/var/mobile/"):
        # required on iOS 17.0+ since /var/mobile is on a separate partition
        base_path = "/var/mobile/backup"
    elif file.restore_path.startswith("/private/var/mobile/"):
        base_path = "/private/var/mobile/backup"
    elif file.restore_path.startswith("/private/var/"):
        base_path = "/private/var/backup"
    # don't append the directory if it has already been added (restore will fail)
    path, name = os.path.split(file.restore_path)
    domain_path = f"SysContainerDomain-../../../../../../../..{base_path}{path}/"
    new_last_domain = last_domain
    if last_domain != domain_path:
        files_list.append(
            backup.Directory("", domain_path, owner=file.owner, group=file.group)
        )
        new_last_domain = domain_path
    files_list.append(
        backup.ConcreteFile(
            "",
            f"{domain_path}{name}",
            owner=file.owner,
            group=file.group,
            contents=file.contents,
        )
    )
    return new_last_domain


def concat_regular_file(
    file: FileToRestore,
    files_list: list[backup.BackupFile],
    last_domain: str,
    last_path: str,
) -> tuple[str, str]:
    """Add *file* as a normal file within its backup domain."""
    path, name = os.path.split(file.restore_path)
    paths = path.split("/")
    new_last_domain = last_domain
    # append the domain first
    if last_domain != file.domain:
        files_list.append(backup.Directory("", file.domain, owner=file.owner, group=file.group))
        last_path = ""
        new_last_domain = file.domain
    # append each part of the path if it is not already there
    full_path = ""
    mode = file.mode
    if mode is None:
        mode = backup.DEFAULT
    for path_item in paths:
        if full_path != "":
            full_path += "/"
        full_path += path_item
        if not last_path.startswith(full_path):
            files_list.append(
                backup.Directory(full_path, file.domain, owner=file.owner, group=file.group, mode=mode)
            )
            last_path = full_path
    # finally, append the file
    files_list.append(
        backup.ConcreteFile(
            f"{full_path}/{name}",
            file.domain,
            owner=file.owner,
            group=file.group,
            contents=file.contents,
            src_path=file.contents_path,
            mode=mode,
        )
    )
    return new_last_domain, full_path


# merge all files that have duplicates and returns the list without duplicates
def merge_duplicates(original_files: list[FileToRestore]) -> list[FileToRestore]:
    no_dupe_files: list[FileToRestore] = []
    existing_locations: dict[str, int] = {}
    for file in original_files:
        if file.domain is None:
            file_loc = "-"
        else:
            file_loc = file.domain + "-"
        restore_path = file.restore_path
        if restore_path.startswith("/"):
            restore_path = restore_path.removeprefix("/")
        file_loc += restore_path
        if file_loc in existing_locations:
            if not restore_path.endswith(".plist"):
                print(f"cannot merge duplicate file, ignoring {file_loc}")
                continue
            # merge the data (plist files only)
            print(f"merging duplicate files for {file_loc}")
            initial_data = plistlib.loads(no_dupe_files[existing_locations[file_loc]].contents)
            added_data = plistlib.loads(file.contents)
            initial_data.update(added_data)
            no_dupe_files[existing_locations[file_loc]].contents = plistlib.dumps(initial_data)
        else:
            # add it to the no dupes list
            no_dupe_files.append(file)
            existing_locations[file_loc] = len(no_dupe_files) - 1
    return no_dupe_files


def has_sparserestore_capability(lockdown_client: Any = None) -> bool:
    """True while the sparserestore exploit itself works (iOS < 18.1)."""
    if lockdown_client is None:
        return True
    ver = lockdown_client.product_version.split(".")
    major = int(ver[0])
    if major > 18:
        return False
    elif major < 18:
        return True
    # there is no iOS 18.0.2 and 18.0.1 works with sparserestore,
    # so no need to check the patch number
    minor = 0
    if len(ver) > 1:
        minor = int(ver[1])
    return minor == 0


# files is a list of FileToRestore objects
def restore_files(
    files: list[FileToRestore],
    reboot: bool = False,
    lockdown_client: Any = None,
    progress_callback: ProgressFn = lambda x: None,
) -> None:
    """Restore *files* through the (sparserestore) backup mechanism."""
    # create the files to be backed up
    files_list: list[backup.BackupFile] = []
    apps_list: list[backup.AppBundle] = []
    active_bundle_ids: list[str] = []
    apps: dict | None = None
    sorted_files = sorted(merge_duplicates(files), key=lambda x: (x.domain, x.restore_path))
    # add the file paths
    last_domain = ""
    last_path = ""
    exploit_only = True
    # extra check for system version to prevent sparserestore from restoring on iOS 18.1+
    passed_version_check = has_sparserestore_capability(lockdown_client)
    for file in sorted_files:
        if file.domain == "" or file.domain == "z":
            if passed_version_check:
                last_domain = concat_exploit_file(file, files_list, last_domain)
        else:
            last_domain, last_path = concat_regular_file(file, files_list, last_domain, last_path)
            exploit_only = False
            # add the app bundle to the list
            if last_domain.startswith("AppDomain"):
                bundle_id = last_domain.removeprefix("AppDomain-")
                if bundle_id not in active_bundle_ids:
                    if apps is None:
                        apps = InstallationProxyService(lockdown=lockdown_client).get_apps(
                            application_type="Any", calculate_sizes=False
                        )
                    app_info = apps[bundle_id]
                    active_bundle_ids.append(bundle_id)
                    apps_list.append(
                        backup.AppBundle(
                            identifier=bundle_id,
                            path=app_info["Container"],
                            version=app_info["CFBundleVersion"],
                            container_content_class="Data/Application",
                        )
                    )

    # crash the restore to skip the setup (only works for exploit files)
    if exploit_only:
        files_list.append(
            backup.ConcreteFile(
                "",
                "SysContainerDomain-../../../../../../../.." + "/crash_on_purpose",
                contents=b"",
            )
        )

    # create the backup
    back = backup.Backup(files=files_list, apps=apps_list)

    for fi in files_list:
        print(f"{fi.domain}, {fi.path}")

    try:
        perform_restore(
            backup_to_restore=back,
            reboot=reboot,
            lockdown_client=lockdown_client,
            progress_callback=progress_callback,
        )
    except (ConnectionTerminatedError, ssl.SSLEOFError, ConnectionAbortedError, ConnectionResetError):
        # These errors usually mean the device rebooted successfully before
        # acknowledging the restore. We catch them and treat the process as
        # successful.
        print("Device disconnected during restore - this is expected as the device reboots.")
        if progress_callback:
            progress_callback(100)
    except Exception:
        # If it's a different error, we still want to see it
        raise