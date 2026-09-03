"""Version math and per-device capability checks.

Ported from Nugget27 (AGPL-3.0): ``src/devicemanagement/constants.py``.
Only the pieces needed for the sparserestore path are exercised by EmLoad,
but the checks are kept faithful so capability questions answer the same way.
"""

from __future__ import annotations

from typing import Any

MIN_VERSION = "17.0"
MAX_VERSION = "26.9"

# iOS 27 Beta 1-4 builds where MobileGestalt tweaks still work.
# MobileGestalt was patched starting with iOS 27 Beta 5.
IOS27_MOBILEGESTALT_BUILDS = ["24A5390f"]  # iOS 27 Beta 4


class Version:
    """A simple ``major.minor.patch`` version with comparison operators."""

    def __init__(self, ver: str):
        nums: list[str] = ver.split(".")
        self.major = int(nums[0])
        self.minor = int(nums[1]) if len(nums) > 1 else 0
        self.patch = int(nums[2]) if len(nums) > 2 else 0

    def compare_to(self, other: "Version") -> int:
        if self.major > other.major:
            return 1
        elif self.major < other.major:
            return -1
        if self.minor > other.minor:
            return 1
        elif self.minor < other.minor:
            return -1
        if self.patch > other.patch:
            return 1
        elif self.patch < other.patch:
            return -1
        return 0

    def __gt__(self, other: "Version") -> bool:
        return self.compare_to(other) == 1

    def __ge__(self, other: "Version") -> bool:
        comp: int = self.compare_to(other)
        return comp == 0 or comp == 1

    def __lt__(self, other: "Version") -> bool:
        return self.compare_to(other) == -1

    def __le__(self, other: "Version") -> bool:
        comp: int = self.compare_to(other)
        return comp == 0 or comp == -1

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Version):
            return NotImplemented
        return self.compare_to(other) == 0

    def __repr__(self) -> str:
        return f"Version({self.major}.{self.minor}.{self.patch})"


class Device:
    """A connected iPhone/iPad plus the capability checks that gate restores."""

    def __init__(
        self,
        udid: str,
        usb: bool,
        name: str,
        version: str,
        build: str,
        model: str,
        hardware: str,
        cpu: str,
        locale: str | None,
        books_container_uuid: str,
        ld: Any,
    ):
        self.udid = udid
        self.connected_via_usb = usb
        self.name = name
        self.version = version
        self.build = build
        self.model = model
        self.hardware = hardware
        self.cpu = cpu
        self.locale = locale
        self.books_container_uuid = books_container_uuid
        self.ld = ld

    def is_exploit_fully_patched(self) -> bool:
        # mobile gestalt methods are completely patched on iOS 26.2 beta 2+
        return not (self.has_bookrestore() or self.has_partial_sparserestore())

    def has_bookrestore(self) -> bool:
        parsed_ver: Version = Version(self.version)
        if Version("18.7.5") <= parsed_ver < Version("26.0"):
            return False
        if parsed_ver <= Version("26.1") or self.build == "23C5027f":
            return True
        # iOS 27 Beta 1-4 builds still support MobileGestalt via BookRestore
        if self.is_ios27_beta() and self.build in IOS27_MOBILEGESTALT_BUILDS:
            return True
        return False

    def has_partial_sparserestore(self) -> bool:
        parsed_ver: Version = Version(self.version)
        if parsed_ver < Version("18.2") or self.build in ("22C5109p", "22C5125e"):
            return True
        return False

    def has_exploit(self) -> bool:
        parsed_ver: Version = Version(self.version)
        # make sure versions past 17.7.1 but before 18.0 aren't supported
        if Version("17.7.1") <= parsed_ver < Version("18.0"):
            return False
        if parsed_ver < Version("18.1") or self.build in (
            "22B5007p",
            "22B5023e",
            "22B5034e",
            "22B5045g",
        ):
            return True
        return False

    def partially_supported(self) -> bool:
        return self.has_exploit()

    def supported(self) -> bool:
        parsed_ver: Version = Version(self.version)
        return Version(MIN_VERSION) <= parsed_ver <= Version(MAX_VERSION)

    def is_ios27_beta(self) -> bool:
        parsed_ver: Version = Version(self.version)
        if Version("27.0") <= parsed_ver < Version("27.1"):
            # beta builds end in a letter, release builds end in a digit
            return len(self.build) > 0 and not self.build[-1].isdigit()
        return False

    def is_iphone_13_or_newer(self) -> bool:
        if not self.model.startswith("iPhone"):
            return False
        try:
            model_num = int(self.model.removeprefix("iPhone").split(",")[0])
        except ValueError:
            return False
        return model_num >= 14