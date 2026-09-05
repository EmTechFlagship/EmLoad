"""Tests for installing the signed-in team's provisioning profile on a device."""

from __future__ import annotations

import plistlib
from datetime import datetime

from emload import provision


def _fake_profile() -> bytes:
    """A minimal CMS-shaped ``.mobileprovision`` (plain plist is enough to parse)."""
    return plistlib.dumps(
        {
            "Name": "Team Development Profile",
            "UUID": "01234567-89ab-cdef-0123-456789abcdef",
            "ApplicationIdentifier": "ABCDE12345.com.example.Demo",
            "TeamIdentifier": ["ABCDE12345"],
            "ExpirationDate": datetime(2026, 9, 10),
            "ProvisionedDevices": ["deadbeef", "cafebabe"],
        }
    )


def test_profile_summary_parses_embedded_plist():
    summary = provision.profile_summary(_fake_profile())
    assert summary["name"] == "Team Development Profile"
    assert summary["uuid"] == "01234567-89AB-CDEF-0123-456789ABCDEF"
    assert summary["app_id"] == "ABCDE12345.com.example.Demo"
    assert summary["team"] == "ABCDE12345"
    assert summary["device_count"] == 2
    # plist dates come back naive; the summary normalizes them to UTC.
    assert summary["expires_at"] == "2026-09-10T00:00:00+00:00"


def test_profile_summary_tolerates_garbage():
    assert provision.profile_summary(b"not a profile") == {
        "name": None,
        "uuid": "",
        "app_id": None,
        "team": "",
        "expires_at": None,
        "device_count": 0,
    }


def test_install_profile_sends_bytes_via_misagent(monkeypatch):
    captured: dict[str, bytes] = {}

    class FakeClient:
        async def close(self):
            pass

    class FakeMisagent:
        def __init__(self, lockdown):
            self.lockdown = lockdown

        async def install(self, plist):
            captured["data"] = plist.read()
            return {"Status": 0}

        async def close(self):
            pass

    async def fake_create(serial, prefer_usb=True):
        assert serial == "deadbeef"
        return FakeClient()

    monkeypatch.setattr("pymobiledevice3.services.misagent.MisagentService", FakeMisagent)
    monkeypatch.setattr(provision.lockdown, "create", fake_create)

    profile = _fake_profile()
    summary = provision.install_profile("deadbeef", profile)

    assert captured["data"] == profile
    assert summary["uuid"] == "01234567-89AB-CDEF-0123-456789ABCDEF"


def test_list_profiles_parses_installed(monkeypatch):
    class FakeClient:
        async def close(self):
            pass

    class FakeProfile:
        def __init__(self, buf):
            self.buf = buf

    class FakeMisagent:
        def __init__(self, lockdown):
            self.lockdown = lockdown

        async def copy_all(self):
            return [FakeProfile(_fake_profile())]

        async def close(self):
            pass

    async def fake_create(serial, prefer_usb=True):
        assert serial == "00008110-000C4D8E0C40401E"
        return FakeClient()

    monkeypatch.setattr("pymobiledevice3.services.misagent.MisagentService", FakeMisagent)
    monkeypatch.setattr(provision.lockdown, "create", fake_create)

    rows = provision.list_profiles("00008110-000C4D8E0C40401E")

    assert len(rows) == 1
    assert rows[0]["uuid"] == "01234567-89AB-CDEF-0123-456789ABCDEF"
    assert rows[0]["name"] == "Team Development Profile"
    assert rows[0]["app_id"] == "ABCDE12345.com.example.Demo"
    assert rows[0]["device_count"] == 2


def test_remove_profile_sends_uuid(monkeypatch):
    captured: dict[str, str] = {}

    class FakeClient:
        async def close(self):
            pass

    class FakeMisagent:
        def __init__(self, lockdown):
            self.lockdown = lockdown

        async def remove(self, profile_id):
            captured["uuid"] = profile_id
            return {"Status": 0}

        async def close(self):
            pass

    async def fake_create(serial, prefer_usb=True):
        return FakeClient()

    monkeypatch.setattr("pymobiledevice3.services.misagent.MisagentService", FakeMisagent)
    monkeypatch.setattr(provision.lockdown, "create", fake_create)

    result = provision.remove_profile("D65AF0F7-C9D3-43AB-B687-E57883C8F64A", "deadbeef")

    assert captured["uuid"] == "D65AF0F7-C9D3-43AB-B687-E57883C8F64A"
    assert result == {"uuid": "D65AF0F7-C9D3-43AB-B687-E57883C8F64A", "removed": True, "udid": "deadbeef"}


