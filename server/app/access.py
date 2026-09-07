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
import threading
import time

import httpx
import jwt
from fastapi import HTTPException, Request
from jwt import PyJWK

AUD = os.environ.get("CLAUDE_ACCESS_AUD") or None
CERTS_URL = os.environ.get("CLAUDE_ACCESS_CERTS_URL") or None

#: Cloudflare answers `Python-urllib/x.y` with a 403, which is why the keys are
#: fetched here rather than by PyJWT's built-in PyJWKClient: that client uses
#: urllib and cannot be given a User-Agent. Any plausible one is accepted.
_USER_AGENT = "claudeWatch-bridge/1.0"

#: Long enough that a burst of requests does not hammer Cloudflare, short enough
#: that a rotated key is picked up the same day.
_TTL_S = 600

#: An unknown key id means either a rotation (refetch, good) or a forged token
#: (refetching on demand would let anyone drive our request rate). This is the
#: floor between refetches, so a stream of junk key ids costs one fetch a minute.
_MIN_REFETCH_S = 60

_lock = threading.Lock()
_keys: dict[str, PyJWK] = {}
_fetched_at = 0.0

#: Built once, at import, on the main thread — deliberately not per request.
#: FastAPI runs sync endpoints in a worker thread, and creating the TLS context
#: there fails the first time in this environment with a bare
#: `ssl.SSLError: unknown error (_ssl.c:3036)`, succeeding on every later
#: attempt. Constructing the client at import moves that work to a place where
#: it is reliable, and reuses one connection pool besides.
_client = httpx.Client(timeout=10.0, headers={"User-Agent": _USER_AGENT})


class KeyLookupError(RuntimeError):
    """The signing keys could not be fetched, or the key id is not among them."""


def enabled() -> bool:
    return AUD is not None


def _fetch_jwks() -> dict:
    """Retrieve the JWKS document. Separated out so tests can replace it."""
    response = _client.get(CERTS_URL)
    response.raise_for_status()
    return response.json()


def _refresh() -> None:
    try:
        document = _fetch_jwks()
    except Exception as exc:  # noqa: BLE001 - httpx raises several unrelated types
        raise KeyLookupError(f"cannot fetch signing keys: {exc}") from exc

    global _keys, _fetched_at
    _keys = {k["kid"]: PyJWK(k, algorithm="RS256") for k in document.get("keys", []) if "kid" in k}
    _fetched_at = time.monotonic()
    if not _keys:
        raise KeyLookupError("signing key document contained no usable keys")


def signing_key(kid: str) -> PyJWK:
    with _lock:
        age = time.monotonic() - _fetched_at
        if not _keys or age > _TTL_S:
            _refresh()
        elif kid not in _keys and age > _MIN_REFETCH_S:
            # Probably a rotation. Rate-limited, so a forged key id cannot be
            # used to make us fetch on demand.
            _refresh()

        key = _keys.get(kid)
        if key is None:
            raise KeyLookupError(f"no signing key for kid {kid!r}")
        return key


def verify(request: Request) -> None:
    """Raise unless the request carries a valid Access assertion.

    A no-op when verification is disabled, so the dev path is unchanged.
    """
    if not enabled():
        return

    if not CERTS_URL:
        # Refuse rather than fall back to unauthenticated: a deployment that
        # sets AUD has asked for verification, and quietly not doing it is the
        # worst possible outcome.
        raise HTTPException(
            status_code=500,
            detail="CLAUDE_ACCESS_AUD is set but CLAUDE_ACCESS_CERTS_URL is not",
        )

    token = request.headers.get("cf-access-jwt-assertion")
    if not token:
        # Access strips CF-Access-Client-Id before forwarding and adds this
        # header itself, so its absence means the request did not come through
        # Access at all — someone reached the bridge directly.
        raise HTTPException(status_code=401, detail="no Access assertion")

    try:
        header = jwt.get_unverified_header(token)
    except jwt.PyJWTError as exc:
        raise HTTPException(status_code=401, detail="invalid Access assertion") from exc

    try:
        key = signing_key(header.get("kid", ""))
    except KeyLookupError as exc:
        # This side failing, not the caller presenting something bad. Calling it
        # 401 would send the watch chasing a credential problem it does not have.
        print(f"[access] key lookup failed: {exc}", flush=True)
        raise HTTPException(status_code=503, detail="cannot verify right now") from exc

    try:
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
    except jwt.PyJWTError as exc:
        # Deliberately opaque to the caller — the response should not say which
        # check failed. The reason is logged instead.
        print(f"[access] rejected assertion: {type(exc).__name__}: {exc}", flush=True)
        raise HTTPException(status_code=401, detail="invalid Access assertion") from exc


def status() -> dict[str, object]:
    """For /health, so a deployment can confirm auth is actually on."""
    return {"access_verification": "on" if enabled() else "off", "checked_at": int(time.time())}
