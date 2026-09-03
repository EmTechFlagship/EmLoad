"""Tests for sideload orchestration helpers (progress relay, signed-IPA cleanup)."""

from __future__ import annotations

from emload import sideload


def test_install_relay_upload():
    percent, step = sideload._install_relay(
        {"phase": "upload", "percent": 50, "sent": 50 * (1 << 20), "total": 100 * (1 << 20)},
        "iPhone",
    )
    assert percent == 40
    assert "50 / 100 MB" in step


def test_install_relay_phases():
    percent, step = sideload._install_relay(
        {"phase": "install", "percent": 50, "status": "ExtractingPackage"}
    )
    assert percent == 90
    assert "Extracting" in step


def test_install_relay_done():
    percent, step = sideload._install_relay({"phase": "install", "status": "Complete"})
    assert percent == 100
    assert step == "Installed"


def test_signed_status_and_clean(tmp_path):
    (tmp_path / "App_Signed.ipa").write_bytes(b"x" * 10)
    (tmp_path / "App_Signed.ipa.bak").write_bytes(b"y")  # not ours
    (tmp_path / "source.ipa").write_bytes(b"z")          # not ours
    sub = tmp_path / "sub"
    sub.mkdir()
    (sub / "Nested_Signed.ipa").write_bytes(b"w")        # not ours (subdir)

    status = sideload.signed_status(str(tmp_path))
    assert status["count"] == 1
    assert status["bytes"] == 10

    cleaned = sideload.clean_signed(str(tmp_path))
    assert cleaned["removed"] == 1
    assert cleaned["bytes_freed"] == 10
    assert (tmp_path / "source.ipa").exists()
    assert (tmp_path / "App_Signed.ipa.bak").exists()
    assert (sub / "Nested_Signed.ipa").exists()


def test_platform_mismatch_rejected(tmp_path):
    from emload.errors import EmLoadError

    # iOS app -> Apple TV device class must be refused.
    ipa_path = str(tmp_path / "app.ipa")
    info = {"platform": "ios"}
    try:
        sideload._check_platform_matches_device(ipa_path, info, "appletv")
    except EmLoadError as exc:
        assert "built for ios devices" in str(exc)
        assert "Apple TV" in str(exc)
    else:
        raise AssertionError("expected a mismatch error")

    # iOS app -> iPhone is fine.
    sideload._check_platform_matches_device(ipa_path, info, "iphone")
    # Unknown platform is allowed through.
    sideload._check_platform_matches_device(ipa_path, {"platform": None}, "appletv")