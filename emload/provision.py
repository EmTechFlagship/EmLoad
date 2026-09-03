"""Provisioning orchestration.

Turns an authenticated session into everything zsign needs to sign an app for a
specific device on a free (or paid) Apple ID:

1. a development certificate (generate key + CSR, submit, cache),
2. the target device registered to the team,
3. an App ID for the app's bundle identifier,
4. a provisioning profile binding the cert + device + App ID.

The private key never leaves this machine; the resulting PKCS#12 + profile are
cached under the per-user signing directory and reused until they expire (free
profiles last 7 days), so repeat signs don't burn Apple's rate limits.
"""

from __future__ import annotations

import base64
import io
import json
import plistlib
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from cryptography import x509
from cryptography.hazmat.primitives import serialization

from . import developer, device, gsa, lockdown, paths, signing
from ._asyncutil import maybe_await, run
from .errors import EmLoadError

_CERT_CACHE = "certificate.json"
_BUNDLE_CACHE = "bundle.json"
_IDENTITY_P12 = "identity.p12"
_PROFILE = "profile.mobileprovision"

#: The machine name EmLoad registers its certificates under.
#:
#: Load-bearing rather than cosmetic: Apple's per-machine certificate limit is what
#: lets one account hold a certificate for Xcode, another for SideStore, and this
#: one at the same time, so it is also how a re-issue tells ours apart from theirs.
CERTIFICATE_MACHINE_NAME = "EmLoad"

#: Pause before retrying a certificate submission after revoking, to give Apple's
#: revocation time to propagate (revoking and submitting back-to-back is what trips
#: error 7460 "you already have a current iOS Development certificate").
_REVOKE_RETRY_DELAY = 2.0


def _account_slug(email: str | None) -> str | None:
    return paths.account_slug(email) if email else None


def load_bundle() -> dict[str, Any]:
    """Return the cached signing bundle from a prior provision, or raise."""
    session = gsa.load_session()
    path = paths.signing_dir(_account_slug(session.get("email"))) / _BUNDLE_CACHE
    if not path.exists():
        raise gsa.GsaError("no signing bundle; run 'emload provision' first")
    return json.loads(path.read_text(encoding="utf-8"))


def signing_identity() -> tuple[bytes, bytes, str]:
    """Return ``(private_key_pem, certificate_der, serial)`` for the active account."""
    session = gsa.load_session()
    cache = paths.signing_dir(_account_slug(session.get("email"))) / _CERT_CACHE
    if not cache.exists():
        raise gsa.GsaError("no signing certificate cached; run 'emload provision' first")
    cached = json.loads(cache.read_text(encoding="utf-8"))
    return (
        base64.b64decode(cached["key_pem"]),
        base64.b64decode(cached["cert_der"]),
        cached["serial"],
    )


def team_scoped_bundle_id(base_bundle_id: str) -> str:
    """Return a bundle id guaranteed registerable on a free account.

    A free Apple ID cannot register a real App Store app's identifier (Apple
    returns error 9401 "not available"). Appending the team id makes it unique
    and always registerable, which is why every free-account signing flow does it.
    """
    team_id = developer.list_teams()[0]["teamId"]
    if base_bundle_id.lower().endswith("." + team_id.lower()):
        return base_bundle_id
    return f"{base_bundle_id}.{team_id}"


def _normalize_udid(udid: str) -> str:
    return udid.replace("-", "").lower()


def _cert_content(cert: dict[str, Any]) -> bytes | None:
    """Pull the DER certificate bytes out of a portal cert dict (varied shapes)."""
    for key in ("certContent", "certificateContent", "certificate"):
        value = cert.get(key)
        if isinstance(value, (bytes, bytearray)):
            return bytes(value)
        if isinstance(value, dict):
            inner = value.get("certContent") or value.get("certificateContent")
            if isinstance(inner, (bytes, bytearray)):
                return bytes(inner)
    return None


def _public_key_der(obj: Any) -> bytes:
    return obj.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )


def _find_cert_for_key(certs: list[dict[str, Any]], key_pem: bytes) -> tuple[bytes | None, str | None]:
    """Return (der, serial) for the certificate matching our private key's public key."""
    my_public = _public_key_der(serialization.load_pem_private_key(key_pem, password=None))
    for cert in certs:
        content = _cert_content(cert)
        if not content:
            continue
        try:
            parsed = x509.load_der_x509_certificate(content)
        except ValueError:
            continue
        if _public_key_der(parsed) == my_public:
            return content, cert.get("serialNumber")
    return None, None


