"""Several machines, one account: the bridge serves the freshest capture.

Other machines hand their snapshot in with ``PUT /usage/{source}``. That is the
only write the bridge accepts, so it is exercised the way the read side is: no
network, a throwaway token, and a temp directory standing in for ``~/.claude``.
"""

from __future__ import annotations

import importlib
import json
import time

import pytest
from fastapi.testclient import TestClient

TOKEN = "push-token-for-tests"
LAN_PEER = ("192.168.1.21", 40000)
OTHER_PEER = ("10.0.0.5", 40000)


def snapshot(ts, five=42.4, seven=7.7, **extra):
    return {"ts": ts, "model": "Test",
            "five_hour": {"pct": five, "resets_at": ts + 3600},
            "seven_day": {"pct": seven, "resets_at": ts + 86400},
            **extra}


@pytest.fixture
def usage_file(tmp_path):
    return tmp_path / "usage.json"


def build(monkeypatch, usage_file, *, token=TOKEN, push_from=None, peer=LAN_PEER):
    """Import the app fresh, since it reads env at import time. Access stays off."""
    monkeypatch.setenv("CLAUDE_USAGE_FILE", str(usage_file))
    monkeypatch.delenv("CLAUDE_USAGE_DIR", raising=False)
    monkeypatch.delenv("CLAUDE_ACCESS_AUD", raising=False)
    for name, value in (("CLAUDE_USAGE_PUSH_TOKEN", token), ("CLAUDE_USAGE_PUSH_FROM", push_from)):
        if value is None:
            monkeypatch.delenv(name, raising=False)
        else:
            monkeypatch.setenv(name, value)

    from app import access, main
    importlib.reload(access)
    importlib.reload(main)
    return TestClient(main.app, client=peer)


def put(client, source, body, token=TOKEN):
    headers = {"Authorization": f"Bearer {token}"} if token is not None else {}
    data = body if isinstance(body, (bytes, str)) else json.dumps(body)
    return client.put(f"/usage/{source}", content=data, headers=headers)


# --- reading across sources -------------------------------------------------------

def test_freshest_source_wins(monkeypatch, usage_file):
    now = int(time.time())
    usage_file.write_text(json.dumps(snapshot(now - 600, five=10)))
    client = build(monkeypatch, usage_file)

    assert put(client, "vm", snapshot(now - 30, five=55)).status_code == 204
    r = client.get("/usage").json()
    assert (r["source"], r["five_pct"], r["age_s"] < 60) == ("vm", 55, True)

    # The local file catching up flips it back.
    usage_file.write_text(json.dumps(snapshot(now, five=60)))
    r = client.get("/usage").json()
    assert (r["source"], r["five_pct"]) == ("local", 60)


def test_pushed_snapshot_serves_without_a_local_file(monkeypatch, usage_file):
    client = build(monkeypatch, usage_file)
    assert client.get("/usage").status_code == 404
    assert put(client, "vm", snapshot(int(time.time()))).status_code == 204
    r = client.get("/usage")
    assert r.status_code == 200 and r.json()["source"] == "vm"


def test_local_file_reports_itself(monkeypatch, usage_file):
    usage_file.write_text(json.dumps(snapshot(int(time.time()))))
    client = build(monkeypatch, usage_file)
    assert client.get("/usage").json()["source"] == "local"
    assert client.get("/health").json()["push"] == "on"


def test_unreadable_pushed_file_does_not_hide_a_good_one(monkeypatch, usage_file, tmp_path):
    usage_file.write_text(json.dumps(snapshot(int(time.time()))))
    client = build(monkeypatch, usage_file)
    (tmp_path / "usage.d").mkdir()
    (tmp_path / "usage.d" / "broken.json").write_text("{not json")
    assert client.get("/usage").status_code == 200


# --- what a push must carry -------------------------------------------------------

def test_push_is_a_missing_route_when_not_enabled(monkeypatch, usage_file):
    client = build(monkeypatch, usage_file, token=None)
    assert put(client, "vm", snapshot(int(time.time()))).status_code == 404
    assert client.get("/health").json()["push"] == "off"


