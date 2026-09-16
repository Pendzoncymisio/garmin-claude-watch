"""Bridge between Claude Code sessions and the watch.

* ``GET /usage`` - 5h and 7d rate limits, plus how old the figures are
* ``PUT /usage/{source}`` - a capture hook on another machine hands in its snapshot

Payloads stay small and flat: the glance runs in 64 KB and the background
service in another 64 KB, and neither should hold a large response alive.

**There is no way to refresh these figures on demand.** Claude Code receives
subscription rate limits as ``anthropic-ratelimit-unified-*`` response headers on
its own API calls and pushes them to the status line; nothing else consumes
them. ``claude -p`` runs headless and never renders a status line — verified by
watching ``session_id``, which does not change across a headless run — so it
cannot be used to force an update. There is no ``claude usage --json``
(feature request: anthropics/claude-code#40793), no local rate-limit state file,
and the Admin usage API covers API-key billing rather than Pro/Max
subscriptions.

What saves this is that stale figures are usually still *correct*: usage only
grows when a session runs, and a session running is exactly what refreshes the
file. The real failure mode is not staleness but the 5h window rolling over
while nobody is looking — after which the stored percentage describes a window
that no longer exists. That case is detected and reported separately.

**Several machines, one account.** The limits are account-wide, so a snapshot
from any machine is valid for all of them, and the freshest one is the right
one to show. The hook on this machine writes ``CLAUDE_USAGE_FILE``; hooks on
other machines ``PUT`` their snapshot here and it lands in ``CLAUDE_USAGE_DIR``
as ``<source>.json``. ``GET /usage`` serves whichever has the newest ``ts``.

Nothing here can write into a Claude session.

``GET /usage`` is gated by Cloudflare Access when ``CLAUDE_ACCESS_AUD`` is set —
see ``access.py``. Unset, the bridge is open, which is what a LAN-only run
against the simulator wants. ``PUT`` exists only when ``CLAUDE_USAGE_PUSH_TOKEN``
is set, and then needs that token as a bearer credential plus, if
``CLAUDE_USAGE_PUSH_FROM`` lists networks, a peer address inside one of them.
"""

from __future__ import annotations

import hmac
import ipaddress
import json
import os
import re
import time
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, ValidationError

from . import access

USAGE_FILE = Path(os.environ.get("CLAUDE_USAGE_FILE", Path.home() / ".claude" / "usage.json"))

#: Snapshots pushed by other machines, one file per source. Next to the local
#: file unless placed elsewhere, so a test that relocates one relocates both.
USAGE_DIR = Path(os.environ.get("CLAUDE_USAGE_DIR") or USAGE_FILE.with_name("usage.d"))

#: Name under which the local file is reported, so the response can say where
#: the figures came from.
LOCAL_SOURCE = "local"

# Past this the figures describe a session that stopped rendering. Overridable
# so the stale path can be exercised without waiting a quarter of an hour.
STALE_AFTER_S = int(os.environ.get("CLAUDE_STALE_AFTER_S", 15 * 60))

#: Setting this is what enables ``PUT /usage/{source}``. No default: a shared
#: secret belongs to a deployment, never to a public repository.
PUSH_TOKEN = os.environ.get("CLAUDE_USAGE_PUSH_TOKEN") or None

#: Comma-separated networks a push may come from. Empty means any peer that
#: knows the token, which is fine on a closed LAN and wrong the moment the
#: bridge is reachable from further away — pin it to the pushing machines.
PUSH_FROM = [
    ipaddress.ip_network(n.strip(), strict=False)
    for n in os.environ.get("CLAUDE_USAGE_PUSH_FROM", "").split(",")
    if n.strip()
]

#: A source name is a filename, so it is kept to something that cannot leave
#: ``USAGE_DIR`` or collide with the local file.
_SOURCE_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,31}")

#: A snapshot is a few hundred bytes; anything bigger is not one.
_MAX_PUSH_BYTES = 4096

#: A ``ts`` this far ahead of our clock is a clock problem on the sender, and
#: taking it at face value would make that machine win every comparison.
_MAX_FUTURE_S = 60


app = FastAPI(title="Claude watch bridge", version="0.3.0")


class Usage(BaseModel):
    model: str | None = None
    five_pct: int | None = None
    five_resets_in_min: int | None = None
    seven_pct: int | None = None
    #: Seconds since the figures were captured.
    age_s: int
    #: Older than the staleness threshold — present it as possibly out of date.
    stale: bool
    #: The captured 5h window has since reset, so five_pct describes a window
    #: that has already expired. The true current figure is near zero, but this
    #: says "unknown" rather than guessing on the user's behalf.
    window_expired: bool
    #: Which machine's capture these figures are: ``local`` or a pushed source.
    source: str


class Window(BaseModel):
    model_config = ConfigDict(extra="ignore")
    pct: float | None = None
    resets_at: int | None = None