def _is_certificate_limit_error(exc: Exception) -> bool:
    """True for Apple error 7460: a current cert or pending request is blocking.

    The message text travels inside a ``DeveloperServicesError`` formatted as
    ``7460: You already have a current iOS Development certificate or a pending
    certificate request.``
    """
    text = str(exc).lower()
    return "7460" in text or "already have a current" in text


def _revoke_emload_certs(team_id: str, server_certs: list[dict[str, Any]]) -> Exception | None:
    """Revoke every certificate this machine registered (``machineName`` = ours).

    Returns the first revocation failure, or None when everything revoked. Only
    ever touches certificates whose machine name is ours - never Xcode's or
    SideStore's, because revoking those stops every app they signed.
    """
    revoke_failure: Exception | None = None
    for cert in server_certs:
        serial = cert.get("serialNumber")
        if serial and cert.get("machineName") == CERTIFICATE_MACHINE_NAME:
            try:
                developer.revoke_certificate(team_id, serial)
            except developer.DeveloperServicesError as exc:
                revoke_failure = exc
    return revoke_failure


def _ensure_certificate(team_id: str, account_slug: str | None) -> tuple[bytes, bytes, str]:
    """Return (private_key_pem, certificate_der, serial), creating one if needed.

    The key cache is per account: shared, a second Apple ID would find the first
    one's key, fail to match it against its own team's certificates, and respond by
    revoking a certificate - breaking every app that had signed.

    Re-issuing only ever revokes a certificate EmLoad itself registered; see
    :data:`CERTIFICATE_MACHINE_NAME`.
    """
    cache_path = paths.signing_dir(account_slug) / _CERT_CACHE
    server_certs = developer.list_certificates(team_id)
    if cache_path.exists():
        cached = json.loads(cache_path.read_text(encoding="utf-8"))
        serial = cached.get("serial")
        if any(c.get("serialNumber") == serial for c in server_certs):
            return (
                base64.b64decode(cached["key_pem"]),
                base64.b64decode(cached["cert_der"]),
                serial,
            )

    # We need to issue a new certificate, and the account has limited room for them,
    # so an old one has to go. Only ever one of *ours* - not certificates Xcode or
    # SideStore registered (revoking those would stop every app they signed).
    revoke_failure = _revoke_emload_certs(team_id, server_certs)

    key_pem, csr_pem = signing.generate_key_and_csr()
    try:
        developer.submit_csr(team_id, csr_pem, machine_name=CERTIFICATE_MACHINE_NAME)
    except developer.DeveloperServicesError as exc:
        if not _is_certificate_limit_error(exc):
            if revoke_failure is not None:
                raise gsa.GsaError(
                    f"Apple would not issue a signing certificate ({exc}), and the old "
                    f"EmLoad certificate could not be revoked to make room for it "
                    f"({revoke_failure}). Revoking it in the Apple Developer portal, under "
                    "Certificates, will let this succeed."
                ) from exc
            raise

        # Error 7460: a current certificate or a *pending certificate request*
        # is in the way. A revocation can take a moment to propagate, and a
        # crashed earlier run can leave a pending request behind, so revoke
        # anything of ours again (including entries that only just went pending)
        # and try the submission once more.
        time.sleep(_REVOKE_RETRY_DELAY)
        try:
            revoke_failure = (
                _revoke_emload_certs(team_id, developer.list_certificates(team_id))
                or revoke_failure
            )
            developer.submit_csr(team_id, csr_pem, machine_name=CERTIFICATE_MACHINE_NAME)
        except developer.DeveloperServicesError as retry_exc:
            if revoke_failure is not None:
                raise gsa.GsaError(
                    f"Apple would not issue a signing certificate ({retry_exc}), and the "
                    f"old EmLoad certificate could not be revoked to make room for it "
                    f"({revoke_failure}). Revoking it in the Apple Developer portal, under "
                    "Certificates, will let this succeed."
                ) from retry_exc
            raise
    cert_der, serial = _find_cert_for_key(developer.list_certificates(team_id), key_pem)
    if cert_der is None:
        raise gsa.GsaError("could not obtain certificate content from Apple")

    cache_path.write_text(
        json.dumps(
            {
                "serial": serial,
                "key_pem": base64.b64encode(key_pem).decode(),
                "cert_der": base64.b64encode(cert_der).decode(),
            }
        ),
        encoding="utf-8",
    )
    return key_pem, cert_der, serial


