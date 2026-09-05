"""Tests for EmStoreServer: IPA resolution, one-shot install, background watch."""

from __future__ import annotations

import threading

import pytest

from emload import server
from emload.errors import EmLoadError


# --------------------------------------------------------------------------- #
# Device-list diffing
# --------------------------------------------------------------------------- #
def test_distinct_serials_dedups_transports():
    entries = [
        {"serial": "AAA", "connection_type": "USB"},
        {"serial": "BBB", "connection_type": "Network"},
        {"serial": "AAA", "connection_type": "Network"},  # same phone, two transports
        {"serial": "", "connection_type": "USB"},
    ]
    assert server.distinct_serials(entries) == ["AAA", "BBB"]


def test_new_serials_only_unseen():
    entries = [{"serial": "AAA"}, {"serial": "BBB"}]
    assert server.new_serials({"AAA"}, entries) == ["BBB"]


# --------------------------------------------------------------------------- #
# Release selection (no network)
# --------------------------------------------------------------------------- #
def _release(name, tag, assets=(), prerelease=False, draft=False):
    return {
        "name": name,
        "tag_name": tag,
        "prerelease": prerelease,
        "draft": draft,
        "assets": [
            {"name": asset, "browser_download_url": f"https://example.com/{asset}"}
            for asset in assets
        ],
    }


def test_select_release_asset_prefers_latest_stable():
    releases = [
        _release("Nightly SideStore Build", "nightly-1", assets=["SideStore.ipa"], prerelease=True),
        _release("Alpha SideStore Build", "alpha-1", assets=["SideStore.ipa"], prerelease=True),
        _release("Stable SideStore Build", "stable-1", assets=["SideStore.ipa"]),
    ]
    release, asset = server._select_release_asset(releases, None)
    assert release["tag_name"] == "stable-1"
    assert asset["name"] == "SideStore.ipa"


def test_select_release_asset_falls_back_to_prerelease():
    releases = [
        _release("Nightly SideStore Build", "nightly-1", assets=["SideStore.ipa"], prerelease=True),
    ]
    release, _asset = server._select_release_asset(releases, None)
    assert release["tag_name"] == "nightly-1"


def test_select_release_asset_channel():
    releases = [
        _release("Nightly SideStore Build", "nightly-1", assets=["SideStore.ipa"], prerelease=True),
        _release("Alpha SideStore Build", "alpha-1", assets=["SideStore.ipa"], prerelease=True),
    ]
    release, _asset = server._select_release_asset(releases, "alpha")
    assert release["tag_name"] == "alpha-1"


def test_select_release_asset_channel_falls_back_to_newest():
    releases = [
        _release("Nightly SideStore Build", "nightly-1", assets=["SideStore.ipa"], prerelease=True),
    ]
    release, _asset = server._select_release_asset(releases, "alpha")
    assert release["tag_name"] == "nightly-1"


def test_select_release_asset_ignores_drafts_and_no_ipa():
    releases = [
        _release("Draft", "draft-1", assets=["SideStore.ipa"], draft=True),
        _release("Nothing", "v1", assets=["SideStore.dSYMs.zip"]),
    ]
    assert server._select_release_asset(releases, None) is None


# --------------------------------------------------------------------------- #
# IPA resolution
# --------------------------------------------------------------------------- #
def test_resolve_ipa_explicit(tmp_path):
    ipa = tmp_path / "EmStore.ipa"
    ipa.write_bytes(b"PK\x03\x04not a real ipa")
    path, source = server.resolve_ipa(str(ipa))
    assert path == ipa.resolve()
    assert source == "explicit"


def test_resolve_ipa_explicit_missing():
    with pytest.raises(EmLoadError, match="No EmStore IPA"):
        server.resolve_ipa(r"C:\definitely\missing.ipa")


def test_resolve_ipa_prefers_local(monkeypatch, tmp_path):
    older, newer = tmp_path / "SideStore.ipa", tmp_path / "EmStore.ipa"
    newer.write_bytes(b"newer")
    monkeypatch.setattr(server, "local_candidates", lambda: [newer, older])
    path, source = server.resolve_ipa()
    assert path == newer
    assert source == "local:EmStore.ipa"