def test_clear_profiles_removes_all(monkeypatch):
    profiles = [
        {"uuid": "A", "name": "One"},
        {"uuid": "B", "name": "Two"},
        {"uuid": "C", "name": "Three"},
    ]
    monkeypatch.setattr(provision, "list_profiles", lambda udid: profiles)

    removed: list[str] = []

    def fake_remove(uuid, udid=None):
        removed.append(uuid)
        return {"removed": True}

    monkeypatch.setattr(provision, "remove_profile", fake_remove)

    result = provision.clear_profiles("deadbeef")

    assert result["removed"] == 3
    assert result["total"] == 3
    assert removed == ["A", "B", "C"]


def test_clear_profiles_reports_failures(monkeypatch):
    monkeypatch.setattr(
        provision, "list_profiles",
        lambda udid: [{"uuid": "A"}, {"uuid": "B"}],
    )

    def fake_remove(uuid, udid=None):
        if uuid == "B":
            raise RuntimeError("device locked")
        return {"removed": True}

    monkeypatch.setattr(provision, "remove_profile", fake_remove)

    result = provision.clear_profiles("deadbeef")

    assert result["removed"] == 1
    assert result["total"] == 2
    assert len(result["failed"]) == 1
    assert "B" in result["failed"][0]


# --------------------------------------------------------------------------- #
# Auto-reprovision on device connect
# --------------------------------------------------------------------------- #
_ACCOUNT = "alice@example.com"


def _slug() -> str:
    return provision._account_slug(_ACCOUNT)


def _write_bundle(tmp_path, **overrides) -> dict[str, Any]:
    """Seed the signing cache for the test account and return the bundle dict."""
    from emload import paths

    monkey_bundle = {
        "team_id": "ABCDE12345",
        "account": _ACCOUNT,
        "bundle_id": "com.example.Demo",
        "udid": "old-device",
        "name": "Demo App",
        "profile_path": "n/a",
    }
    monkey_bundle.update(overrides)
    folder = paths.signing_dir(_slug())
    (folder / "certificate.json").write_text("{}", encoding="utf-8")
    (folder / "bundle.json").write_text(
        __import__("json").dumps(monkey_bundle), encoding="utf-8"
    )
    (folder / "identity.p12").write_bytes(b"p12")
    (folder / "profile.mobileprovision").write_bytes(_fake_profile())
    return monkey_bundle


def test_ensure_provisioned_not_signed_in(monkeypatch):
    monkeypatch.setattr(
        provision.gsa, "load_session",
        lambda email=None: (_ for _ in ()).throw(provision.gsa.GsaError("not signed in")),
    )
    result = provision.ensure_provisioned_for_device("deadbeef")
    assert result == {"status": "not_signed_in"}


def test_ensure_provisioned_no_cached_bundle(monkeypatch):
    monkeypatch.setattr(
        provision.gsa, "load_session", lambda email=None: {"email": _ACCOUNT}
    )
    result = provision.ensure_provisioned_for_device("deadbeef")
    assert result == {"status": "no_cached_bundle"}


def test_ensure_provisioned_up_to_date(monkeypatch):
    monkeypatch.setattr(
        provision.gsa, "load_session", lambda email=None: {"email": _ACCOUNT}
    )

    def fake_load_bundle():
        return {"udid": "deadbeef", "bundle_id": "com.example.Demo"}

    monkeypatch.setattr(provision, "load_bundle", fake_load_bundle)
    result = provision.ensure_provisioned_for_device("deadbeef")
    assert result == {"status": "up_to_date", "udid": "deadbeef"}