def _ensure_device(team_id: str, udid: str, name: str) -> None:
    target = _normalize_udid(udid)
    for existing in developer.list_devices(team_id):
        if _normalize_udid(existing.get("deviceNumber", "")) == target:
            return
    try:
        developer.register_device(team_id, udid, name)
    except developer.DeveloperServicesError as exc:
        if "already exist" not in str(exc).lower():
            raise


def _ensure_app_id(team_id: str, bundle_id: str, name: str) -> dict[str, Any]:
    for existing in developer.list_app_ids(team_id):
        if existing.get("identifier") == bundle_id:
            return existing
    try:
        return developer.add_app_id(team_id, bundle_id, name)
    except developer.DeveloperServicesError:
        for existing in developer.list_app_ids(team_id):
            if existing.get("identifier") == bundle_id:
                return existing
        raise


def ensure_signing_assets(
    bundle_id: str,
    udid: str,
    app_name: str = "EmLoad App",
    device_name: str = "EmLoad device",
    on_step: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    """Provision cert + device + App ID + profile and cache a signing bundle."""
    step = on_step or (lambda _m: None)
    step("Contacting Apple\u2026")
    session = gsa.load_session()  # raises if not signed in
    account = session.get("email")
    team = developer.list_teams()[0]
    team_id = team["teamId"]
    # Remember which team this Apple ID provisions under, so a later refresh can
    # find its way back to the right account instead of using whichever is active.
    if account:
        gsa.remember_team(account, team_id)

    step("Preparing signing certificate\u2026")
    key_pem, cert_der, serial = _ensure_certificate(team_id, _account_slug(account))
    step("Registering your device\u2026")
    _ensure_device(team_id, udid, device_name)
    step("Creating the App ID\u2026")
    app_id = _ensure_app_id(team_id, bundle_id, app_name)
    app_id_id = app_id.get("appIdId") or app_id.get("appIdPlatform") or app_id.get("identifier")

    step("Fetching the provisioning profile\u2026")
    profile = developer.download_profile(team_id, app_id_id)
    profile_data = profile.get("encodedProfile")
    if not isinstance(profile_data, (bytes, bytearray)):
        raise gsa.GsaError("provisioning profile download did not return profile data")

    signing_dir = paths.signing_dir(_account_slug(account))
    p12_path = signing_dir / _IDENTITY_P12
    profile_path = signing_dir / _PROFILE
    p12_path.write_bytes(signing.build_p12(cert_der, key_pem))
    profile_path.write_bytes(bytes(profile_data))

    bundle = {
        "team_id": team_id,
        "team_name": team.get("name"),
        "account": account,
        "bundle_id": bundle_id,
        "app_id_id": app_id_id,
        "certificate_serial": serial,
        "udid": udid,
        "p12_path": str(p12_path),
        "p12_password": signing.P12_PASSWORD,
        "profile_path": str(profile_path),
    }
    (signing_dir / _BUNDLE_CACHE).write_text(json.dumps(bundle, indent=2), encoding="utf-8")
    return bundle


def ensure_provisioned_for_device(
    udid: str,
    on_step: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    """Make the cached signing assets serve ``udid``, provisioning it if needed.

    Called when a device plugs in. The development certificate is *not*
    device-specific - one certificate signs for every device on the team - but a
    provisioning profile is: it lists the devices it covers. So when a different
    device shows up we keep the certificate (revoking and re-issuing it per device
    is what trips Apple error 7460 "you already have a current iOS Development
    certificate"), register the new device, fetch a fresh profile for the same App
    ID, and install it on the device.

    Safe to call on every attach: returns immediately (no network calls) when
    there is no signed-in account, nothing cached yet, or the cache already
    matches the device.
    """
    step = on_step or (lambda _m: None)
    try:
        gsa.load_session()
    except gsa.GsaError:
        return {"status": "not_signed_in"}
    try:
        bundle = load_bundle()
    except gsa.GsaError:
        return {"status": "no_cached_bundle"}

    if _normalize_udid(bundle.get("udid") or "") == _normalize_udid(udid):
        return {"status": "up_to_date", "udid": udid}

    bundle_id = bundle.get("bundle_id")
    if not bundle_id:
        return {"status": "no_cached_bundle"}

    device_name = "EmLoad device"
    try:
        info = device.get_device_info(udid)
        device_name = str(info.get("DeviceName") or device_name)
    except Exception:  # noqa: BLE001 - cosmetic; provisioning matters more
        pass

    # Reuses the cached certificate when it is still valid, so plugging in a
    # device only re-registers it and re-downloads the profile - no new cert.
    fresh = ensure_signing_assets(
        bundle_id,
        udid,
        app_name=bundle.get("name") or "EmLoad App",
        device_name=device_name,
        on_step=step,
    )

    profile_bytes = Path(fresh["profile_path"]).read_bytes()
    summary = profile_summary(profile_bytes)
    result: dict[str, Any] = {
        "status": "reprovisioned",
        "udid": udid,
        "device_name": device_name,
        "team_id": fresh.get("team_id"),
        "bundle_id": fresh["bundle_id"],
        "expires_at": summary["expires_at"],
        "profile_installed": False,
    }
    try:
        install_profile(udid, profile_bytes)
    except Exception as exc:  # noqa: BLE001 - the cache is already fresh; report and move on
        result["warning"] = (
            f"Fresh certificate + profile are ready, but the profile could not be "
            f"installed on the device: {exc}"
        )
        return result
    result["profile_installed"] = True
    return result


# --------------------------------------------------------------------------- #
# Installing a profile on a device
# --------------------------------------------------------------------------- #
def profile_plist(profile_bytes: bytes) -> dict[str, Any]:
    """The plist embedded inside a ``.mobileprovision`` (CMS-wrapped), or {}.

    Same slicing trick the registry's expiry reader uses: the CMS wrapper is
    opaque, but the signed payload inside is a plain XML plist we can read.
    """
    start = profile_bytes.find(b"<?xml")
    end = profile_bytes.find(b"</plist>")
    if start == -1 or end == -1:
        return {}
    try:
        plist = plistlib.loads(profile_bytes[start : end + len(b"</plist>")])
        return plist if isinstance(plist, dict) else {}
    except Exception:  # noqa: BLE001 - malformed profile, nothing worth parsing
        return {}


def profile_summary(profile_bytes: bytes) -> dict[str, Any]:
    """Name/UUID/expiry/team details from a ``.mobileprovision``, for display."""
    plist = profile_plist(profile_bytes)
    expiry = plist.get("ExpirationDate")
    if isinstance(expiry, datetime) and expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=timezone.utc)
    return {
        "name": plist.get("Name"),
        "uuid": str(plist.get("UUID") or "").upper(),
        "app_id": plist.get("ApplicationIdentifier"),
        "team": ", ".join(plist.get("TeamIdentifier") or []),
        "expires_at": expiry.isoformat() if isinstance(expiry, datetime) else None,
        "device_count": len(plist.get("ProvisionedDevices") or []),
    }


async def _install_profile_async(udid: str, profile_bytes: bytes) -> None:
    from pymobiledevice3.services.misagent import MisagentService

    client = await lockdown.create(udid)
    try:
        misagent = MisagentService(lockdown=client)
        try:
            await maybe_await(misagent.install(io.BytesIO(profile_bytes)))
        finally:
            await maybe_await(misagent.close())
    finally:
        await lockdown.close(client)


def install_profile(udid: str, profile_bytes: bytes) -> dict[str, Any]:
    """Install a provisioning profile file onto a connected device.

    Uses the ``com.apple.misagent`` service - the same one Xcode's Devices window
    writes profiles with. The profile must belong to the device (its UDID must be
    in ``ProvisionedDevices``) or the device refuses it.
    """
    run(_install_profile_async(udid, profile_bytes))
    return profile_summary(profile_bytes)


class ProvisionDeviceError(EmLoadError):
    """Listed/removing provisioning profiles on a device did not work."""


async def _list_profiles_async(udid: str) -> list[dict[str, Any]]:
    from pymobiledevice3.services.misagent import MisagentService

    client = await lockdown.create(udid)
    try:
        misagent = MisagentService(lockdown=client)
        try:
            profiles = await maybe_await(misagent.copy_all())
        finally:
            await maybe_await(misagent.close())
    finally:
        await lockdown.close(client)

    rows: list[dict[str, Any]] = []
    for profile in profiles or []:
        raw = getattr(profile, "buf", None)
        if not isinstance(raw, (bytes, bytearray)):
            continue
        raw = bytes(raw)
        plist = profile_plist(raw)
        rows.append(
            {
                **profile_summary(raw),
                "app_id_name": plist.get("AppIDName"),
                "team_name": plist.get("TeamName"),
            }
        )
    return rows


def list_profiles(udid: str | None = None) -> list[dict[str, Any]]:
    """Every provisioning profile installed on the device, one dict each."""
    target = device.resolve_serial(udid)
    try:
        return run(_list_profiles_async(target))
    except EmLoadError:
        raise
    except Exception as exc:  # noqa: BLE001 - wrap driver-level failures readably
        raise ProvisionDeviceError(
            f"Could not list provisioning profiles on {target}: {exc}"
        ) from exc


async def _remove_profile_async(udid: str, profile_uuid: str) -> None:
    from pymobiledevice3.services.misagent import MisagentService

    client = await lockdown.create(udid)
    try:
        misagent = MisagentService(lockdown=client)
        try:
            await maybe_await(misagent.remove(profile_uuid))
        finally:
            await maybe_await(misagent.close())
    finally:
        await lockdown.close(client)


def remove_profile(profile_uuid: str, udid: str | None = None) -> dict[str, Any]:
    """Remove one installed provisioning profile by its UUID."""
    target = device.resolve_serial(udid)
    try:
        run(_remove_profile_async(target, profile_uuid))
    except EmLoadError:
        raise
    except Exception as exc:  # noqa: BLE001 - wrap driver-level failures readably
        raise ProvisionDeviceError(
            f"Could not remove profile {profile_uuid} from {target}: {exc}"
        ) from exc
    return {"uuid": profile_uuid, "removed": True, "udid": target}


def clear_profiles(udid: str | None = None) -> dict[str, Any]:
    """Remove every provisioning profile installed on the device."""
    target = device.resolve_serial(udid)
    profiles = list_profiles(target)
    failures: list[str] = []
    removed = 0
    for profile in profiles:
        uuid = profile.get("uuid")
        if not uuid:
            continue
        try:
            remove_profile(uuid, target)
        except Exception as exc:  # noqa: BLE001 - keep going; count what failed
            failures.append(f"{uuid}: {exc}")
            continue
        removed += 1
    result = {"removed": removed, "udid": target, "total": len(profiles)}
    if failures:
        result["failed"] = failures
    return result


def provision_device(
    bundle_id: str,
    udid: str | None = None,
    app_name: str = "EmLoad App",
    on_step: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    """Provision the signed-in team's assets, then install the profile on a device.

    One command for "the phone is plugged in and I'm signed in": register the
    device, get the team's development certificate, create the App ID, download
    its provisioning profile, and hand that profile to the device so the phone
    carries it even before (or without) installing an app.

    Requires a connected device and a signed-in Apple ID; the error messages name
    exactly which condition failed.
    """
    step = on_step or (lambda _m: None)
    step("Locating your device\u2026")
    target = device.resolve_serial(udid)  # raises DeviceError when nothing is plugged in
    step("Signing in\u2026")
    gsa.load_session()  # raises GsaError when no account is logged in

    step("Reading the device identity\u2026")
    device_name = "EmLoad device"
    try:
        info = device.get_device_info(target)
        device_name = str(info.get("DeviceName") or device_name)
    except Exception:  # noqa: BLE001 - name is cosmetic; provisioning matters more
        pass

    step("Provisioning with Apple\u2026")
    bundle = ensure_signing_assets(
        bundle_id,
        target,
        app_name=app_name,
        device_name=device_name,
        on_step=step,
    )

    step(f"Installing the profile on {device_name}\u2026")
    profile_bytes = Path(bundle["profile_path"]).read_bytes()
    summary = install_profile(target, profile_bytes)

    return {
        "status": "installed",
        "udid": target,
        "device_name": device_name,
        "team_id": bundle.get("team_id"),
        "bundle_id": bundle["bundle_id"],
        **summary,
    }