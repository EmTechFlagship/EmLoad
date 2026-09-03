"""Tests for IPA inspection and preparation."""

from __future__ import annotations

import plistlib
import zipfile

import pytest

from emload import ipa
from emload.errors import EmLoadError


def test_inspect_fields(sample_ipa):
    info = ipa.inspect(sample_ipa)
    assert info["app_bundle"] == "Demo.app"
    assert info["bundle_id"] == "com.example.Demo"
    assert info["display_name"] == "Demo App"
    assert info["version"] == "1.2.3"
    assert info["build"] == "4"
    assert info["minimum_os"] == "13.0"
    assert info["platform"] == "ios"
    assert info["has_sc_info"] is False
    assert info["extensions"] == []
    assert info["icon"].startswith("data:image/png;base64,")


def test_inspect_missing_file(tmp_path):
    with pytest.raises(EmLoadError, match="Could not find"):
        ipa.inspect(str(tmp_path / "nope.ipa"))


def test_inspect_not_a_zip(tmp_path):
    bad = tmp_path / "bad.ipa"
    bad.write_text("this is not a zip")
    with pytest.raises(EmLoadError, match="not an .ipa"):
        ipa.inspect(str(bad))


def test_inspect_zip_without_payload(tmp_path):
    import zipfile

    bad = tmp_path / "empty.ipa"
    with zipfile.ZipFile(bad, "w") as zf:
        zf.writestr("readme.txt", "hi")
    with pytest.raises(EmLoadError, match="not an .ipa"):
        ipa.inspect(str(bad))


def test_prepare_strips_extensions_and_patches(tmp_path, sample_ipa):
    import shutil

    # Build an IPA with a PlugIns extension and a UISupportedDevices key.
    src = tmp_path / "ext.ipa"
    with zipfile.ZipFile(sample_ipa) as zf:
        names = zf.namelist()
    with zipfile.ZipFile(sample_ipa) as zin, zipfile.ZipFile(src, "w") as zout:
        for name in zin.namelist():
            data = zin.read(name)
            if name.endswith("Info.plist"):
                info = plistlib.loads(data)
                info["UISupportedDevices"] = ["iPhone14,2"]
                data = plistlib.dumps(info, fmt=plistlib.FMT_BINARY)
            zout.writestr(name, data)
        zout.writestr("Payload/Demo.app/PlugIns/Today.appex/Today", b"x")

    out = tmp_path / "prepared.ipa"
    report = ipa.prepare(str(src), str(out))
    assert report["removed"] == ["PlugIns"]
    assert report["info_plist_changes"]["UISupportedDevices"] == "removed"

    with zipfile.ZipFile(out) as zf:
        names = zf.namelist()
        assert not any("PlugIns" in n for n in names)
        info = plistlib.loads(zf.read("Payload/Demo.app/Info.plist"))
        assert "UISupportedDevices" not in info


def test_encrypted_detection(tmp_path):
    # A fake little-endian arm64 Mach-O header with LC_ENCRYPTION_INFO_64 (0x2C).
    import struct

    # header: magic(4) cputype(4) cpusubtype(4) filetype(4) ncmds(4) sizeofcmds(4)
    # flags(4) reserved(4) = 32 bytes
    ncmds = 1
    header = struct.pack(
        "<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 0, ncmds, 64, 0, 0,
    )
    # LC_ENCRYPTION_INFO_64: cmd(4) cmdsize(4) cryptoff(4) cryptsize(4) cryptid(4)
    load = struct.pack("<IIIII", 0x2C, 32, 0, 0, 1)
    macho = tmp_path / "Demo"
    macho.write_bytes(header + load + b"\x00" * 64)
    assert ipa.is_encrypted(macho) is True

    load_clear = struct.pack("<IIIII", 0x2C, 32, 0, 0, 0)
    macho2 = tmp_path / "Demo2"
    macho2.write_bytes(header + load_clear + b"\x00" * 64)
    assert ipa.is_encrypted(macho2) is False


def test_macho_arches(tmp_path):
    import struct

    macho = tmp_path / "bin"
    macho.write_bytes(struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 0, 0, 0, 0, 0))
    assert ipa.macho_arches(macho) == {"arm64"}


def test_deepest_entry(sample_ipa):
    depth = ipa.deepest_entry(sample_ipa)
    assert depth > 0
    assert ipa.deepest_entry(str(tmp_path := __import__("pathlib").Path(sample_ipa).parent / "missing.ipa")) == 0