def test_ensure_provisioned_reprovisions_for_new_device(monkeypatch, tmp_path):
    from emload import paths

    _write_bundle(tmp_path)  # cache belongs to "old-device"
    monkeypatch.setattr(
        provision.gsa, "load_session", lambda email=None: {"email": _ACCOUNT}
    )

    calls: dict[str, Any] = {}
    profile_file = tmp_path / "fresh.mobileprovision"
    profile_file.write_bytes(_fake_profile())

    def fake_ensure_signing_assets(bundle_id, udid, **kwargs):
        calls["ensure"] = (bundle_id, udid, kwargs)
        return {
            "team_id": "ABCDE12345",
            "bundle_id": bundle_id,
            "profile_path": str(profile_file),
        }

    def fake_install_profile(udid, profile_bytes):
        calls["install"] = (udid, profile_bytes)

    monkeypatch.setattr(provision, "ensure_signing_assets", fake_ensure_signing_assets)
    monkeypatch.setattr(provision, "install_profile", fake_install_profile)
    monkeypatch.setattr(
        provision.device, "get_device_info", lambda udid, **kw: {"DeviceName": "My iPhone"}
    )

    result = provision.ensure_provisioned_for_device("new-device")

    assert result["status"] == "reprovisioned"
    assert result["device_name"] == "My iPhone"
    assert result["profile_installed"] is True
    # Provisioned for the new device, reusing the old bundle's App ID.
    assert calls["ensure"][0] == "com.example.Demo"
    assert calls["ensure"][1] == "new-device"
    assert calls["ensure"][2]["device_name"] == "My iPhone"
    assert calls["install"][0] == "new-device"
    assert calls["install"][1] == _fake_profile()
    # The certificate is kept: it is not device-specific, and deleting it is what
    # forces Apple error 7460 (a current cert or pending request already exists).
    folder = paths.signing_dir(_slug())
    for name in ("certificate.json", "identity.p12"):
        assert (folder / name).exists()


def test_ensure_provisioned_reports_install_failure(monkeypatch, tmp_path):
    _write_bundle(tmp_path)
    monkeypatch.setattr(
        provision.gsa, "load_session", lambda email=None: {"email": _ACCOUNT}
    )

    profile_file = tmp_path / "fresh.mobileprovision"
    profile_file.write_bytes(_fake_profile())

    monkeypatch.setattr(
        provision,
        "ensure_signing_assets",
        lambda bundle_id, udid, **kw: {
            "team_id": "ABCDE12345",
            "bundle_id": bundle_id,
            "profile_path": str(profile_file),
        },
    )
    monkeypatch.setattr(
        provision, "install_profile", lambda udid, data: (_ for _ in ()).throw(RuntimeError("device locked"))
    )

    result = provision.ensure_provisioned_for_device("new-device")

    assert result["status"] == "reprovisioned"
    assert result["profile_installed"] is False
    assert "device locked" in result["warning"]


