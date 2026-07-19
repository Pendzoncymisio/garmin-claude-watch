# claudeWatch — Claude Code on the fēnix 8 Pro

Two jobs, in build order:

1. **Usage on the wrist** — 5h limit on the glance, all limits when opened. *Done.*
2. **Answer Claude's questions from the wrist** — see the pending question and
   pick an option without walking back to the machine. *Not started.*

Separate app from the ICM weather project in `../garmin-app-first`: different
product, different app UUID. The two share only the device, the Makefile
pattern, and the dev-certificate approach.

## Device, memory, toolchain

Same as the weather app — see `../garmin-app-first/CLAUDE.md`, which is the
fuller reference for `fenix8pro47mm`, the 64 KB glance budget, the SDK Manager
`libjpeg.so.8` workaround, and the three simulator gotchas. All of it applies
here unchanged.

`minApiLevel` is **5.1.0**, not 3.3.0: `Notifications.showNotification()` with
actions — which step 3 needs — arrived in 5.1.0.

```sh
export PATH=$PATH:$(cat $HOME/.Garmin/ConnectIQ/current-sdk.cfg)/bin
make build
make sim     # separate shell, leave running
make run
```

## Where the usage numbers come from

**Claude Code pushes them; nothing can pull them.** The rate-limit and context
figures arrive as stdin JSON to the status line command and are available
nowhere else — no API, no file, no env var. So the capture point is the status
line itself.

`~/.claude/statusline-command.sh` writes `~/.claude/usage.json` on every render
(atomic rename, best-effort, never breaks the status line). A backup of the
original is at `statusline-command.sh.bak`.

Consequences worth remembering:

- **The data is only as fresh as the last status-line render.** No session
  running means no updates. The server reports `age_s` and sets `stale` past
  15 minutes; the glance appends `?` and the full view says "no live session".
  Without that the watch would present an hours-old number as current.
- **5h and 7d are account-wide, context is per-session.** Any session's snapshot
  is valid for the limits. `ctx` describes whichever session rendered last,
  which is a genuinely different thing — do not present it as global.

## Server — `server/`

FastAPI, read-only, `uv` only (never `python3 -m venv`; `python3-venv` is not
installed on this VM).

```sh
cd server
uv venv && uv pip install -r requirements.txt
./scripts/make-dev-certs.sh
.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8444 \
    --ssl-keyfile certs/server.key --ssl-certfile certs/server.crt
```

`CLAUDE_USAGE_FILE` overrides the input path — used to serve a fixture when
testing worst-case layouts without waiting for real numbers to hit 100%.

**Nothing here can write to the session, by design.** Answer injection is step 4
and is a different security class: it hands the watch the ability to type into a
live shell. It must stay LAN-only, token-authenticated, and must never be
exposed through a public tunnel.

## Layout constraints, verified not assumed

- **Glance**: `5h 45%` at 7.3/59.8 kB. Text overrunning the strip is clipped
  silently — not wrapped, not shrunk.
- **Full view**: 8.2/763.6 kB. The 5h row is the widest thing drawn. It was
  checked at the true worst case (`5h 100% 4h58m`) and fits with **no margin
  left**. Anything added to that row must be re-checked at 100% with a >1h
  reset, or it will clip without any error.
- Colour thresholds: amber ≥70%, red ≥90% — deliberately pessimistic, so the
  glance reads without being read.

## Steps 2–4 (planned)

Chosen approach is **A + C** — they compose, and neither needs a companion phone
app:

- **C — hot key.** Claude's existing phone push already buzzes the wrist. Assign
  the app to a fēnix hot key: buzz → hold key → app opens on the pending
  question → tap an option. Instant, no new infrastructure.
- **A — background poll + action notification.** `Background` temporal events
  have a **5 minute platform minimum**, so this cannot be the fast path — it is
  the catch-you-when-you-missed-the-buzz path.
  `Notifications.showNotification()` posts the options as tappable actions and
  `registerForNotificationMessages()` receives the choice, queued if the app is
  not running.

Rejected: a companion Android app driving `registerForPhoneAppMessageEvent` for
instant wake. It is the only way to beat the 5 minute floor, but it is a whole
second codebase and C already covers the fast case.

**When adding the `Background` permission**, annotate source `(:background)` at
the same time. Granting it with nothing annotated makes the compiler load the
entire app as a background process, which drops `GlanceView`/`View` out of scope
and produces confusing "not available in all function scopes" errors.

Question text comes from the **session transcript**
(`~/.claude/projects/<slug>/<session>.jsonl`), not from a hook: the transcript
carries the full `AskUserQuestion` payload — question, headers, every option
label and description — whereas the notification only says a question exists.
There is no `PreAskUserQuestion` hook, and `PreToolUse` cannot supply a result.