class Snapshot(BaseModel):
    """What the capture hook writes, and therefore what a push must look like.

    Unknown keys are dropped rather than stored: the hook also records the
    session id and working directory, which are of no use to the watch and
    have no business being copied between machines.
    """

    model_config = ConfigDict(extra="ignore")
    ts: int
    model: str | None = None
    five_hour: Window | None = None
    seven_day: Window | None = None


@app.get("/health")
def health() -> dict[str, object]:
    """Liveness, plus whether authentication is actually switched on.

    Deliberately unauthenticated: it reports no usage figures, and a probe that
    needs a credential cannot tell you the credential path is broken. It does
    say whether verification is enabled, so a deployment that meant to turn it
    on can confirm it did.
    """
    return {"status": "ok", **access.status(), "push": "on" if PUSH_TOKEN else "off"}


def _snapshots() -> list[tuple[str, Path]]:
    """Every place a capture may be: the local file first, then pushed ones."""
    found = [(LOCAL_SOURCE, USAGE_FILE)]
    if USAGE_DIR.is_dir():
        found += [(p.stem, p) for p in sorted(USAGE_DIR.glob("*.json"))]
    return found


def _read_usage() -> dict:
    """The freshest capture across all sources, with its name under ``source``."""
    best: dict | None = None
    unreadable = False
    for name, path in _snapshots():
        try:
            raw = json.loads(path.read_text())
        except FileNotFoundError:
            continue
        except (json.JSONDecodeError, OSError):
            # Should not happen: every writer renames atomically. A truncated
            # file is still better reported than served as zeroes.
            unreadable = True
            continue
        if not isinstance(raw, dict):
            unreadable = True
            continue
        try:
            ts = int(raw.get("ts", 0))
        except (TypeError, ValueError):
            ts = 0
        raw["ts"] = ts
        raw["source"] = name
        if best is None or ts > best["ts"]:
            best = raw

    if best is not None:
        return best
    if unreadable:
        raise HTTPException(status_code=503, detail="usage file unreadable")
    raise HTTPException(
        status_code=404,
        detail="no usage captured yet - is the status line hook installed?",
    )


def _pct(value) -> int | None:
    """Round to whole percent — neither view has room for decimals."""
    return None if value is None else int(round(float(value)))


def _build_usage() -> Usage:
    raw = _read_usage()
    now = int(time.time())
    age = max(0, now - (raw["ts"] or now))

    resets_at = (raw.get("five_hour") or {}).get("resets_at")
    resets_in = None
    expired = False
    if resets_at:
        remaining = int(resets_at) - now
        expired = remaining <= 0
        resets_in = max(0, int(remaining / 60))

    return Usage(
        model=raw.get("model"),
        five_pct=_pct((raw.get("five_hour") or {}).get("pct")),
        five_resets_in_min=resets_in,
        seven_pct=_pct((raw.get("seven_day") or {}).get("pct")),
        age_s=age,
        stale=age > STALE_AFTER_S,
        window_expired=expired,
        source=raw["source"],
    )


@app.get("/usage", response_model=Usage, dependencies=[Depends(access.verify)])
def usage() -> Usage:
    return _build_usage()


def _push_allowed_from(request: Request) -> bool:
    if not PUSH_FROM:
        return True
    try:
        peer = ipaddress.ip_address(request.client.host if request.client else "")
    except ValueError:
        return False
    return any(peer in net for net in PUSH_FROM)


@app.put("/usage/{source}", status_code=204)
async def push(source: str, request: Request) -> Response:
    """Accept another machine's capture. Token first, then everything else.

    Not enabled: 404, so a bridge that never asked for pushes does not
    advertise a write route. Wrong network: 403. Bad or missing token: 401.
    The body is the hook's own ``usage.json``, validated and reduced to the
    fields the watch needs before it is stored.
    """
    if PUSH_TOKEN is None:
        raise HTTPException(status_code=404, detail="Not Found")
    if not _push_allowed_from(request):
        raise HTTPException(status_code=403, detail="push not accepted from this address")

    auth = request.headers.get("authorization", "")
    scheme, _, presented = auth.partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(presented.strip(), PUSH_TOKEN):
        raise HTTPException(status_code=401, detail="bad push token")

    if not _SOURCE_RE.fullmatch(source) or source == LOCAL_SOURCE:
        raise HTTPException(status_code=422, detail="source must be [a-z0-9_-], not 'local'")

    body = await request.body()
    if len(body) > _MAX_PUSH_BYTES:
        raise HTTPException(status_code=413, detail="snapshot too large")
    try:
        snapshot = Snapshot.model_validate_json(body)
    except ValidationError as exc:
        raise HTTPException(status_code=422, detail="not a usage snapshot") from exc

    snapshot.ts = min(snapshot.ts, int(time.time()) + _MAX_FUTURE_S)

    USAGE_DIR.mkdir(parents=True, exist_ok=True)
    target = USAGE_DIR / f"{source}.json"
    tmp = target.with_name(f".{source}.json.tmp")
    tmp.write_text(snapshot.model_dump_json())
    os.replace(tmp, target)
    return Response(status_code=204)