def test_ensure_certificate_recovers_from_7460(monkeypatch, tmp_path):
    """Apple error 7460 (current cert / pending request) is handled by revoking
    our own cert and retrying the submission once."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.x509.oid import NameOID

    from emload import developer, signing

    real_generate_key_and_csr = signing.generate_key_and_csr
    generated: dict[str, Any] = {}

    def fake_generate_key_and_csr():
        key_pem, csr_pem = real_generate_key_and_csr()
        generated["key_pem"] = key_pem
        return key_pem, csr_pem

    def cert_for_key(key_pem):
        key = serialization.load_pem_private_key(key_pem, password=None)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "EmLoad")])
        cert = (
            x509.CertificateBuilder()
            .subject_name(name)
            .issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(datetime(2026, 1, 1))
            .not_valid_after(datetime(2030, 1, 1))
            .sign(key, hashes.SHA256())
        )
        return cert.public_bytes(serialization.Encoding.DER)

    # Apple's side still has an old EmLoad cert (the private key is gone, so it
    # must be revoked before Apple will issue another one).
    server_certs = [
        {
            "serialNumber": "S-OLD",
            "machineName": "EmLoad",
            "certContent": cert_for_key(signing.generate_key_and_csr()[0]),
        }
    ]

    submit_calls = {"count": 0}
    revoke_calls: list[str] = []

    def fake_list_certificates(team_id):
        if submit_calls["count"] >= 2:  # after the retried submit succeeded
            return [
                {
                    "serialNumber": "S-NEW",
                    "machineName": "EmLoad",
                    "certContent": cert_for_key(generated["key_pem"]),
                }
            ]
        return server_certs

    def fake_revoke(team_id, serial):
        revoke_calls.append(serial)

    def fake_submit(team_id, csr_pem, machine_name="EmLoad"):
        submit_calls["count"] += 1
        if submit_calls["count"] == 1:
            raise developer.DeveloperServicesError(
                "7460: You already have a current iOS Development certificate "
                "or a pending certificate request."
            )
        return {"certRequest": {"serialNumber": "S-NEW"}}

    monkeypatch.setattr(provision.signing, "generate_key_and_csr", fake_generate_key_and_csr)
    monkeypatch.setattr(provision.developer, "list_certificates", fake_list_certificates)
    monkeypatch.setattr(provision.developer, "revoke_certificate", fake_revoke)
    monkeypatch.setattr(provision.developer, "submit_csr", fake_submit)
    monkeypatch.setattr("time.sleep", lambda _seconds: None)

    key_pem, cert_der, serial = provision._ensure_certificate("TEAM", _slug())

    assert submit_calls["count"] == 2
    assert "S-OLD" in revoke_calls
    assert serial == "S-NEW"
    assert x509.load_der_x509_certificate(cert_der).subject.rfc4514_string() == "CN=EmLoad"
    assert key_pem == generated["key_pem"]


# --------------------------------------------------------------------------- #
# Regenerating the provisioning profile after an integrity-check failure
# --------------------------------------------------------------------------- #
def test_regenerate_profile_deletes_old_and_fetches_fresh(monkeypatch, tmp_path):
    from emload import paths

    _write_bundle(tmp_path)  # seeds the old profile (UUID ...abcdef) + bundle cache
    monkeypatch.setattr(
        provision.gsa, "load_session", lambda email=None: {"email": _ACCOUNT}
    )

    fresh_profile = tmp_path / "fresh.mobileprovision"
    fresh_profile.write_bytes(_fake_profile())
    removed: list[str] = []

    def fake_ensure(bundle_id, udid, **kwargs):
        assert bundle_id == "com.example.Demo"
        assert udid == "deadbeef"
        return {
            "team_id": "ABCDE12345",
            "bundle_id": bundle_id,
            "udid": udid,
            "profile_path": str(fresh_profile),
            "p12_path": "n/a",
            "p12_password": "n/a",
            "app_id_id": "ABCDE12345.com.example.Demo",
        }

    def fake_remove(uuid, udid=None):
        removed.append(uuid)
        return {"removed": True}

    monkeypatch.setattr(provision, "ensure_signing_assets", fake_ensure)
    monkeypatch.setattr(provision, "remove_profile", fake_remove)

    result = provision.regenerate_profile("com.example.Demo", "deadbeef")

    # The fresh profile replaces the old one.
    assert result["profile_path"] == str(fresh_profile)
    assert removed == ["01234567-89AB-CDEF-0123-456789ABCDEF"]
    # The old profile + bundle cache are gone, so nothing points at them.
    folder = paths.signing_dir(_slug())
    assert not (folder / "profile.mobileprovision").exists()
    assert not (folder / "bundle.json").exists()


def test_regenerate_profile_removes_old_by_app_id_when_uuid_missing(monkeypatch, tmp_path):
    """No cached profile file (unknown UUID): retire any on-device profile for the app."""
    import json

    from emload import paths

    folder = paths.signing_dir(_slug())
    folder.mkdir(parents=True, exist_ok=True)
    # Only the bundle cache survives; it still names the App ID.
    (folder / "bundle.json").write_text(
        json.dumps({"app_id_id": "ABCDE12345.com.example.Demo"}), encoding="utf-8"
    )
    monkeypatch.setattr(
        provision.gsa, "load_session", lambda email=None: {"email": _ACCOUNT}
    )

    fresh_profile = tmp_path / "fresh.mobileprovision"
    fresh_profile.write_bytes(_fake_profile())
    monkeypatch.setattr(
        provision,
        "ensure_signing_assets",
        lambda bundle_id, udid, **kw: {"profile_path": str(fresh_profile)},
    )
    monkeypatch.setattr(
        provision,
        "list_profiles",
        lambda udid: [
            {"uuid": "STALE-1", "app_id": "ABCDE12345.com.example.Demo"},
            {"uuid": "OTHER-1", "app_id": "ABCDE12345.com.other.App"},
        ],
    )
    removed: list[str] = []
    monkeypatch.setattr(
        provision, "remove_profile", lambda uuid, udid=None: removed.append(uuid)
    )

    provision.regenerate_profile("com.example.Demo", "deadbeef")

    assert removed == ["STALE-1"]  # only the profile for this app id


def test_regenerate_profile_tolerates_device_removal_failure(monkeypatch, tmp_path):
    """A locked/unreachable device must not stop the fresh profile from being issued."""
    _write_bundle(tmp_path)
    monkeypatch.setattr(
        provision.gsa, "load_session", lambda email=None: {"email": _ACCOUNT}
    )

    fresh_profile = tmp_path / "fresh.mobileprovision"
    fresh_profile.write_bytes(_fake_profile())
    monkeypatch.setattr(
        provision,
        "ensure_signing_assets",
        lambda bundle_id, udid, **kw: {"profile_path": str(fresh_profile)},
    )
    monkeypatch.setattr(
        provision,
        "remove_profile",
        lambda uuid, udid=None: (_ for _ in ()).throw(RuntimeError("device locked")),
    )

    result = provision.regenerate_profile("com.example.Demo", "deadbeef")

    assert result["profile_path"] == str(fresh_profile)