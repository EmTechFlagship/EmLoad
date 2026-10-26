"""Tests for the EmStoreServer HTTP API (the EmStore app's AltServer alternative)."""

from __future__ import annotations

import hashlib
import json
import socket
import ssl
import threading
import time
import urllib.error
import urllib.request

import pytest

from emload import server
from emload.errors import EmLoadError


def _url(httpd: object) -> str:
    host, port = httpd.server_address[:2]
    return f"http://{host}:{port}"


def _get(url: str) -> tuple[int, dict]:
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def _post(url: str, body: dict | None = None) -> tuple[int, dict]:
    data = json.dumps(body or {}).encode("utf-8")
    request = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def _wait_job(base: str, job_id: str, timeout: float = 10) -> dict:
    """Poll /api/jobs/<id> until the job is done (the client's contract)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        _code, job = _get(f"{base}/api/jobs/{job_id}")
        if job["status"] == "done":
            return job
        time.sleep(0.05)
    raise AssertionError(f"job {job_id} did not finish in {timeout}s")


def _wait_store_job(jobs: server.JobStore, job_id: str, timeout: float = 5) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        job = jobs.get(job_id)
        if job is not None and job["status"] == "done":
            return job
        time.sleep(0.01)
    raise AssertionError(f"job {job_id} did not finish in {timeout}s")


# --------------------------------------------------------------------------- #
# Job bookkeeping (no network)
# --------------------------------------------------------------------------- #
def test_jobstore_lifecycle():
    jobs = server.JobStore()
    job = jobs.create("refresh", {"udid": "AAA"})
    assert job["status"] == "queued"
    assert job["params"] == {"udid": "AAA"}
    assert job["log"] == []
    jobs.append_log(job["job_id"], "working")
    jobs.touch(job["job_id"], summary="1/1 refreshed")
    jobs.finish(job["job_id"])
    done = jobs.get(job["job_id"])
    assert done["status"] == "done"
    assert done["summary"] == "1/1 refreshed"
    assert done["finished_at"] is not None
    assert done["log"][0].endswith("] working")


def test_jobstore_create_returns_snapshot():
    jobs = server.JobStore()
    job = jobs.create("install", {})
    job["status"] = "tampered"
    assert jobs.get(job["job_id"])["status"] == "queued"


def test_jobstore_evicts_oldest_over_limit():
    jobs = server.JobStore()
    first = jobs.create("refresh", {})
    for _ in range(server._JOB_LIMIT):
        jobs.create("refresh", {})
    assert jobs.get(first["job_id"]) is None
    assert len(jobs.list()) == server._JOB_LIMIT


def test_jobstore_fail_marks_done_with_error():
    jobs = server.JobStore()
    job = jobs.create("install", {})
    jobs.fail(job["job_id"], "boom")
    done = jobs.get(job["job_id"])
    assert done["status"] == "done"
    assert done["error"] == "boom"
    assert done["finished_at"] is not None


# --------------------------------------------------------------------------- #
# Background worker
# --------------------------------------------------------------------------- #
def test_worker_unknown_action_fails_job():
    jobs = server.JobStore()
    worker = server.JobWorker(jobs)
    worker.start()
    try:
        job = worker.submit("nope", {})
        done = _wait_store_job(jobs, job["job_id"])
        assert done["error"] == "unknown action 'nope'"
    finally:
        worker.stop()


def test_worker_survives_failures(monkeypatch):
    calls = {"n": 0}

    def runner(jobs, job_id, params, log):
        calls["n"] += 1
        if calls["n"] == 1:
            raise EmLoadError("signing failed")
        if calls["n"] == 2:
            raise RuntimeError("bug in runner")
        jobs.finish(job_id)

    monkeypatch.setattr(server, "_ACTIONS", {"install": runner})
    jobs = server.JobStore()
    worker = server.JobWorker(jobs)
    worker.start()
    try:
        first = worker.submit("install", {})
        done = _wait_store_job(jobs, first["job_id"])
        assert done["error"] == "signing failed"

        second = worker.submit("install", {})
        done = _wait_store_job(jobs, second["job_id"])
        assert done["error"] == "unexpected error: bug in runner"

        third = worker.submit("install", {})
        done = _wait_store_job(jobs, third["job_id"])
        assert done["status"] == "done"  # the worker kept processing
    finally:
        worker.stop()


# --------------------------------------------------------------------------- #
# Job runners
# --------------------------------------------------------------------------- #
def test_run_refresh_nothing_to_do(monkeypatch):
    monkeypatch.setattr(server.registry, "due", lambda within_days: [])
    jobs = server.JobStore()
    job_id = jobs.create("refresh", {})["job_id"]
    logs: list[str] = []
    server._run_refresh(jobs, job_id, {}, logs.append)
    job = jobs.get(job_id)
    assert job["status"] == "done"
    assert job["summary"] == "nothing to refresh"
    assert logs == ["nothing to refresh"]


def test_run_refresh_refreshes_due_apps(monkeypatch):
    entry = {"bundle_id": "com.example.Demo", "name": "Demo", "udid": "AAA"}
    monkeypatch.setattr(server.registry, "due", lambda within_days: [entry])
    monkeypatch.setattr(
        server.sideload, "refresh_record",
        lambda entry, on_progress=None: {"installed": True, "expires": "later"},
    )
    jobs = server.JobStore()
    job_id = jobs.create("refresh", {})["job_id"]
    logs: list[str] = []
    server._run_refresh(jobs, job_id, {"udid": "AAA", "within_days": 3.0}, logs.append)
    job = jobs.get(job_id)
    assert job["status"] == "done"
    assert job["summary"] == "1/1 refreshed"
    assert job["results"][0]["status"] == "ok"
    assert job["results"][0]["bundle_id"] == "com.example.Demo"
    assert any("refreshing 1 app(s) on AAA" in line for line in logs)


def test_run_refresh_filters_by_bundle_ids(monkeypatch):
    entry = {"bundle_id": "com.example.Demo", "name": "Demo", "udid": "AAA"}
    monkeypatch.setattr(
        server.registry, "get",
        lambda bundle_id: entry if bundle_id == "com.example.Demo" else None,
    )
    monkeypatch.setattr(
        server.sideload, "refresh_record",
        lambda entry, on_progress=None: {"installed": True},
    )
    jobs = server.JobStore()
    job_id = jobs.create("refresh", {})["job_id"]
    server._run_refresh(jobs, job_id, {"bundle_ids": ["com.example.Demo"]}, lambda m: None)
    job = jobs.get(job_id)
    assert job["summary"] == "1/1 refreshed"


def test_run_refresh_records_failures(monkeypatch):
    entry = {"bundle_id": "com.example.Demo", "name": "Demo"}
    monkeypatch.setattr(server.registry, "due", lambda within_days: [entry])

    def boom(entry, on_progress=None):
        raise EmLoadError("bad provision")

    monkeypatch.setattr(server.sideload, "refresh_record", boom)
    jobs = server.JobStore()
    job_id = jobs.create("refresh", {})["job_id"]
    server._run_refresh(jobs, job_id, {}, lambda m: None)
    job = jobs.get(job_id)
    assert job["summary"] == "0/1 refreshed"
    assert job["results"][0]["status"] == "error"
    assert "bad provision" in job["results"][0]["error"]


def test_run_install_sideloads_emstore(monkeypatch):
    captured: dict = {}

    def fake_ensure(udid, **kwargs):
        captured.update(udid=udid, kwargs=kwargs)
        return {"status": "installed", "version": "0.6.4"}

    monkeypatch.setattr(server, "ensure_installed", fake_ensure)
    jobs = server.JobStore()
    job_id = jobs.create("install", {})["job_id"]
    logs: list[str] = []
    server._run_install(jobs, job_id, {"udid": "AAA", "force": True}, logs.append)
    job = jobs.get(job_id)
    assert job["status"] == "done"
    assert job["summary"] == "installed"
    assert job["results"] == [{"status": "installed", "version": "0.6.4"}]
    assert captured["udid"] == "AAA"
    assert captured["kwargs"]["force"] is True
    assert logs == ["installed"]


def test_run_install_resolves_udid_when_omitted(monkeypatch):
    monkeypatch.setattr(server.device, "resolve_serial", lambda: "FIRST")
    captured: dict = {}
    monkeypatch.setattr(
        server, "ensure_installed",
        lambda udid, **kwargs: captured.__setitem__("udid", udid)
        or {"status": "already_installed"},
    )
    jobs = server.JobStore()
    job_id = jobs.create("install", {})["job_id"]
    server._run_install(jobs, job_id, {}, lambda m: None)
    job = jobs.get(job_id)
    assert job["summary"] == "already installed"  # underscores become spaces
    assert captured["udid"] == "FIRST"


# --------------------------------------------------------------------------- #
# Live HTTP server
# --------------------------------------------------------------------------- #
@pytest.fixture
def httpd(tmp_path, monkeypatch):
    """A live server on an ephemeral port, with device/Apple calls stubbed."""
    monkeypatch.setattr(server.gsa, "status", lambda: {
        "authenticated": True,
        "email": "ios@example.com",
        "team_id": "TEAMID",
        "account_count": 1,
        "adsid": "secret-token",  # must never leave /api/status
    })
    ipa = tmp_path / "EmStore.ipa"
    ipa.write_bytes(b"PK\x03\x04hello")
    monkeypatch.setattr(server, "local_candidates", lambda: [ipa])
    monkeypatch.setattr(server.device, "list_devices", lambda: [
        {"serial": "AAA", "connection_type": "USB"},
        {"serial": "BBB", "connection_type": "Network"},
    ])
    monkeypatch.setattr(
        server.device, "get_device_info",
        lambda serial: {
            "DeviceName": f"Phone {serial}",
            "ProductType": "iPhone15,2",
            "ProductVersion": "18.1",
        },
    )
    monkeypatch.setattr(
        server.apps, "list_installed", lambda serial: {
            "com.SideStore.SideStore": {"name": "SideStore", "version": "1.0"},
            "com.example.Demo": {"name": "Demo", "version": "1.2.3"},
        }
    )

    httpd = server.create_server(port=0)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        yield httpd
    finally:
        httpd.shutdown()
        httpd.server_close()
        httpd.worker.stop()


def test_root_serves_service_info(httpd):
    code, body = _get(_url(httpd) + "/")
    assert code == 200
    assert body["service"] == server.SERVICE_NAME
    assert "/api/status" in body["endpoints"]


def test_status_reports_state_without_tokens(httpd):
    code, body = _get(_url(httpd) + "/api/status")
    assert code == 200
    assert body["service"] == server.SERVICE_NAME
    assert body["bundle_id"] == "com.SideStore.SideStore"
    assert body["repo"] == "embabyty/EmStore"
    assert body["account"]["authenticated"] is True
    assert body["account"]["email"] == "ios@example.com"
    assert body["account"]["team_id"] == "TEAMID"
    assert "adsid" not in body["account"]
    assert "secret-token" not in json.dumps(body)  # nowhere in the payload
    assert any(str(path).endswith("EmStore.ipa") for path in body["ipa"])


def test_devices_lists_connected_devices(httpd):
    code, body = _get(_url(httpd) + "/api/devices")
    assert code == 200
    assert body["devices"] == [
        {"udid": "AAA", "connection": "USB", "name": "Phone AAA",
         "model": "iPhone15,2", "os_version": "18.1"},
        {"udid": "BBB", "connection": "Network", "name": "Phone BBB",
         "model": "iPhone15,2", "os_version": "18.1"},
    ]


def test_apps_for_udid(httpd):
    code, body = _get(_url(httpd) + "/api/apps?udid=AAA")
    assert code == 200
    assert body["udid"] == "AAA"
    assert body["apps"] == [
        {"bundle_id": "com.SideStore.SideStore", "name": "SideStore", "version": "1.0"},
        {"bundle_id": "com.example.Demo", "name": "Demo", "version": "1.2.3"},
    ]


def test_jobs_list_starts_empty(httpd):
    code, body = _get(_url(httpd) + "/api/jobs")
    assert code == 200
    assert body["jobs"] == []


def test_unknown_endpoint_404(httpd):
    code, body = _get(_url(httpd) + "/api/nope")
    assert code == 404
    assert "error" in body


def test_job_not_found(httpd):
    code, body = _get(_url(httpd) + "/api/jobs/idonotexist")
    assert code == 404
    assert "no such job" in body["error"]


def test_post_refresh_returns_202_and_runs_job(monkeypatch, httpd):
    ran: dict = {}

    def fake_refresh(jobs, job_id, params, log):
        ran.update(params)
        jobs.append_log(job_id, "working")
        jobs.touch(
            job_id,
            results=[{"bundle_id": "com.example.Demo", "status": "ok"}],
            summary="1/1 refreshed",
        )
        jobs.finish(job_id)

    monkeypatch.setattr(server, "_ACTIONS", {"refresh": fake_refresh})
    code, body = _post(
        _url(httpd) + "/api/refresh",
        {"udid": "AAA", "bundle_ids": ["com.example.Demo"], "within_days": 14},
    )
    assert code == 202
    assert body["action"] == "refresh"
    assert body["status"] == "queued"
    job = _wait_job(_url(httpd), body["job_id"])
    assert job["status"] == "done"
    assert job["results"][0]["bundle_id"] == "com.example.Demo"
    assert ran["udid"] == "AAA"
    assert ran["bundle_ids"] == ["com.example.Demo"]
    assert ran["within_days"] == 14


def test_post_install_returns_202_and_drops_unknown_keys(monkeypatch, httpd):
    ran: dict = {}

    def fake_install(jobs, job_id, params, log):
        ran.update(params)
        jobs.finish(job_id)

    monkeypatch.setattr(server, "_ACTIONS", {"install": fake_install})
    code, body = _post(
        _url(httpd) + "/api/install", {"udid": "AAA", "force": True, "ignored": 7},
    )
    assert code == 202
    assert body["action"] == "install"
    job = _wait_job(_url(httpd), body["job_id"])
    assert job["status"] == "done"
    assert ran == {"udid": "AAA", "force": True}


def test_post_refresh_rejects_bad_bodies(httpd):
    code, body = _post(_url(httpd) + "/api/refresh", {"bundle_ids": "nope"})
    assert code == 400
    assert "bundle_ids" in body["error"]

    code, body = _post(_url(httpd) + "/api/refresh", {"within_days": "soon"})
    assert code == 400

    code, body = _post(_url(httpd) + "/api/refresh", {"udid": 7})
    assert code == 400


@pytest.fixture
def certificate_httpd(tmp_path, monkeypatch):
    monkeypatch.setattr(server.paths, "tls_dir", lambda: tmp_path)
    monkeypatch.setattr(
        server.provision, "signing_identity",
        lambda: (b"private-key", b"certificate", "serial"),
    )
    monkeypatch.setattr(
        server.signing, "build_p12",
        lambda cert_der, key_pem: b"test-pkcs12",
    )
    httpd, fingerprint = server.create_certificate_transfer_server(
        "127.0.0.1", 0, "pairing-token"
    )
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        yield httpd, fingerprint
    finally:
        httpd.shutdown()
        httpd.server_close()


def _certificate_get(httpd, token: str | None = None) -> tuple[int, dict]:
    host, port = httpd.server_address[:2]
    request = urllib.request.Request(f"https://{host}:{port}/api/certificate")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(
            request, context=ssl._create_unverified_context(), timeout=10
        ) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def test_certificate_transfer_requires_pairing_token(certificate_httpd):
    httpd, _fingerprint = certificate_httpd

    code, body = _certificate_get(httpd)

    assert code == 401
    assert body["error"] == "invalid transfer token"


def test_certificate_transfer_fingerprint_matches_tls_certificate(certificate_httpd):
    httpd, fingerprint = certificate_httpd
    host, port = httpd.server_address[:2]
    context = ssl._create_unverified_context()

    with socket.create_connection((host, port), timeout=10) as connection:
        with context.wrap_socket(connection, server_hostname=host) as tls_connection:
            certificate = tls_connection.getpeercert(binary_form=True)

    assert hashlib.sha256(certificate).hexdigest() == fingerprint


def test_certificate_share_returns_the_values_emcontainer_asks_for(tmp_path, monkeypatch):
    monkeypatch.setattr(server.paths, "tls_dir", lambda: tmp_path)
    monkeypatch.setattr(
        server.provision, "signing_identity",
        lambda: (b"private-key", b"certificate", "serial"),
    )
    monkeypatch.setattr(server.signing, "build_p12", lambda cert_der, key_pem: b"test-pkcs12")
    monkeypatch.setattr(server, "lan_ipv4", lambda: "127.0.0.1")
    monkeypatch.setattr(server, "_certificate_share", None)

    started = server.start_certificate_transfer()
    try:
        assert started["running"] is True
        assert started["url"].startswith("https://127.0.0.1:")
        assert started["url"].endswith("/api/certificate")
        assert started["token"]
        assert len(started["fingerprint"]) == 64
        again = server.start_certificate_transfer()
        assert again["token"] == started["token"]

        request = urllib.request.Request(started["url"])
        request.add_header("Authorization", f"Bearer {started['token']}")
        with urllib.request.urlopen(
            request, context=ssl._create_unverified_context(), timeout=10
        ) as response:
            body = json.loads(response.read())
        assert body == {"p12": "dGVzdC1wa2NzMTI=", "password": "EmLoad"}
    finally:
        assert server.stop_certificate_transfer() == {"running": False}
        assert server.certificate_transfer_status() == {"running": False}


def test_certificate_transfer_returns_pkcs12_with_valid_token(certificate_httpd):
    httpd, fingerprint = certificate_httpd

    code, body = _certificate_get(httpd, "pairing-token")

    assert len(fingerprint) == 64
    assert code == 200
    assert body == {"p12": "dGVzdC1wa2NzMTI=", "password": "EmLoad"}