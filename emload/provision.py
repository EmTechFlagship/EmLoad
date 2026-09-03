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
import json
from typing import Any, Callable

from cryptography import x509
from cryptography.hazmat.primitives import serialization

from . import developer, gsa, paths, signing

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
    revoke_failure: Exception | None = None
    for cert in server_certs:
        serial = cert.get("serialNumber")
        if serial and cert.get("machineName") == CERTIFICATE_MACHINE_NAME:
            try:
                developer.revoke_certificate(team_id, serial)
            except developer.DeveloperServicesError as exc:
                revoke_failure = exc

    key_pem, csr_pem = signing.generate_key_and_csr()
    try:
        developer.submit_csr(team_id, csr_pem, machine_name=CERTIFICATE_MACHINE_NAME)
    except developer.DeveloperServicesError as exc:
        if revoke_failure is not None:
            raise gsa.GsaError(
                f"Apple would not issue a signing certificate ({exc}), and the old "
                f"EmLoad certificate could not be revoked to make room for it "
                f"({revoke_failure}). Revoking it in the Apple Developer portal, under "
                "Certificates, will let this succeed."
            ) from exc
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