def test_resolve_ipa_downloads_when_no_local(monkeypatch, tmp_path):
    downloaded = tmp_path / "EmStore.ipa"
    downloaded.write_bytes(b"ipa")
    monkeypatch.setattr(server, "local_candidates", lambda: [])

    def fake_download(channel=None):
        assert channel == "alpha"
        return downloaded

    monkeypatch.setattr(server, "download_release_ipa", fake_download)
    path, source = server.resolve_ipa(channel="alpha")
    assert path == downloaded
    assert source == "github:alpha"


def test_download_release_ipa_verifies_zip_magic(monkeypatch, tmp_path):
    fake_response = type("R", (), {"raise_for_status": lambda self: None, "content": b"PK\x03\x04fake"})()
    calls = {"n": 0}

    def fake_get(url, **kwargs):
        calls["n"] += 1
        if url.startswith("https://api.github.com"):
            return type("R", (), {
                "raise_for_status": lambda self: None,
                "json": lambda self: [
                    _release("Alpha SideStore Build", "alpha-1",
                             assets=["SideStore.ipa"], prerelease=True)
                ],
            })()
        return fake_response  # asset download

    monkeypatch.setattr(server.requests, "get", fake_get)
    dest = tmp_path / "cached" / "EmStore.ipa"
    dest.parent.mkdir()
    path = server.download_release_ipa(dest=dest)
    assert path == dest
    assert dest.read_bytes() == b"PK\x03\x04fake"
    assert not dest.with_name(dest.name + ".part").exists()
    assert calls["n"] == 2


def test_download_release_ipa_rejects_non_zip(monkeypatch, tmp_path):
    def fake_get(url, **kwargs):
        return type("R", (), {
            "raise_for_status": lambda self: None,
            "json": lambda self: [
                _release("Alpha SideStore Build", "alpha-1", assets=["SideStore.ipa"])
            ],
        })() if url.startswith("https://api.github.com") else type(
            "R", (), {"raise_for_status": lambda self: None, "content": b"<html>not a zip"}
        )()

    monkeypatch.setattr(server.requests, "get", fake_get)
    with pytest.raises(EmLoadError, match="not an IPA"):
        server.download_release_ipa(dest=tmp_path / "EmStore.ipa")


# --------------------------------------------------------------------------- #
# One-shot install
# --------------------------------------------------------------------------- #
def _stub_install_env(monkeypatch, tmp_path) -> tuple[object, dict]:
    """Signed in, a local IPA, and a fake installed-app inventory."""
    monkeypatch.setattr(
        server.gsa, "status",
        lambda: {"authenticated": True, "email": "ios@example.com"},
    )
    ipa = tmp_path / "EmStore.ipa"
    ipa.write_bytes(b"PK\x03\x04x")
    monkeypatch.setattr(
        server, "resolve_ipa", lambda *a, **k: (ipa, "local:EmStore.ipa")
    )
    installed: dict[str, dict] = {}
    monkeypatch.setattr(
        server.apps, "list_installed", lambda udid, app_type="User": installed
    )
    return ipa, installed


def test_ensure_installed_requires_signin(monkeypatch, tmp_path):
    monkeypatch.setattr(
        server.gsa, "status", lambda: {"authenticated": False}
    )
    with pytest.raises(EmLoadError, match="not signed in"):
        server.ensure_installed("deadbeef")


def test_ensure_installed_skips_when_present(monkeypatch, tmp_path):
    _ipa, installed = _stub_install_env(monkeypatch, tmp_path)
    installed[server.EMSTORE_BUNDLE_ID] = {
        "name": "SideStore", "version": "0.6.4", "build": "604",
    }
    calls = {"n": 0}
    monkeypatch.setattr(
        server.sideload, "run_sideload",
        lambda *a, **k: calls.__setitem__("n", calls["n"] + 1) or {},
    )
    result = server.ensure_installed("deadbeef")
    assert result["status"] == "already_installed"
    assert result["version"] == "0.6.4"
    assert calls["n"] == 0


def test_ensure_installed_installs_when_missing(monkeypatch, tmp_path):
    ipa, installed = _stub_install_env(monkeypatch, tmp_path)
    captured: dict = {}

    def fake_sideload(ipa_path, udid, **kwargs):
        captured.update(ipa_path=ipa_path, udid=udid, kwargs=kwargs)
        return {"status": "installed", "bundle_id": kwargs["bundle_id"], "name": "x"}

    monkeypatch.setattr(server.sideload, "run_sideload", fake_sideload)
    result = server.ensure_installed("deadbeef", display_name="EmStore")
    assert result["status"] == "installed"
    assert result["ipa_source"] == "local:EmStore.ipa"
    assert captured["udid"] == "deadbeef"
    assert captured["ipa_path"] == str(ipa)
    assert captured["kwargs"]["bundle_id"] == server.EMSTORE_BUNDLE_ID
    assert captured["kwargs"]["display_name"] == "EmStore"


