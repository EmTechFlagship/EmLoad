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


# --------------------------------------------------------------------------- #
# Automatic profile regeneration on integrity-check failures
# --------------------------------------------------------------------------- #
def _stub_sideload_env(monkeypatch, tmp_path) -> dict:
    """Point ``run_sideload``'s heavy dependencies at fakes; sign install nothing."""
    from emload import apps, device, ipa, provision, signing

    monkeypatch.setattr(device, "resolve_serial", lambda udid=None: udid or "deadbeef")
    monkeypatch.setattr(
        device, "get_device_info",
        lambda udid, prefer_usb=True: {"DeviceClass": "iPhone", "DeviceName": "iPhone"},
    )
    monkeypatch.setattr(
        ipa, "inspect",
        lambda path: {
            "has_sc_info": False,
            "display_name": "Demo App",
            "bundle_id": "com.example.Demo",
            "platform": "ios",
        },
    )
    monkeypatch.setattr(ipa, "deepest_entry", lambda path: 0)
    monkeypatch.setattr(provision, "team_scoped_bundle_id", lambda b: f"{b}.TEAM1234567")

    bundle = {
        "team_id": "TEAM1234567",
        "p12_path": str(tmp_path / "identity.p12"),
        "p12_password": "pw",
        "profile_path": str(tmp_path / "profile.mobileprovision"),
    }
    (tmp_path / "identity.p12").write_bytes(b"p12")
    (tmp_path / "profile.mobileprovision").write_bytes(b"profile")
    monkeypatch.setattr(provision, "ensure_signing_assets", lambda *a, **kw: bundle)
    monkeypatch.setattr(signing, "sign_ipa", lambda *a, **kw: None)
    monkeypatch.setattr(apps, "install", lambda *a, **kw: None)
    return bundle


def _fake_ipa(tmp_path) -> str:
    path = tmp_path / "demo.ipa"
    path.write_bytes(b"ipa")
    return str(path)


def test_run_sideload_regenerates_profile_on_verification_failure(monkeypatch, tmp_path):
    from pymobiledevice3.exceptions import AppInstallError

    from emload import apps, provision

    bundle = _stub_sideload_env(monkeypatch, tmp_path)
    install_calls = {"count": 0}

    def fake_install(output, udid, progress=None):
        install_calls["count"] += 1
        if install_calls["count"] == 1:
            raise AppInstallError(
                "ApplicationVerificationFailed: The application could not be verified."
            )

    monkeypatch.setattr(apps, "install", fake_install)

    fresh_bundle = dict(bundle, profile_path=str(tmp_path / "fresh.mobileprovision"))
    (tmp_path / "fresh.mobileprovision").write_bytes(b"fresh")
    regen_calls = {"count": 0, "udid": None, "bundle_id": None}

    def fake_regenerate(bundle_id, udid, **kwargs):
        regen_calls["count"] += 1
        regen_calls["udid"] = udid
        regen_calls["bundle_id"] = bundle_id
        return fresh_bundle

    monkeypatch.setattr(provision, "regenerate_profile", fake_regenerate)

    result = sideload.run_sideload(
        _fake_ipa(tmp_path),
        "deadbeef",
        signed_dir=str(tmp_path / "signed"),
    )

    assert install_calls["count"] == 2          # failed once, re-signed, installed again
    assert regen_calls["count"] == 1            # one fresh profile was issued
    assert regen_calls["udid"] == "deadbeef"
    assert regen_calls["bundle_id"] == "com.example.Demo.TEAM1234567"
    assert result["status"] == "installed"
    assert result["profile_regenerations"] == 1


def test_run_sideload_does_not_regenerate_on_other_install_errors(monkeypatch, tmp_path):
    import pytest
    from pymobiledevice3.exceptions import AppInstallError

    from emload import apps, provision

    _stub_sideload_env(monkeypatch, tmp_path)
    monkeypatch.setattr(
        apps, "install",
        lambda output, udid, progress=None: (_ for _ in ()).throw(
            AppInstallError("DiskFull: No space left on device")
        ),
    )

    def fake_regenerate(*args, **kwargs):
        raise AssertionError("must not regenerate for a non-verification error")

    monkeypatch.setattr(provision, "regenerate_profile", fake_regenerate)

    with pytest.raises(AppInstallError):
        sideload.run_sideload(
            _fake_ipa(tmp_path),
            "deadbeef",
            signed_dir=str(tmp_path / "signed"),
        )


def test_run_sideload_gives_up_after_max_regenerations(monkeypatch, tmp_path):
    import pytest
    from pymobiledevice3.exceptions import AppInstallError

    from emload import apps, provision

    bundle = _stub_sideload_env(monkeypatch, tmp_path)
    install_calls = {"count": 0}

    def fake_install(output, udid, progress=None):
        install_calls["count"] += 1
        raise AppInstallError("ApplicationVerificationFailed: The application could not be verified.")

    monkeypatch.setattr(apps, "install", fake_install)
    regen_calls = {"count": 0}
    monkeypatch.setattr(
        provision, "regenerate_profile", lambda *a, **kw: (regen_calls.__setitem__("count", regen_calls["count"] + 1), bundle)[1]
    )

    with pytest.raises(AppInstallError):
        sideload.run_sideload(
            _fake_ipa(tmp_path),
            "deadbeef",
            signed_dir=str(tmp_path / "signed"),
        )

    # Bounded: exactly MAX regenerations, then the original failure surfaces.
    assert regen_calls["count"] == sideload.MAX_PROFILE_REGENERATIONS
    assert install_calls["count"] == sideload.MAX_PROFILE_REGENERATIONS + 1