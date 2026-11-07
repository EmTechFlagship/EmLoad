"""OTA release selection. Network and installers are not contacted."""

from __future__ import annotations

from pathlib import Path

import pytest

from emload import __version__, update
from emload.errors import EmLoadError


def test_version_order_and_pep440():
    versions = [
        "0.1.0-alpha2",
        "0.1.0b4",
        "0.1.0-beta5",
        "0.1.0-beta10",
        "0.1.0-rc1",
        "0.1.0",
        "0.2.0-beta1",
        "v0.2.0",
    ]
    parsed = [update.parse_version(item) for item in versions]
    assert all(parsed)
    for left, right in zip(parsed, parsed[1:]):
        assert left < right
    assert update.parse_version("v0.1.0-beta5") == update.parse_version("0.1.0b5")
    assert update.parse_version("v0.1.0-rc1") == update.parse_version("0.1.0rc1")
    assert update.parse_version("beta") is None


def test_this_release_is_the_first_ota_version():
    assert update.parse_version(__version__) == update.OTA_SINCE
    assert str(update.OTA_SINCE) == "0.1.0-rc1"


def test_a_beta_4_release_is_never_offered():
    only_beta4 = update.parse_releases(
        [
            {
                "tag_name": "v0.1.0-beta4",
                "name": "EmLoad 0.1.0 Beta 4",
                "prerelease": True,
                "draft": False,
                "html_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/tag/v0.1.0-beta4",
                "assets": [
                    {
                        "name": "EmLoad-Setup-0.1.0-beta4.exe",
                        "browser_download_url": (
                            "https://github.com/EmTechFlagship/EmLoadServer/releases/download/"
                            "v0.1.0-beta4/EmLoad-Setup-0.1.0-beta4.exe"
                        ),
                    }
                ],
            }
        ]
    )
    assert (
        update.select_update(
            only_beta4,
            current=update.parse_version("0.1.0-beta1"),
            layout="installed_app",
            platform_name="win32",
            architecture="x64",
        )
        is None
    )
    only_beta5 = update.parse_releases(
        [
            {
                "tag_name": "v0.1.0-beta5",
                "name": "EmLoad 0.1.0 Beta 5",
                "prerelease": True,
                "draft": False,
                "html_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/tag/v0.1.0-beta5",
                "assets": [
                    {
                        "name": "EmLoad-Setup-0.1.0-beta5.exe",
                        "browser_download_url": (
                            "https://github.com/EmTechFlagship/EmLoadServer/releases/download/"
                            "v0.1.0-beta5/EmLoad-Setup-0.1.0-beta5.exe"
                        ),
                    }
                ],
            }
        ]
    )
    assert (
        update.select_update(
            only_beta5,
            current=update.parse_version("0.1.0-beta4"),
            layout="installed_app",
            platform_name="win32",
            architecture="x64",
        )
        is None
    )


def test_ignores_betas_and_picks_the_windows_setup():
    current = update.parse_version("0.1.0-beta5")
    found = update.select_update(
        _releases(),
        current=current,
        layout="installed_app",
        platform_name="win32",
        architecture="x64",
    )
    assert found["version"] == "0.1.0-rc2"
    assert found["asset_name"] == "EmLoad-Setup-0.1.0-rc2.exe"
    assert found["can_apply"] is True
    assert found["prerelease"] is True
    assert "EmLoad-Setup-0.1.0-beta4.exe" not in found["asset_name"]


def test_cli_install_uses_the_cli_setup_not_the_desktop_one():
    found = update.select_update(
        _releases(),
        current=update.OTA_SINCE,
        layout="installed_cli",
        platform_name="win32",
        architecture="x64",
    )
    assert found["asset_name"] == "EmLoad-Cli-Setup-0.1.0-rc2.exe"
    assert found["can_apply"] is True


def test_portable_uses_the_zip_and_source_checkout_does_not_apply():
    portable = update.select_update(
        _releases(),
        current=update.OTA_SINCE,
        layout="portable",
        platform_name="win32",
        architecture="x64",
    )
    assert portable["asset_name"] == "EmLoad-0.1.0-rc2-win-x64.zip"
    assert portable["can_apply"] is True

    source = update.select_update(
        _releases(),
        current=update.OTA_SINCE,
        layout="source",
        platform_name="win32",
        architecture="x64",
    )
    assert source["asset_name"] == "EmLoad-Setup-0.1.0-rc2.exe"
    assert source["can_apply"] is False


def test_macos_prefers_the_cpu_archive_and_does_not_apply_from_python():
    found = update.select_update(
        _releases(),
        current=update.OTA_SINCE,
        layout="source",
        platform_name="darwin",
        architecture="arm64",
    )
    assert found["asset_name"] == "EmLoad-0.1.0-rc2-macos-arm64.zip"
    assert found["can_apply"] is False