def test_ensure_installed_force_reinstalls(monkeypatch, tmp_path):
    _ipa, installed = _stub_install_env(monkeypatch, tmp_path)
    installed[server.EMSTORE_BUNDLE_ID] = {"name": "SideStore", "version": "0.6.4"}
    calls = {"n": 0}

    def fake_sideload(*a, **k):
        calls["n"] += 1
        return {"status": "installed", "bundle_id": k["bundle_id"], "name": "x"}

    monkeypatch.setattr(server.sideload, "run_sideload", fake_sideload)
    result = server.ensure_installed("deadbeef", force=True)
    assert result["status"] == "installed"
    assert calls["n"] == 1


# --------------------------------------------------------------------------- #
# Background watcher
# --------------------------------------------------------------------------- #
class _ImmediateThread:  # runs the target synchronously, no real threading
    def __init__(self, target=None, args=(), kwargs=None, daemon=None):
        self._target = target
        self._args = args
        self._kwargs = kwargs or {}

    def start(self):
        self._target(*self._args, **self._kwargs)


def _stub_watch(monkeypatch, sequences):
    def fake_watch(emit, stop):
        for entries in sequences:
            emit({"type": "event", "name": "devices", "data": entries})
    monkeypatch.setattr(server.device, "run_usbmux_watch", fake_watch)
    monkeypatch.setattr(server.threading, "Thread", _ImmediateThread)


def test_watch_installs_each_new_device(monkeypatch):
    _stub_watch(monkeypatch, [
        [{"serial": "AAA", "connection_type": "USB"}],
        [{"serial": "AAA"}, {"serial": "BBB", "connection_type": "Network"}],
        [{"serial": "AAA"}],  # BBB left - forget it so a re-plug counts as new
        [{"serial": "BBB", "connection_type": "USB"}, {"serial": "CCC"}],
    ])
    installed: list[str] = []
    monkeypatch.setattr(
        server, "ensure_installed",
        lambda serial, **k: installed.append(serial) or {"status": "installed", "udid": serial},
    )
    server.watch_and_install(threading.Event(), on_log=lambda m: None)
    # BBB appears again after leaving, so it is treated as a new attach (the
    # install itself is idempotent - ensure_installed reports already_installed).
    assert installed == ["AAA", "BBB", "BBB", "CCC"]


def test_watch_respects_filter_udid(monkeypatch):
    _stub_watch(monkeypatch, [
        [{"serial": "AAA"}, {"serial": "BBB"}],
        [{"serial": "CCC"}],
    ])
    installed: list[str] = []
    monkeypatch.setattr(
        server, "ensure_installed",
        lambda serial, **k: installed.append(serial) or {"status": "installed", "udid": serial},
    )
    server.watch_and_install(threading.Event(), filter_udid="BBB")
    assert installed == ["BBB"]


def test_watch_processes_already_connected_devices(monkeypatch):
    _stub_watch(monkeypatch, [])  # the listener never reports anything
    installed: list[str] = []
    monkeypatch.setattr(
        server, "ensure_installed",
        lambda serial, **k: installed.append(serial) or {"status": "installed", "udid": serial},
    )
    stop = threading.Event()
    server.watch_and_install(
        stop,
        on_log=lambda m: None,
        initial=[{"serial": "AAA", "connection_type": "USB"}],
    )
    assert installed == ["AAA"]


def test_watch_retries_after_failure(monkeypatch):
    _stub_watch(monkeypatch, [
        [{"serial": "AAA"}],   # first attach fails (e.g. untrusted)
        [],                    # it detaches again
        [{"serial": "AAA"}],   # re-attach: retried as a new device
    ])
    calls: list[str] = []

    def flaky(serial, **k):
        calls.append(serial)
        if len(calls) == 1:
            raise EmLoadError("device not paired")
        return {"status": "installed", "udid": serial}

    monkeypatch.setattr(server, "ensure_installed", flaky)
    logs: list[str] = []
    server.watch_and_install(threading.Event(), on_log=logs.append)
    assert len(calls) == 2
    assert any("installed." in line for line in logs)