"""Tests for the sideload registry and profile expiry parsing."""

from __future__ import annotations

import datetime

from emload import registry


def _entry(bundle_id="com.example.App", expires_at=None):
    return {
        "bundle_id": bundle_id,
        "name": "App",
        "expires_at": expires_at,
        "installed_at": "2026-01-01T00:00:00+00:00",
    }


def test_record_get_forget():
    registry.record(_entry())
    assert registry.get("com.example.App")["bundle_id"] == "com.example.App"
    assert registry.forget("com.example.App") is True
    assert registry.get("com.example.App") is None
    assert registry.forget("com.example.App") is False


def test_records_sorted_by_expiry():
    registry.record(_entry("a", "2026-01-10T00:00:00+00:00"))
    registry.record(_entry("b", "2026-01-05T00:00:00+00:00"))
    registry.record(_entry("c", None))
    records = registry.records()
    assert [r["bundle_id"] for r in records] == ["b", "a", "c"]


def test_days_left_and_expired():
    soon = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)).isoformat()
    past = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)).isoformat()
    registry.record(_entry("soon", soon))
    registry.record(_entry("past", past))
    records = {r["bundle_id"]: r for r in registry.records()}
    assert records["soon"]["days_left"] == 1.0
    assert records["past"]["expired"] is True
    assert records["soon"]["expired"] is False
    assert {r["bundle_id"] for r in registry.due(within_days=2)} == {"soon", "past"}


def test_profile_expiration():
    # A CMS-wrapped profile with an embedded XML plist.
    import plistlib

    expiry = datetime.datetime(2026, 1, 8, 12, 0, 0, tzinfo=datetime.timezone.utc)
    inner = plistlib.dumps(
        {"ExpirationDate": expiry, "Name": "x"},
        fmt=plistlib.FMT_XML,
    )
    blob = b"PKCS7 junk" + inner + b"PKCS7 junk"
    parsed = registry.profile_expiration(blob)
    assert parsed == expiry

    assert registry.profile_expiration(b"no plist here") is None