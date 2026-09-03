"""Apple Developer Services client (developerservices2.apple.com).

Uses the scoped Xcode token minted by :mod:`emload.gsa` to drive the same
private developer-portal API Xcode uses: list the team, issue a development
certificate from a CSR, register the device, create/reuse an App ID, and
download a provisioning profile. These are the steps that let a free Apple ID
sign an app for a specific device.

All requests are plist-over-HTTPS POSTs carrying an Xcode identity (clientId +
protocolVersion) plus anisette and the GS token, verified against the pinned
Apple CA bundle.
"""

from __future__ import annotations

import plistlib
import uuid
from typing import Any

import requests

from . import anisette, gsa, tls
from .errors import EmLoadError

_BASE = "https://developerservices2.apple.com/services/QH65B2/"
_CLIENT_ID = "XABBG36SBA"
_PROTOCOL_VERSION = "QH65B2"
_USER_AGENT = "Xcode"
_XCODE_VERSION = "11.2 (11B41)"
_APP_INFO = "com.apple.gs.xcode.auth"
_TIMEOUT = 30


class DeveloperServicesError(EmLoadError):
    """Raised when developerservices2 returns a non-zero result code."""


def _headers(session: dict[str, Any], anisette_headers: dict[str, str]) -> dict[str, str]:
    headers = {
        "Content-Type": "text/x-xml-plist",
        "User-Agent": _USER_AGENT,
        "Accept": "text/x-xml-plist",
        "Accept-Language": "en-us",
        "X-Apple-App-Info": _APP_INFO,
        "X-Xcode-Version": _XCODE_VERSION,
        "X-Apple-I-Identity-Id": session["adsid"],
        "X-Apple-GS-Token": session["auth_token"],
        "X-Apple-I-Locale": anisette_headers.get("X-Apple-Locale", "en_US"),
    }
    headers.update(anisette_headers)
    return headers


def _request(
    endpoint: str, params: dict[str, Any] | None = None, team_id: str | None = None
) -> dict[str, Any]:
    """POST a plist request to a developerservices2 endpoint and parse the result."""
    session = gsa.load_session()
    body: dict[str, Any] = {
        "clientId": _CLIENT_ID,
        "protocolVersion": _PROTOCOL_VERSION,
        "requestId": str(uuid.uuid4()).upper(),
    }
    if team_id:
        body["teamId"] = team_id
    if params:
        body.update(params)

    resp = requests.post(
        f"{_BASE}{endpoint}?clientId={_CLIENT_ID}",
        headers=_headers(session, anisette.get_headers()),
        data=plistlib.dumps(body),
        timeout=_TIMEOUT,
        verify=tls.ca_bundle(),
    )
    resp.raise_for_status()
    result = plistlib.loads(resp.content)

    result_code = result.get("resultCode")
    if result_code not in (0, None, "0"):
        message = result.get("userString") or result.get("resultString") or "unknown error"
        raise DeveloperServicesError(f"{result_code}: {message}")
    return result


def list_teams() -> list[dict[str, Any]]:
    """Return the development teams available to the signed-in account."""
    result = _request("listTeams.action")
    return result.get("teams", [])


def _sanitize_name(name: str) -> str:
    """Apple requires App ID / device names to be alphanumeric + spaces."""
    cleaned = "".join(ch for ch in name if ch.isalnum() or ch == " ").strip()
    return cleaned or "EmLoad"


# --------------------------------------------------------------------------- #
# Devices
# --------------------------------------------------------------------------- #
def list_devices(team_id: str) -> list[dict[str, Any]]:
    return _request("ios/listDevices.action", team_id=team_id).get("devices", [])


def register_device(team_id: str, udid: str, name: str = "EmLoad device") -> dict[str, Any]:
    result = _request(
        "ios/addDevice.action",
        {"deviceNumber": udid, "name": _sanitize_name(name)},
        team_id=team_id,
    )
    return result.get("device", {})


# --------------------------------------------------------------------------- #
# Certificates
# --------------------------------------------------------------------------- #
def list_certificates(team_id: str) -> list[dict[str, Any]]:
    result = _request("ios/listAllDevelopmentCerts.action", team_id=team_id)
    return result.get("certificates", [])


def submit_csr(team_id: str, csr_pem: str, machine_name: str = "EmLoad") -> dict[str, Any]:
    result = _request(
        "ios/submitDevelopmentCSR.action",
        {"csrContent": csr_pem, "machineId": str(uuid.uuid4()), "machineName": machine_name},
        team_id=team_id,
    )
    return result.get("certRequest", {})


def revoke_certificate(team_id: str, serial_number: str) -> None:
    _request(
        "ios/revokeDevelopmentCert.action",
        {"serialNumber": serial_number},
        team_id=team_id,
    )


# --------------------------------------------------------------------------- #
# App IDs
# --------------------------------------------------------------------------- #
def list_app_ids(team_id: str) -> list[dict[str, Any]]:
    return _request("ios/listAppIds.action", team_id=team_id).get("appIds", [])


def add_app_id(team_id: str, bundle_id: str, name: str) -> dict[str, Any]:
    result = _request(
        "ios/addAppId.action",
        {"identifier": bundle_id, "name": _sanitize_name(name)},
        team_id=team_id,
    )
    return result.get("appId", {})


def delete_app_id(team_id: str, app_id_id: str) -> None:
    """Delete a registered App ID, freeing one of a free account's 10 weekly slots."""
    _request("ios/deleteAppId.action", {"appIdId": app_id_id}, team_id=team_id)


# --------------------------------------------------------------------------- #
# Provisioning profiles
# --------------------------------------------------------------------------- #
def download_profile(team_id: str, app_id_id: str) -> dict[str, Any]:
    result = _request(
        "ios/downloadTeamProvisioningProfile.action",
        {"appIdId": app_id_id},
        team_id=team_id,
    )
    return result.get("provisioningProfile", {})