# claudeWatch

Claude Code usage limits on a Garmin fēnix 8 Pro — 5h burn on the glance, both
windows when you open the app.

The point is deciding *whether there is room to start working* without walking
back to the machine. A glance in the carousel shows the 5-hour window as a
percentage, a bar and a countdown to reset; opening the app adds the 7-day
window and how old the reading is.

<!-- A screenshot of the glance and the full view belongs here. -->

## How the numbers get out of Claude Code

**Claude Code pushes them; nothing can pull them.** It receives subscription
rate limits as `anthropic-ratelimit-unified-*` response headers on its own API
calls and forwards them to exactly one place: the status line command, as JSON
on stdin. So the status line is the capture point.

```
Claude Code ──stdin JSON──▶ hooks/usage-capture.sh ──▶ ~/.claude/usage.json
                                                              │
                                            server/ (FastAPI, read-only)
                                                              │
                                                     GET /usage over HTTPS
                                                              │
                                                     glance + app on the watch
```

This was tested rather than assumed, and the alternatives do not exist:

- `claude -p` (headless) **never renders a status line**, so it cannot force an
  update. Verified via `session_id` in `usage.json`, which does not change
  across a headless run. Watching the timestamp alone is *not* a valid test —
  any live interactive session rewrites the file every few seconds.
