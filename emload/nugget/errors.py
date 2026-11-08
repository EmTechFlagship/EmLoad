"""Errors raised by the nugget (tweak) subsystem.

Ported from Nugget27 (AGPL-3.0): ``src/exceptions/nugget_exception.py``,
simplified to a single user-facing exception.
"""

from __future__ import annotations


class NuggetError(Exception):
    """A friendly, user-facing error from the tweak/restore subsystem."""