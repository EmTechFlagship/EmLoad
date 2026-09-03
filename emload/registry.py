"""Sideload registry + expiry tracking (the basis of refresh).

A free Apple ID's provisioning profile expires seven days after it is issued, at
which point the sideloaded app stops launching. We record each successful
sideload - the source IPA plus the exact options it was signed with - so the app
can re-sign and reinstall it before it expires, either on demand from the UI or
from a scheduled background task.

The registry is a single JSON file keyed by installed bundle id. It holds no
secrets (only paths + option flags + timestamps).
"""

from __future__ import annotations

import datetime
import json
import plistlib
from typing import Any

from . import paths


def _now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def _load() -> dict[str, Any]:
    path = paths.installs_file()
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
        except (ValueError, OSError):
            return {}
    return {}


def _save(data: dict[str, Any]) -> None:
    paths.installs_file().write_text(json.dumps(data, indent=2), encoding="utf-8")


def profile_expiration(profile_bytes: bytes) -> datetime.datetime | None:
    """Extract ``ExpirationDate`` from a ``.mobileprovision`` (CMS-wrapped plist).

    A provisioning profile is a PKCS#7/CMS blob with an XML plist embedded in the
    signed content; slice the plist out and read its expiry.
    """
    start = profile_bytes.find(b"<?xml")
    end = profile_bytes.find(b"</plist>")
    if start == -1 or end == -1:
        return None
    try:
        plist = plistlib.loads(profile_bytes[start: end + len(b"</plist>")])
    except Exception:
        return None
    expiry = plist.get("ExpirationDate")
    if isinstance(expiry, datetime.datetime):
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=datetime.timezone.utc)
        return expiry
    return None


def record(entry: dict[str, Any]) -> dict[str, Any]:
    """Upsert a sideload record, keyed by its installed bundle id."""
    data = _load()
    data[entry["bundle_id"]] = entry
    _save(data)
    return entry


def get(bundle_id: str) -> dict[str, Any] | None:
    return _load().get(bundle_id)


def forget(bundle_id: str) -> bool:
    data = _load()
    if bundle_id in data:
        del data[bundle_id]
        _save(data)
        return True
    return False


def _days_left(expires_at: str | None) -> float | None:
    if not expires_at:
        return None
    try:
        expiry = datetime.datetime.fromisoformat(expires_at)
    except ValueError:
        return None
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    return round((expiry - _now()).total_seconds() / 86400, 2)


def records() -> list[dict[str, Any]]:
    """All recorded sideloads, annotated with ``days_left`` + ``expired``, soonest first."""
    out: list[dict[str, Any]] = []
    for entry in _load().values():
        item = dict(entry)
        days = _days_left(entry.get("expires_at"))
        item["days_left"] = days
        item["expired"] = days is not None and days <= 0
        out.append(item)
    out.sort(key=lambda r: (r.get("days_left") is None, r.get("days_left") or 0.0))
    return out


def due(within_days: float = 2.0) -> list[dict[str, Any]]:
    """Records whose profile expires within ``within_days`` (or already has)."""
    return [
        r for r in records()
        if r.get("days_left") is not None and r["days_left"] <= within_days
    ]