@pytest.mark.parametrize("token", [None, "", "wrong-token", TOKEN + "x"])
def test_bad_token_is_refused(monkeypatch, usage_file, token):
    client = build(monkeypatch, usage_file)
    assert put(client, "vm", snapshot(int(time.time())), token=token).status_code == 401
    assert not (usage_file.parent / "usage.d").exists()


def test_basic_scheme_is_not_bearer(monkeypatch, usage_file):
    client = build(monkeypatch, usage_file)
    r = client.put("/usage/vm", content=json.dumps(snapshot(1)), headers={"Authorization": f"Basic {TOKEN}"})
    assert r.status_code == 401


def test_peer_network_is_enforced_when_configured(monkeypatch, usage_file):
    body = snapshot(int(time.time()))
    inside = build(monkeypatch, usage_file, push_from="192.168.1.0/24", peer=LAN_PEER)
    assert put(inside, "vm", body).status_code == 204

    outside = build(monkeypatch, usage_file, push_from="192.168.1.0/24", peer=OTHER_PEER)
    r = put(outside, "vm", body)
    assert r.status_code == 403
    # Checked before the token, so an outsider cannot probe for it.
    assert put(outside, "vm", body, token="wrong").status_code == 403


def test_no_network_list_means_any_peer(monkeypatch, usage_file):
    client = build(monkeypatch, usage_file, push_from=None, peer=OTHER_PEER)
    assert put(client, "vm", snapshot(int(time.time()))).status_code == 204


@pytest.mark.parametrize("source", ["local", "Vm", "a b", "../etc", "x" * 33, ".hidden"])
def test_source_name_is_a_plain_filename(monkeypatch, usage_file, source):
    client = build(monkeypatch, usage_file)
    r = client.put(f"/usage/{source}", content=json.dumps(snapshot(1)),
                   headers={"Authorization": f"Bearer {TOKEN}"})
    assert r.status_code in (404, 422), source  # 404 when the router rejects the path itself


@pytest.mark.parametrize("body, code", [
    ("{not json", 422),
    (json.dumps({"model": "no ts"}), 422),
    (json.dumps({"ts": "soon"}), 422),
    (json.dumps(snapshot(1, note="x" * 5000)), 413),
])
def test_junk_is_refused(monkeypatch, usage_file, body, code):
    client = build(monkeypatch, usage_file)
    assert put(client, "vm", body).status_code == code


def test_only_the_watch_fields_are_stored(monkeypatch, usage_file):
    """The hook also records session id and cwd; those stay on their machine."""
    client = build(monkeypatch, usage_file)
    now = int(time.time())
    assert put(client, "vm", snapshot(now, session_id="abc", cwd="/secret/path",
                                      context={"used_pct": 50})).status_code == 204
    stored = json.loads((usage_file.parent / "usage.d" / "vm.json").read_text())
    assert set(stored) == {"ts", "model", "five_hour", "seven_day"}
    assert stored["five_hour"] == {"pct": 42.4, "resets_at": now + 3600}


def test_clock_from_the_future_is_clamped(monkeypatch, usage_file):
    """A sender with a fast clock must not win every comparison forever."""
    client = build(monkeypatch, usage_file)
    now = int(time.time())
    assert put(client, "vm", snapshot(now + 7200)).status_code == 204
    stored = json.loads((usage_file.parent / "usage.d" / "vm.json").read_text())
    assert stored["ts"] <= now + 61
    assert client.get("/usage").json()["age_s"] == 0


def test_overwrite_is_atomic_and_leaves_no_temp_file(monkeypatch, usage_file):
    client = build(monkeypatch, usage_file)
    now = int(time.time())
    put(client, "vm", snapshot(now - 10, five=1))
    put(client, "vm", snapshot(now, five=2))
    d = usage_file.parent / "usage.d"
    assert sorted(p.name for p in d.iterdir()) == ["vm.json"]
    assert client.get("/usage").json()["five_pct"] == 2
