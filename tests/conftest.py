"""Shared pytest fixtures: isolate all state in a temp dir."""

from __future__ import annotations

import pytest

import emload.paths as paths


@pytest.fixture(autouse=True)
def isolated_data_dir(tmp_path, monkeypatch):
    """Point every paths.* helper at a throwaway directory per test."""
    data = tmp_path / "data"
    data.mkdir()
    monkeypatch.setattr(paths, "data_dir", lambda: data)
    yield data


@pytest.fixture
def sample_ipa(tmp_path):
    """Build a small synthetic IPA (Payload/<App>.app with Info.plist + binary)."""
    import plistlib
    import zipfile

    payload = tmp_path / "Payload" / "Demo.app"
    payload.mkdir(parents=True)
    info = {
        "CFBundleIdentifier": "com.example.Demo",
        "CFBundleDisplayName": "Demo App",
        "CFBundleName": "Demo",
        "CFBundleExecutable": "Demo",
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "4",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "UIDeviceFamily": [1, 2],
        "MinimumOSVersion": "13.0",
    }
    (payload / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    (payload / "Demo").write_bytes(b"\xcf\xfa\xed\xfe" + b"\x00" * 64)
    (payload / "AppIcon60x60@2x.png").write_bytes(
        b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
    )
    ipa = tmp_path / "demo.ipa"
    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as zf:
        for file in (payload / "Info.plist", payload / "Demo", payload / "AppIcon60x60@2x.png"):
            zf.write(file, file.relative_to(tmp_path).as_posix())
    return str(ipa)