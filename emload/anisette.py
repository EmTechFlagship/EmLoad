"""Anisette provider.

Anisette headers are the device-provisioning data Apple's GrandSlam (GSA) servers
require to authenticate an Apple ID from a non-Apple machine. EmLoad generates
them fully in-process using the pure-Python ``Anisette`` package, which runs
Apple's own portable provisioning libraries.

Those libraries (about 2 MB, arm64, emulated regardless of host CPU) are fetched
once from a public host and then cached with the provisioning state in a single
file, so the machine presents as a stable, already-provisioned device on every
run - re-provisioning repeatedly is what trips Apple's anti-abuse checks.

Apple's wire protocol also demands that header values stay ASCII (HTTP headers
are latin-1). Windows locale/timezone display names are localized, so we map
them to Apple-style tags/offsets here, at the single place every caller goes
through.
"""

from __future__ import annotations

import io
import locale
import re
import warnings
from datetime import datetime, timedelta, timezone
from importlib import metadata
from typing import Any

import requests

from . import paths
from .errors import EmLoadError


class AnisetteError(EmLoadError):
    """Device provisioning could not be set up (libraries unreachable or state broken)."""


#: Where the provisioning libraries are fetched from, tried in order.
_LIBS_URLS: tuple[str, ...] = (
    "https://anisette.dl.mikealmel.ooo/libs?arch=arm64-v8a",
)

#: The formats the anisette package can read a bundle as. A response that starts
#: with none of these is an error page or a truncated download, not the libraries.
_ARCHIVE_MAGIC = (b"PK", b"\x1f\x8b", b"BZh", b"\xfd7zXZ")

#: Apple-style locale tags look like ``zh_CN`` / ``en_US``.
_APPLE_LOCALE = re.compile(r"^[A-Za-z]{2,3}([_-][A-Za-z0-9]+)+$")

# The Anisette package uses Android's provisioning libraries, so its generated
# client info must not claim to be a Mac. Apple rejects that mismatch (-80045).
_WINDOWS_CLIENT_INFO = (
    "<PC> <Windows;6.2(0,0);9200> "
    "<com.apple.AuthKit/1 (com.apple.akd/1.0)>"
)


def _download_libs() -> io.BytesIO:
    """Fetch Apple's provisioning libraries, trying each source with retries."""
    attempts: list[str] = []
    for url in _LIBS_URLS:
        for _ in range(3):
            try:
                response = requests.get(url, timeout=30)
                response.raise_for_status()
                data = response.content
                if not any(data.startswith(magic) for magic in _ARCHIVE_MAGIC):
                    raise ValueError(
                        f"response was not an archive (starts {data[:12]!r})"
                    )
                return io.BytesIO(data)
            except Exception as exc:  # noqa: BLE001 - record every source that failed
                attempts.append(f"{url}: {exc}")
    raise AnisetteError(
        "Could not download Apple's device-provisioning libraries. The provisioning "
        "server may be down, or your network is blocking it - check your connection "
        "and try again.\n\nTried:\n  " + "\n  ".join(attempts)
    )


def _load_provider() -> Any:
    """Return a ready, provisioned Anisette provider, persisting its state.

    A cache that cannot be loaded is discarded and rebuilt rather than re-raised:
    an interrupted first provision would otherwise throw the same archive error on
    every later launch with no way out but deleting the file by hand.
    """
    from anisette import Anisette

    state = paths.anisette_state_file()

    def _fresh() -> Any:
        return Anisette.init(_download_libs())

    if state.exists():
        try:
            provider = Anisette.load(str(state))
        except AnisetteError:
            raise
        except Exception:  # noqa: BLE001 - any load failure means the cache is unusable
            state.unlink(missing_ok=True)
            provider = _fresh()
    else:
        provider = _fresh()

    if not provider.is_provisioned:
        provider.provision()

    provider.save_all(str(state))
    return provider


def _gmt_offset_label(offset: timedelta) -> str:
    """Format a UTC offset the way Apple clients do: ``GMT+02:00``."""
    total = int(offset.total_seconds())
    sign = "+" if total >= 0 else "-"
    total = abs(total)
    hours, rem = divmod(total, 3600)
    minutes = rem // 60
    return f"GMT{sign}{hours:02d}:{minutes:02d}"


