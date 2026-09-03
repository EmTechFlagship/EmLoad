"""Nugget-style device tweaks (port of Nugget27's sparserestore stack).

This subpackage brings a "Miscellaneous" menu to EmLoad:
SpringBoard options, daemons, and Liquid Glass tweaks, applied through the
sparserestore backup-restore exploit (iOS 17.0 - 18.1), plus a WebKit
overload respring.

Derived from `Nugget27 <https://github.com/leminlimez/Nugget/>`_ (AGPL-3.0).
Ported code keeps the original structure where possible, but is Qt-free:
progress is reported through ``on_progress(phase, percent, step)`` callbacks so
the GUI worker threads can surface it.

Apply routing: iOS 17.0 - 18.1 (plus unpatched 18.2 betas) uses sparserestore;
iOS 18.2+ uses BookRestore (AFC or Restore method); iOS 27 is hard-blocked
(Apple's setup flow does not honor skip-setup, leaving devices on the white
"Swipe up to upgrade" screen); fully patched devices raise
:class:`NuggetError`.
"""

from __future__ import annotations

from .bookrestore import BookRestoreApplyMethod, BookRestoreFileTransferMethod
from .constants import (
    IOS27_MOBILEGESTALT_BUILDS,
    MAX_VERSION,
    MIN_VERSION,
    Device,
    Version,
)
from .locations import FileLocation
from .tweak_names import TweakID
from .tweak_classes import (
    AdvancedPlistTweak,
    BasicPlistTweak,
    NullifyFileTweak,
    Tweak,
)
from .daemons import Daemon
from .tweaks import load_daemons, load_liquidglass, load_springboard, tweaks
from .restore import FileToRestore, restore_files
from .errors import NuggetError
from .apply import apply_tweaks, respring_device

__all__ = [
    "BookRestoreApplyMethod",
    "BookRestoreFileTransferMethod",
    "IOS27_MOBILEGESTALT_BUILDS",
    "MAX_VERSION",
    "MIN_VERSION",
    "Device",
    "Version",
    "FileLocation",
    "TweakID",
    "Tweak",
    "BasicPlistTweak",
    "AdvancedPlistTweak",
    "NullifyFileTweak",
    "Daemon",
    "tweaks",
    "load_springboard",
    "load_daemons",
    "load_liquidglass",
    "FileToRestore",
    "restore_files",
    "NuggetError",
    "apply_tweaks",
    "respring_device",
]