- There is no `claude usage --json` (open request:
  [anthropics/claude-code#40793](https://github.com/anthropics/claude-code/issues/40793)),
  no local rate-limit state file, and no `claude usage` subcommand. `/usage` is
  TUI-only.
- The Admin usage API covers **API-key billing**, not Pro/Max subscriptions.
- `ccusage` and friends estimate cost from transcript token counts; they do not
  read real rate-limit windows.

Tapping the app therefore re-fetches from the bridge and picks up whatever
render has happened since — it cannot conjure fresher figures, and the app does
not pretend otherwise.

**Stale data is still usable**, because usage only grows when a session runs and
a session running is exactly what refreshes the file. The failure that matters
is the 5-hour window rolling over while nobody is looking: after that the stored
percentage describes a window that no longer exists and *overstates* usage. The
server compares `resets_at` against now, sets `window_expired`, and the views
show `--` and "window reset" rather than a number that is confidently wrong.

5h and 7d are account-wide, so any session's snapshot is valid for both. Context
use is captured but deliberately not displayed: it is per-session, describing
whichever session rendered last, which is a different quantity and misleading
next to two account-wide figures.

## 1. Install the capture hook

Needs `jq`. The hook is a pass-through filter: it writes `usage.json` and echoes
stdin onward, so it sits in front of whatever status line you already use.

```sh
mkdir -p ~/.claude/hooks
cp hooks/usage-capture.sh ~/.claude/hooks/
```

In `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "$HOME/.claude/hooks/usage-capture.sh | $HOME/.claude/statusline-command.sh"
  }
}
```

If you have no status line of your own, `hooks/statusline-command.sh` is a
renderer showing model, both windows and context use — copy it alongside and
point the pipe at it. Capture is best-effort and always exits 0; a broken hook
can blank the status line but never breaks Claude Code.

`CLAUDE_USAGE_FILE` overrides the output path. The server reads the same
variable, which is also how the odd states (expired window, stale reading) were
tested — by serving a fixture rather than waiting for real numbers to hit 100%.

## 2. Run the bridge

FastAPI, read-only, one endpoint. **`uv` only** — this was developed on a Debian
box without `python3-venv`, where `python3 -m venv` fails outright.

```sh
cd server
uv venv && uv pip install -r requirements.txt
./scripts/make-dev-certs.sh
.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8444 \
    --ssl-keyfile certs/server.key --ssl-certfile certs/server.crt
```

`GET /usage` returns the two percentages, minutes to reset, the age of the
capture, and the `stale` / `window_expired` flags. `GET /health` is a liveness
probe. **Nothing here can write into a Claude session, by design.**

TLS is not optional: Connect IQ rejects plain `http` with
`SECURE_CONNECTION_REQUIRED` (-1001), in the simulator as well as on the watch.
`make-dev-certs.sh` mints a throwaway CA plus a server certificate carrying the
machine's LAN IP in the SAN, and builds a bundle the simulator can trust — the
simulator does not route to loopback, so `127.0.0.1` never opens a socket at
all.

## 3. Build and run

Target device is `fenix8pro47mm` (covers 47mm, 51mm, MicroLED and quatix 8 Pro —
one ID for all four). `minApiLevel` is 5.1.0, for
`Notifications.showNotification()` with actions, which the planned question view
needs. Needs the Connect IQ SDK (≥ 7.4.3; developed against 9.2.0).

```sh
export PATH=$PATH:$(cat $HOME/.Garmin/ConnectIQ/current-sdk.cfg)/bin
make build     # headless, never needs a display
make sim       # start the simulator — separate shell, leave it running
make run       # push the build to it
```

`make build` generates `developer_key.der` on first run if absent; it is
gitignored and must stay that way. `make package` produces `bin/claudeWatch.iq`.

**The glance budget is 64 KB** and it is the constraint that shapes the code:
everything reachable from `GlanceView` carries `(:glance)`, because
un-annotated code is excluded from glance scope and that exclusion is what keeps
the view inside budget. Current use is 8.0/59.8 kB glance, 9.1/763.6 kB app.

Two simulator behaviours will silently break a request with no error pointing at
the cause: `UseHttpsRequirements=0` must be set in
`~/.Garmin/ConnectIQ/simulator.ini` (with device HTTPS rules on, a
privately-signed certificate returns `404` with `data=null`, indistinguishable
from a missing route), and app settings persist across rebuilds, so changing a
default in `resources/settings/properties.xml` has no effect until the stored
copy is cleared.

## 4. Install on the watch

`make package`, then upload `bin/claudeWatch.iq` at apps-developer.garmin.com
with **Beta App** ticked, and open the beta URL **on the phone** — it hands off
to the Connect IQ store app, which installs over Bluetooth. The dashboard's
install button and Garmin Express do not work for this, and beta apps never
appear in the IQ app's "my apps" list.

After install the glance **appends itself to the end of the glance carousel** —
it does not need adding by hand, it is just below every built-in glance. This is
not a bug; it cost an investigation once already.

### Demo mode ships enabled

A real watch **cannot** reach a dev bridge: device HTTPS rules are enforced in
firmware and reject a privately-signed certificate, with no equivalent of the
simulator's escape hatch. So `DemoMode` defaults to `true` and shows invented
figures, labelled as such in both views — a plausible fake that reads as real is
worse than an obvious error.

Turning it off needs a publicly trusted certificate in front of the bridge; a
Cloudflare Tunnel is the intended route. Set `ServerUrl` in the app settings to
that hostname, no trailing slash — the client appends `/usage`.

## Status

Usage on the wrist works. Two things are not done:

- **The bridge has no authentication.** `GET /usage` is open, and
  `UsageStore.mc` sends no request headers, so it cannot present a Cloudflare
  Access service token either. Do not expose the bridge publicly until both
  ends carry credentials.
- **Answering Claude's questions from the wrist** is designed but unbuilt: a hot
  key for the fast path, plus a background poll raising a notification with the
  options as tappable actions for when the buzz was missed. Background temporal
  events have a 5-minute platform floor, so the poll can only ever be the
  catch-up path. Question text would come from the session transcript
  (`~/.claude/projects/<slug>/<session>.jsonl`), which carries the full
  `AskUserQuestion` payload; the notification only says that a question exists.
  Answer injection hands the watch the ability to type into a live shell — it
  must stay LAN-only and token-authenticated.

`CLAUDE.md` holds the working notes: measured layout constraints, what was
verified against what was assumed, and the dead ends not worth walking again.

## License

MIT — see `LICENSE`. Not affiliated with or endorsed by Anthropic or Garmin.
