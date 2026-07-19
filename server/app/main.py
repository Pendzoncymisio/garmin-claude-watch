"""Bridge between a local Claude Code session and the watch.

* ``GET /usage`` - 5h and 7d rate limits, plus how old the figures are

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

Nothing here can write into a Claude session.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

USAGE_FILE = Path(os.environ.get("CLAUDE_USAGE_FILE", Path.home() / ".claude" / "usage.json"))

# Past this the figures describe a session that stopped rendering. Overridable
# so the stale path can be exercised without waiting a quarter of an hour.
STALE_AFTER_S = int(os.environ.get("CLAUDE_STALE_AFTER_S", 15 * 60))


app = FastAPI(title="Claude watch bridge", version="0.2.0")


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


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


def _read_usage() -> dict:
    try:
        return json.loads(USAGE_FILE.read_text())
    except FileNotFoundError:
        raise HTTPException(
            status_code=404,
            detail="no usage captured yet - is the status line hook installed?",
        )
    except json.JSONDecodeError:
        # Should not happen: the writer renames atomically. A truncated file is
        # still better reported than served as zeroes.
        raise HTTPException(status_code=503, detail="usage file unreadable")


def _pct(value) -> int | None:
    """Round to whole percent — neither view has room for decimals."""
    return None if value is None else int(round(float(value)))


def _build_usage() -> Usage:
    raw = _read_usage()
    now = int(time.time())
    age = max(0, now - int(raw.get("ts", now)))

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
    )


@app.get("/usage", response_model=Usage)
def usage() -> Usage:
    return _build_usage()
