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
        private, public = keypair
        numbers = public.public_numbers()

        def to_b64(n, length):
            import base64
            return base64.urlsafe_b64encode(n.to_bytes(length, "big")).rstrip(b"=").decode()

        jwks = {"keys": [{"kty": "RSA", "alg": "RS256", "use": "sig", "kid": KID,
                          "n": to_b64(numbers.n, 256), "e": to_b64(numbers.e, 3)}]}

        class FakeJWKClient:
            def __init__(self, *_a, **_kw):
                pass

            def get_signing_key_from_jwt(self, token):
                from jwt import PyJWK
                header = jwt.get_unverified_header(token)
                for k in jwks["keys"]:
                    if k["kid"] == header.get("kid"):
                        return PyJWK(k, algorithm="RS256")
                from jwt.exceptions import PyJWKClientError
                raise PyJWKClientError("unknown kid")

        monkeypatch.setattr(access, "PyJWKClient", FakeJWKClient)
        access._jwks = None

    return TestClient(main.app)


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
