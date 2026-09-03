"""Tweak object model (Qt-free port).

Ported from Nugget27 (AGPL-3.0): ``src/tweaks/tweak_classes.py``.

The Qt ``QCoreApplication.tr()`` calls were dropped and only the classes the
SpringBoard / Daemons / Liquid Glass families use were kept
(:class:`Tweak`, :class:`NullifyFileTweak`, :class:`BasicPlistTweak`,
:class:`AdvancedPlistTweak`).
"""

from __future__ import annotations

from typing import Any

from .locations import FileLocation


class Tweak:
    def __init__(self, key: str | None, value: Any = 1, owner: int = 501, group: int = 501):
        self.key = key
        self.value = value
        self.owner = owner
        self.group = group
        self.enabled = False

    def set_enabled(self, value: bool) -> None:
        self.enabled = value

    def toggle_enabled(self) -> None:
        self.enabled = not self.enabled

    def set_value(self, new_value: Any, toggle_enabled: bool = True) -> None:
        self.value = new_value
        if toggle_enabled:
            self.enabled = True

    def apply_tweak(self, *args: Any, **kwargs: Any) -> Any:
        raise NotImplementedError


class NullifyFileTweak(Tweak):
    """Nulls (zeros) an entire file instead of editing a plist key."""

    def __init__(self, file_location: FileLocation, owner: int = 501, group: int = 501):
        super().__init__(key=None, value=None, owner=owner, group=group)
        self.file_location = file_location

    def apply_tweak(self, other_tweaks: dict) -> dict:
        if self.enabled:
            other_tweaks[self.file_location] = b""
        return other_tweaks


class BasicPlistTweak(Tweak):
    """Sets one key inside a plist located at ``file_location``."""

    def __init__(
        self,
        file_location: FileLocation,
        key: str,
        value: Any = True,
        owner: int = 501,
        group: int = 501,
        is_risky: bool = False,
    ):
        super().__init__(key=key, value=value, owner=owner, group=group)
        self.file_location = file_location
        self.is_risky = is_risky

    def apply_tweak(self, other_tweaks: dict, risky_allowed: bool = False) -> dict:
        if not self.enabled or (self.is_risky and not risky_allowed):
            return other_tweaks
        if self.file_location in other_tweaks:
            other_tweaks[self.file_location][self.key] = self.value
        else:
            other_tweaks[self.file_location] = {self.key: self.value}
        return other_tweaks


class AdvancedPlistTweak(BasicPlistTweak):
    """Replaces a whole plist (or sets several keys at once)."""

    def __init__(
        self,
        file_location: FileLocation,
        key_values: dict,
        owner: int = 501,
        group: int = 501,
        is_risky: bool = False,
    ):
        super().__init__(
            file_location=file_location,
            key=None,
            value=key_values,
            owner=owner,
            group=group,
            is_risky=is_risky,
        )

    def set_multiple_values(self, keys: list[str], value: Any) -> None:
        for key in keys:
            self.value[key] = value

    def apply_tweak(self, other_tweaks: dict, risky_allowed: bool = False) -> dict:
        if not self.enabled or (self.is_risky and not risky_allowed):
            return other_tweaks
        plist: dict = {}
        for key in self.value:
            plist[key] = self.value[key]
        other_tweaks[self.file_location] = plist
        return other_tweaks