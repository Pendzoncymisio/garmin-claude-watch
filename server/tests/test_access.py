"""The bridge must not be open once it is reachable from the internet.

These tests mint their own RSA key and serve it as a JWKS, so the whole
verification path runs offline — no Cloudflare, no network, no real token.
"""

from __future__ import annotations

import importlib
import json
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

AUD = "test-audience-tag"
KID = "test-key-id"


@pytest.fixture(scope="module")
def keypair():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return key, key.public_key()


@pytest.fixture
def usage_file(tmp_path):
    """A capture that is fresh and mid-window, so nothing else trips a flag."""
    now = int(time.time())
    p = tmp_path / "usage.json"
    p.write_text(json.dumps({
        "ts": now,
        "model": "Test",
        "five_hour": {"pct": 42.4, "resets_at": now + 3600},
        "seven_day": {"pct": 7.7, "resets_at": now + 86400},
    }))
    return p


def build(monkeypatch, usage_file, keypair, *, aud=None, certs_url=None):
    """Import the app fresh, since both modules read env at import time."""
    monkeypatch.setenv("CLAUDE_USAGE_FILE", str(usage_file))
    for name, value in (("CLAUDE_ACCESS_AUD", aud), ("CLAUDE_ACCESS_CERTS_URL", certs_url)):
        if value is None:
            monkeypatch.delenv(name, raising=False)
        else:
            monkeypatch.setenv(name, value)

    from app import access, main
    importlib.reload(access)
    importlib.reload(main)

    if aud is not None:
        # Serve the test key instead of fetching Cloudflare's.
        monkeypatch.setattr(access, "_fetch_jwks", lambda: jwks_for(keypair))
        access._keys = {}
        access._fetched_at = 0.0

    return TestClient(main.app)


def jwks_for(keypair):
    import base64
    _, public = keypair
    numbers = public.public_numbers()

    def b64(n, length):
        return base64.urlsafe_b64encode(n.to_bytes(length, "big")).rstrip(b"=").decode()

    return {"keys": [{"kty": "RSA", "alg": "RS256", "use": "sig", "kid": KID,
                      "n": b64(numbers.n, 256), "e": b64(numbers.e, 3)}]}


def mint(keypair, *, aud=AUD, kid=KID, expired=False):
    private, _ = keypair
    now = int(time.time())
    return jwt.encode(
        {"aud": aud, "iss": "https://example.cloudflareaccess.com",
         "iat": now - 10, "exp": now - 5 if expired else now + 300, "sub": "svc"},
        private, algorithm="RS256", headers={"kid": kid},
    )


def test_open_when_unconfigured(monkeypatch, usage_file, keypair):
    """No audience tag set: the LAN dev path must keep working."""
    client = build(monkeypatch, usage_file, keypair)
    assert client.get("/health").json()["access_verification"] == "off"
    r = client.get("/usage")
    assert r.status_code == 200
    assert r.json()["five_pct"] == 42


def test_valid_assertion_passes(monkeypatch, usage_file, keypair):
    client = build(monkeypatch, usage_file, keypair, aud=AUD, certs_url="https://example.invalid/certs")
    assert client.get("/health").json()["access_verification"] == "on"
    r = client.get("/usage", headers={"Cf-Access-Jwt-Assertion": mint(keypair)})
    assert r.status_code == 200
    assert r.json()["five_pct"] == 42


@pytest.mark.parametrize("headers, why", [
    ({}, "no header at all — reached the bridge without going through Access"),
    ({"Cf-Access-Jwt-Assertion": "not-a-jwt"}, "garbage"),
])
def test_missing_or_malformed_is_rejected(monkeypatch, usage_file, keypair, headers, why):
    client = build(monkeypatch, usage_file, keypair, aud=AUD, certs_url="https://example.invalid/certs")
    assert client.get("/usage", headers=headers).status_code == 401, why


def test_wrong_audience_is_rejected(monkeypatch, usage_file, keypair):
    """A token minted for another application of the same account must not work."""
    client = build(monkeypatch, usage_file, keypair, aud=AUD, certs_url="https://example.invalid/certs")
    token = mint(keypair, aud="some-other-application")
    assert client.get("/usage", headers={"Cf-Access-Jwt-Assertion": token}).status_code == 401


def test_expired_assertion_is_rejected(monkeypatch, usage_file, keypair):
    client = build(monkeypatch, usage_file, keypair, aud=AUD, certs_url="https://example.invalid/certs")
    token = mint(keypair, expired=True)
    assert client.get("/usage", headers={"Cf-Access-Jwt-Assertion": token}).status_code == 401


def test_health_needs_no_credential(monkeypatch, usage_file, keypair):
    """Otherwise a broken credential path cannot be diagnosed from outside."""
    client = build(monkeypatch, usage_file, keypair, aud=AUD, certs_url="https://example.invalid/certs")
    assert client.get("/health").status_code == 200


def test_unknown_key_id_is_not_a_credential_error(monkeypatch, usage_file, keypair):
    """A key id we cannot resolve is 503, not 401.

    Rate limiting means an unknown kid is not refetched immediately, so this is
    the state a real rotation passes through. Reporting it as 401 would send the
    watch chasing a credential problem it does not have.
    """
    client = build(monkeypatch, usage_file, keypair, aud=AUD, certs_url="https://example.invalid/certs")
    token = mint(keypair, kid="some-other-key")
    assert client.get("/usage", headers={"Cf-Access-Jwt-Assertion": token}).status_code == 503


def test_keys_are_fetched_with_a_user_agent(monkeypatch, keypair):
    """Regression: Cloudflare answers the default `Python-urllib/x.y` with 403.

    PyJWT's own PyJWKClient uses urllib and cannot be given a User-Agent, which
    is the entire reason the fetch is hand-rolled. If someone swaps httpx back
    in for the built-in client, this fails.

    Deliberately does not use `build()`: that stubs out the fetch itself, which
    is the very thing under test here.
    """
    monkeypatch.setenv("CLAUDE_ACCESS_AUD", AUD)
    monkeypatch.setenv("CLAUDE_ACCESS_CERTS_URL", "https://example.invalid/certs")

    from app import access as access_module
    importlib.reload(access_module)

    seen = {}

    class FakeResponse:
        def raise_for_status(self):
            return None

        def json(self):
            return jwks_for(keypair)

    class FakeClient:
        headers = access_module._client.headers

        def get(self, url):
            seen["url"] = url
            seen["headers"] = dict(self.headers)
            return FakeResponse()

    monkeypatch.setattr(access_module, "_client", FakeClient())
    access_module.signing_key(KID)

    agent = seen["headers"].get("user-agent")
    assert agent, "the JWKS fetch must send a User-Agent"
    assert "urllib" not in agent.lower()
