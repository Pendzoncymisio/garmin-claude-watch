"""Bridge between a local Claude Code session and the watch.

Two read-only endpoints for now:

* ``/usage``    - rate-limit and context figures, captured by the status line
* ``/question`` - the question Claude is currently blocked on, if any

Payloads stay small and flat: the glance runs in 64 KB and the background
service in another 64 KB, and neither should hold a large response alive.

Nothing here can write to the session yet. Answer injection is a separate,
security-sensitive step and is deliberately not part of this service.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

USAGE_FILE = Path(os.environ.get("CLAUDE_USAGE_FILE", Path.home() / ".claude" / "usage.json"))

# Beyond this the figures describe a session that has long stopped rendering its
# status line, so the watch is told the age and can present it as stale rather
# than quietly showing an old number as current.
STALE_AFTER_S = 15 * 60

app = FastAPI(title="Claude watch bridge", version="0.1.0")


class Usage(BaseModel):
    model: str | None = None
    five_pct: int | None = None
    five_resets_in_min: int | None = None
    seven_pct: int | None = None
    ctx_pct: int | None = None
    age_s: int
    stale: bool


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
        # A torn read should not happen (the writer renames atomically), but a
        # truncated file is better reported than served as zeroes.
        raise HTTPException(status_code=503, detail="usage file unreadable")


def _pct(value) -> int | None:
    """Round to whole percent — the glance has no room for decimals."""
    return None if value is None else int(round(float(value)))


@app.get("/usage", response_model=Usage)
def usage() -> Usage:
    raw = _read_usage()
    now = int(time.time())
    age = max(0, now - int(raw.get("ts", now)))

    resets_at = (raw.get("five_hour") or {}).get("resets_at")
    resets_in = None
    if resets_at:
        resets_in = max(0, int((int(resets_at) - now) / 60))

    return Usage(
        model=raw.get("model"),
        five_pct=_pct((raw.get("five_hour") or {}).get("pct")),
        five_resets_in_min=resets_in,
        seven_pct=_pct((raw.get("seven_day") or {}).get("pct")),
        ctx_pct=_pct((raw.get("context") or {}).get("used_pct")),
        age_s=age,
        stale=age > STALE_AFTER_S,
    )