def test_untrusted_and_draft_releases_are_skipped():
    payload = [
        {
            "tag_name": "v0.1.0-rc9",
            "name": "Draft",
            "prerelease": True,
            "draft": True,
            "html_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/tag/v0.1.0-rc9",
            "assets": [
                {
                    "name": "EmLoad-Setup-0.1.0-rc9.exe",
                    "browser_download_url": (
                        "https://github.com/EmTechFlagship/EmLoadServer/releases/download/"
                        "v0.1.0-rc9/EmLoad-Setup-0.1.0-rc9.exe"
                    ),
                }
            ],
        },
        {
            "tag_name": "v0.1.0-rc8",
            "name": "Elsewhere",
            "prerelease": True,
            "draft": False,
            "html_url": "https://example.com/evil",
            "assets": [
                {
                    "name": "EmLoad-Setup-0.1.0-rc8.exe",
                    "browser_download_url": "https://example.com/EmLoad-Setup-0.1.0-rc8.exe",
                }
            ],
        },
    ]
    found = update.select_update(
        update.parse_releases(payload),
        current=update.OTA_SINCE,
        layout="installed_app",
        platform_name="win32",
        architecture="x64",
    )
    assert found["version"] == "0.1.0-rc8"
    assert found["download_url"] == ""
    assert found["can_apply"] is False
    assert found["html_url"].startswith("https://github.com/EmTechFlagship/EmLoadServer/releases/tag/")


def test_github_error_object_is_reported():
    with pytest.raises(EmLoadError, match="rate limit"):
        update.parse_releases({"message": "API rate limit exceeded"})


def test_layout_detection(tmp_path: Path):
    assert update.describe_layout(tmp_path) == "source"
    app = tmp_path / "app"
    app.mkdir()
    (app / "EmLoad.WinUI.exe").write_bytes(b"")
    (tmp_path / "unins000.exe").write_bytes(b"")
    assert update.describe_layout(tmp_path) == "installed_app"

    cli = tmp_path / "cli"
    cli.mkdir()
    (cli / "unins000.exe").write_bytes(b"")
    assert update.describe_layout(cli) == "installed_cli"

    portable = tmp_path / "portable"
    portable.mkdir()
    (portable / "EmLoad.WinUI.exe").write_bytes(b"")
    assert update.describe_layout(portable) == "portable"


def test_installer_script_waits_then_runs_setup(tmp_path: Path):
    script = update.render_windows_script(
        mode="installer",
        pids=[100, 200],
        payload=tmp_path / "EmLoad-Setup-0.1.0-rc2.exe",
        install_dir=tmp_path / "EmLoad",
        relaunch=tmp_path / "EmLoad" / "app" / "EmLoad.WinUI.exe",
        log_path=tmp_path / "update.log",
        wait_for_app=True,
    )
    assert "Wait-Pid" in script
    assert "/VERYSILENT" in script
    assert "EmLoad-Setup-0.1.0-rc2.exe" in script
    assert "EmLoad.WinUI" in script
    assert "robocopy" not in script


def test_portable_script_copies_the_zip_and_keeps_the_venv(tmp_path: Path):
    script = update.render_windows_script(
        mode="portable",
        pids=[7],
        payload=tmp_path / "EmLoad-0.1.0-rc2-win-x64.zip",
        install_dir=tmp_path / "portable",
        relaunch=tmp_path / "portable" / "EmLoad.WinUI.exe",
        log_path=tmp_path / "update.log",
        wait_for_app=True,
    )
    assert "Expand-Archive" in script
    assert "/XD .venv" in script
    assert "EmLoad-0.1.0-rc2-win-x64.zip" in script


def test_download_urls_must_be_this_repos_release_assets():
    good = (
        "https://github.com/EmTechFlagship/EmLoadServer/releases/download/"
        "v0.1.0-rc2/EmLoad-Setup-0.1.0-rc2.exe"
    )
    assert update.is_trusted_download(good)
    assert not update.is_trusted_download(good.replace("https", "http"))
    assert not update.is_trusted_download(
        "https://github.com/EmTechFlagship/Other/releases/download/v1/a.exe"
    )
    assert not update.is_trusted_download("https://example.com/a.exe")


def _releases() -> list[dict]:
    return update.parse_releases(
        [
            {
                "tag_name": "v0.1.0-beta4",
                "name": "EmLoad 0.1.0 Beta 4",
                "prerelease": True,
                "draft": False,
                "html_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/tag/v0.1.0-beta4",
                "body": "before OTA",
                "assets": [
                    _asset("EmLoad-Setup-0.1.0-beta4.exe", "v0.1.0-beta4"),
                ],
            },
            {
                "tag_name": "v0.1.0-rc2",
                "name": "EmLoad 0.1.0 RC 2",
                "prerelease": True,
                "draft": False,
                "html_url": "https://github.com/EmTechFlagship/EmLoadServer/releases/tag/v0.1.0-rc2",
                "body": "notes",
                "assets": [
                    _asset("EmLoad-0.1.0-rc2-win-x64.zip", "v0.1.0-rc2"),
                    _asset("EmLoad-Setup-0.1.0-rc2.exe", "v0.1.0-rc2"),
                    _asset("EmLoad-Cli-Setup-0.1.0-rc2.exe", "v0.1.0-rc2"),
                    _asset("EmLoad-0.1.0-rc2-macos.zip", "v0.1.0-rc2"),
                    _asset("EmLoad-0.1.0-rc2-macos-arm64.zip", "v0.1.0-rc2"),
                ],
            },
        ]
    )


def _asset(name: str, tag: str) -> dict[str, str]:
    return {
        "name": name,
        "browser_download_url": (
            f"https://github.com/EmTechFlagship/EmLoadServer/releases/download/{tag}/{name}"
        ),
    }
