"""Cloudflare Access verification for the bridge.

The bridge is read-only, but it still must not be an open endpoint once it is
reachable from the internet. Access sits in front of it and authenticates the
watch with a **service token**; what arrives here is a signed JWT in the
``Cf-Access-Jwt-Assertion`` header.

Checking that the header merely *exists* would be worthless: anything that can
reach the bridge directly — anything on the LAN — could set it. The signature is
the only thing that cannot be forged, so it is verified against Access's public
keys, along with the audience tag, which is what stops a token minted for some
other application of the same account being replayed here.

Configuration is entirely environmental and there are no defaults, because the
values name a specific deployment and this repository is public:

``CLAUDE_ACCESS_AUD``
    The application's audience tag. **Setting this turns verification on**; with
    it unset the bridge stays open, which is the right behaviour for a LAN-only
    dev run against the simulator.
``CLAUDE_ACCESS_CERTS_URL``
    Where to fetch the signing keys. Access publishes them on the application's
    own hostname at ``/cdn-cgi/access/certs``, so the team domain is not needed.
"""

from __future__ import annotations

import os
import time

import jwt
from fastapi import HTTPException, Request
from jwt import PyJWKClient
from jwt.exceptions import PyJWKClientError

AUD = os.environ.get("CLAUDE_ACCESS_AUD") or None
CERTS_URL = os.environ.get("CLAUDE_ACCESS_CERTS_URL") or None

#: Access rotates signing keys. PyJWKClient caches them and refetches on an
#: unknown key id, which is exactly the behaviour a rotation needs.
_jwks: PyJWKClient | None = None

#: Long enough that a burst of requests does not hammer Cloudflare, short enough
#: that a revoked key stops working the same day.
_JWKS_TTL_S = 600


def enabled() -> bool:
    return AUD is not None


def _client() -> PyJWKClient:
    global _jwks
    if _jwks is None:
        if not CERTS_URL:
            # Refuse rather than fall back to unauthenticated: a deployment that
            # sets AUD has asked for verification, and quietly not doing it is
            # the worst possible outcome.
            raise HTTPException(
                status_code=500,
                detail="CLAUDE_ACCESS_AUD is set but CLAUDE_ACCESS_CERTS_URL is not",
            )
        _jwks = PyJWKClient(CERTS_URL, cache_keys=True, lifespan=_JWKS_TTL_S)
    return _jwks


def verify(request: Request) -> None:
    """Raise 401 unless the request carries a valid Access assertion.

    A no-op when verification is disabled, so the dev path is unchanged.
    """
    if not enabled():
        return

    token = request.headers.get("cf-access-jwt-assertion")
    if not token:
        # Access strips CF-Access-Client-Id before forwarding and adds this
        # header itself, so its absence means the request did not come through
        # Access at all — someone reached the bridge directly.
        raise HTTPException(status_code=401, detail="no Access assertion")

    try:
        key = _client().get_signing_key_from_jwt(token).key
        jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            audience=AUD,
            options={"require": ["exp", "iat", "aud", "iss"]},
        )
        # The issuer is required to be present but not pinned to a value: the
        # audience tag is already specific to one application of one account,
        # which is the check that actually matters here.
    except PyJWKClientError as exc:
        # The keys could not be fetched or the key id is unknown. That is this
        # side failing, not the caller presenting something bad, and calling it
        # 401 would send the watch chasing a credential problem it does not have.
        print(f"[access] key lookup failed: {exc}", flush=True)
        raise HTTPException(status_code=503, detail="cannot verify right now") from exc
    except jwt.PyJWTError as exc:
        # Deliberately opaque to the caller — the response should not say which
        # check failed. The reason is logged instead.
        print(f"[access] rejected assertion: {type(exc).__name__}: {exc}", flush=True)
        raise HTTPException(status_code=401, detail="invalid Access assertion") from exc


def status() -> dict[str, object]:
    """For /health, so a deployment can confirm auth is actually on."""
    return {"access_verification": "on" if enabled() else "off", "checked_at": int(time.time())}