def ascii_timezone(now: datetime | None = None) -> str:
    """Timezone label safe to put on an HTTP header (ASCII, Apple-style)."""
    when = now if now is not None else datetime.now().astimezone()
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)

    name = when.tzname() or ""
    if name.isascii() and name.strip():
        return name.strip()

    offset = when.utcoffset()
    if offset is None:
        return "GMT"
    return _gmt_offset_label(offset)


#: Windows ``getlocale()`` display names -> Apple's locale identifiers.
_WINDOWS_LOCALE_TO_APPLE: dict[str, str] = {
    "chinese (simplified)_china": "zh_CN",
    "chinese (simplified)_singapore": "zh_SG",
    "chinese (traditional)_taiwan": "zh_TW",
    "chinese (traditional)_hong kong s.a.r.": "zh_HK",
    "chinese (traditional)_hong kong sar": "zh_HK",
    "chinese (traditional)_macao s.a.r.": "zh_MO",
    "chinese_china": "zh_CN",
    "chinese_taiwan": "zh_TW",
    "english_united states": "en_US",
    "english_united kingdom": "en_GB",
    "english_india": "en_IN",
    "english_australia": "en_AU",
    "english_canada": "en_CA",
    "japanese_japan": "ja_JP",
    "korean_korea": "ko_KR",
    "german_germany": "de_DE",
    "french_france": "fr_FR",
    "french_canada": "fr_CA",
    "spanish_spain": "es_ES",
    "spanish_mexico": "es_MX",
    "portuguese_brazil": "pt_BR",
    "portuguese_portugal": "pt_PT",
    "russian_russia": "ru_RU",
    "italian_italy": "it_IT",
    "dutch_netherlands": "nl_NL",
    "polish_poland": "pl_PL",
    "turkish_turkey": "tr_TR",
    "thai_thailand": "th_TH",
    "vietnamese_vietnam": "vi_VN",
    "arabic_saudi arabia": "ar_SA",
    "hindi_india": "hi_IN",
}


def _apple_locale_tag(value: str) -> str | None:
    """Return an Apple-style locale tag for ``value``, or None if it cannot be mapped."""
    if not value or not value.isascii():
        return None
    cleaned = value.strip().replace("-", "_")
    if _APPLE_LOCALE.fullmatch(cleaned):
        parts = cleaned.split("_")
        if len(parts) >= 2 and len(parts[1]) == 2:
            parts[1] = parts[1].upper()
        parts[0] = parts[0].lower()
        return "_".join(parts)
    return _WINDOWS_LOCALE_TO_APPLE.get(value.strip().lower())


def ascii_locale(preferred: str | None = None) -> str:
    """Locale tag Apple's GrandSlam endpoints accept (``zh_CN`` / ``en_US``)."""
    candidates: list[str] = []
    if preferred:
        candidates.append(preferred)
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            default = locale.getdefaultlocale()[0]
    except Exception:  # noqa: BLE001 - locale stack varies by platform
        default = None
    if default:
        candidates.append(default)
    try:
        current = locale.getlocale()[0]
    except Exception:  # noqa: BLE001
        current = None
    if current:
        candidates.append(current)

    for candidate in candidates:
        mapped = _apple_locale_tag(candidate)
        if mapped:
            return mapped
    return "en_US"


def _wire_safe_headers(raw: dict[str, Any]) -> dict[str, Any]:
    """Rewrite anisette fields that must be both latin-1-safe and Apple-accepted."""
    headers = dict(raw)
    headers["X-Apple-I-TimeZone"] = ascii_timezone()
    existing_locale = headers.get("X-Apple-Locale")
    headers["X-Apple-Locale"] = ascii_locale(
        existing_locale if isinstance(existing_locale, str) else None
    )
    headers["X-MMe-Client-Info"] = _WINDOWS_CLIENT_INFO
    return headers


def get_headers() -> dict[str, Any]:
    """Return a fresh set of anisette headers for a GSA request."""
    provider = _load_provider()
    return _wire_safe_headers(dict(provider.get_data()))


def status() -> dict[str, Any]:
    """Report anisette readiness without forcing provisioning."""
    try:
        version: str | None = metadata.version("Anisette")
    except metadata.PackageNotFoundError:
        version = None
    state = paths.anisette_state_file()
    return {
        "available": version is not None,
        "package_version": version,
        "state_cached": state.exists(),
        "state_path": str(state),
    }