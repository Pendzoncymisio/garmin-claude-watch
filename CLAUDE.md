# claudeWatch — Claude Code on the fēnix 8 Pro

Two jobs, in build order:

1. **Usage on the wrist** — 5h limit on the glance, all limits when opened. *Done.*
2. **Answer Claude's questions from the wrist** — see the pending question and
   pick an option without walking back to the machine. *Not started.*

`README.md` is the public-facing version of this file: setup, the data flow,
and why the numbers can only be captured from the status line. This file is the
working notes — what was measured, what was tried and abandoned. Keep both in
step when either changes.

Separate app from the ICM weather project in `../garmin-app-first`: different
product, different app UUID. The two share only the device, the Makefile
pattern, and the dev-certificate approach.

## Device, memory, toolchain

Same as the weather app. That project's `CLAUDE.md` is the fuller reference for
`fenix8pro47mm`, the 64 KB glance budget, the SDK Manager `libjpeg.so.8`
workaround, and the three simulator gotchas — all of it applies here unchanged.
**It is a separate, private repo**, so a clone of this one will not have it; the
parts that matter for building are restated in `README.md`.

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

`hooks/usage-capture.sh` writes `~/.claude/usage.json` on every render (atomic
rename, best-effort, always exits 0 so it can never break the status line). It
is a **pass-through filter** — it echoes stdin onward — so it composes with an
existing status line rather than replacing it:
`usage-capture.sh | statusline-command.sh` in `settings.json`. That shape is
what lets the repo ship the capture without dictating anyone's status line;
`hooks/statusline-command.sh` is an optional renderer for people who have none.

On this machine the capture block is still inlined in
`~/.claude/statusline-command.sh` (original backed up at `.bak`) from before it
was extracted. Either arrangement works; the repo copy is the canonical one.

### There is no way to refresh on demand — this was tested, not assumed

Claude Code gets these figures from `anthropic-ratelimit-unified-*` response
headers on its own API calls and forwards them only to the status line.

- `claude -p` (headless) **does not render a status line**, so it cannot be used
  to force an update. Verified via `session_id` in `usage.json`, which does not
  change across a headless run. Watching `ts` alone is **not** a valid test: any
  live interactive session rewrites the file every few seconds, so a `ts` bump
  looks like success when nothing happened. That mistake was made here first.
- There is no `claude usage --json` (open request: anthropics/claude-code#40793),
  no local rate-limit state file, and no `claude usage` subcommand.
- `/usage` exists but is TUI-only.
- The Admin usage API covers **API-key billing**, not Pro/Max subscriptions.
- `ccusage` and similar estimate cost from transcript token counts; they do not
  read real rate-limit windows.

So tapping re-fetches from the bridge, which picks up a render that happened
since the view opened. It cannot conjure newer figures, and the app does not
pretend otherwise.

### Why stale data is still usable

Usage only grows when a session runs — and a session running is exactly what
refreshes the file. So an old reading is generally still *correct*.

The real failure is the **5h window rolling over** while nobody is looking:
after that, the stored percentage describes a window that no longer exists and
overstates usage — the one direction that matters, since the whole point is
deciding whether there is room to start working. The server compares `resets_at`
against now and sets `window_expired`; the views then show `--` and "window
reset" rather than a number that is confidently wrong.

**5h and 7d are account-wide**, so any session's snapshot is valid for both.
(Context was dropped from the app: it is per-session, describing whichever
session happened to render last, which is a different quantity and misleading
next to two account-wide figures.)

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

- **Glance**: the strip is **349 × 130** on this device and `FONT_GLANCE` is
  42px tall — about 13 characters across. Measured, not assumed. 8.0/59.8 kB.
- **The strip is a rectangle but the display is round.** The mask cuts it into a
  trapezoid: the strip sits *above* screen centre, so the usable left edge moves
  inward going up — roughly **x=45 at the top, x=30 mid, x=8 near the bottom**,
  with the right edge mirroring it. Measured by drawing full-width rules at
  eight heights and reading where each was cut (the capture is worth redoing if
  the layout changes materially; at 1:1 scale, glance x + 197 = image x).
  Consequences that already bit:
  - The title cannot sit as far left as the bottom row, however much one wants
    it to. It is set as low as the layout allows to narrow the gap.
  - Right-aligning to `w - PAD` on an upper row clips. The `%` sign vanished
    this way, leaving `54.`
  - At 100% the bar's corner gets nipped at full width, hence a larger right
    inset than left.
- **The bar is hand-drawn, and has to be.** Connect IQ has no progress-bar
  drawable: `WatchUi.ProgressBar` is a full-screen modal you `pushView`, and the
  only `Drawable` subclasses are `Bitmap`, `Text`, `TextArea` and `Selectable`.
  Garmin's own glance bars are firmware-rendered and not exposed, so a
  third-party glance can never match them exactly — thin, square and flat reads
  closer to the house style than a thick rounded pill.
- Content is centred vertically in the strip rather than top-aligned: this
  glance sits first in the carousel, where top-aligned content reads as
  floating.
- **Full view**: 9.1/763.6 kB. The 5h row is the widest thing drawn. It was
  checked at the true worst case (`5h 100% 4h58m`) and fits with **no margin
  left**. Anything added to that row must be re-checked at 100% with a >1h
  reset, or it will clip without any error.
- Both odd states were verified by serving fixtures through `CLAUDE_USAGE_FILE`
  rather than waiting for them to occur: expired window renders `5h --` plus
  "window reset", stale renders "upd 3h - no live session".
- **One font in the glance** (`FONT_GLANCE`). Mixing sizes is what made an
  earlier version look assembled rather than designed.
- Colours: the glance uses **Claude orange `0xD97757`** for the title and bar,
  white for the figure, grey for the countdown and the bar's remainder. Red at
  ≥90%. No amber tier in the glance — the base colour is already orange, so a
  third step reads as noise rather than warning. The full view still uses
  amber ≥70% / red ≥90%, where white is the base.

## Installing

`make package` produces `bin/claudeWatch.iq`; upload it at
apps-developer.garmin.com with **Beta App** ticked, then open the beta URL **on
the phone** — it hands off to the Connect IQ store app, which installs over
Bluetooth. The dashboard's install button and Garmin Express do not work for
this, and beta apps never appear in the IQ app's "my apps" list.

`type="watch-app"` is correct and the glance works. **After install the glance
appends itself to the end of the glance carousel** — it does not need adding by
hand, it is just last in the list, below every built-in glance. Do not go
looking for a bug here: this cost an investigation once already, including a
`type="widget"` rebuild that was never needed. (fēnix 8 does not list `widget`
as a supported app type at all — widgets are gone, glances replaced them.)

A real watch **cannot** reach the dev bridge: device HTTPS rules are enforced in
firmware and reject a privately signed certificate, with no equivalent of the
simulator's `UseHttpsRequirements=0`. Hence `DemoMode`, which ships enabled.
Making it show live data needs a publicly trusted certificate — a Cloudflare
Tunnel to this VM being the intended route.

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
