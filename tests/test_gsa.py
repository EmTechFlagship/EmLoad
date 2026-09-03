"""Tests for protocol helpers (GSA crypto + anisette header hygiene)."""

from __future__ import annotations

import hmac
import hashlib

from emload import anisette, gsa


def test_identity_token():
    token = gsa._identity_token("adsid123", "idms456")
    import base64

    assert base64.b64decode(token).decode() == "adsid123:idms456"


def test_app_tokens_checksum_deterministic():
    sk = b"\x00" * 32
    a = gsa._app_tokens_checksum(sk, "adsid", ["com.apple.gs.xcode.auth"])
    b = gsa._app_tokens_checksum(sk, "adsid", ["com.apple.gs.xcode.auth"])
    assert a == b
    assert len(a) == 32


def test_loads_plist_tolerates_missing_prolog():
    raw = b'<plist version="1.0"><dict><key>a</key><integer>1</integer></dict></plist>'
    assert gsa._loads_plist(raw) == {"a": 1}


def test_session_hmac():
    key = b"k" * 32
    assert gsa._session_hmac(key, "extra data key:") == hmac.new(
        key, b"extra data key:", hashlib.sha256
    ).digest()


def test_ascii_timezone_ascii():
    value = anisette.ascii_timezone()
    assert value.isascii() and value.strip()


def test_ascii_locale_maps_windows_names():
    assert anisette.ascii_locale("en_US") == "en_US"
    assert anisette.ascii_locale("zh_CN") == "zh_CN"
    assert anisette.ascii_locale("Chinese (Simplified)_China") == "zh_CN"
    assert anisette.ascii_locale("garbage") in ("en_US", "garbage")


def test_gmt_offset_label():
    import datetime

    offset = datetime.timedelta(hours=5, minutes=30)
    assert anisette._gmt_offset_label(offset) == "GMT+05:30"
    assert anisette._gmt_offset_label(-datetime.timedelta(hours=8)) == "GMT-08:00"