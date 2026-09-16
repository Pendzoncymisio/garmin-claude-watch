#!/bin/bash
#
# Capture Claude Code's rate-limit figures for the watch app.
#
# Claude Code hands the status line command a JSON blob on stdin containing the
# `anthropic-ratelimit-unified-*` figures it received on its own API calls. That
# blob is the ONLY place those numbers appear: there is no `claude usage --json`,
# no local rate-limit state file, and the Admin usage API bills API keys rather
# than Pro/Max subscriptions. So the status line is the capture point.
#
# This script is a pass-through filter: it writes the numbers to usage.json and
# echoes stdin back out unchanged, so it can sit in front of whatever status line
# renderer you already use.
#
#   ~/.claude/settings.json
#   { "statusLine": { "type": "command",
#                     "command": "$HOME/.claude/hooks/usage-capture.sh | $HOME/.claude/your-status-line.sh" } }
#
# The pipe is optional — this script works alone, it just renders nothing.
#
# Capture is best-effort and must never break the status line: every failure is
# swallowed and the exit status is always 0. The write is atomic (temp file plus
# rename) so the server never reads a half-written file.
#
# Set CLAUDE_USAGE_FILE to move the output; the server reads the same variable.
#
# ── Pushing to a bridge on another machine ─────────────────────────────────────
#
# The limits are account-wide, so the bridge can sit on one machine and take
# snapshots from every machine you run Claude Code on. On those, drop a file at
#
#   ~/.config/claude-watch/push.env        (mode 600 — it holds a secret)
#     CLAUDE_USAGE_PUSH_URL=http://bridge-host:8444
#     CLAUDE_USAGE_PUSH_TOKEN=<the bridge's CLAUDE_USAGE_PUSH_TOKEN>
#     CLAUDE_USAGE_SOURCE=this-machine     # optional; defaults to the hostname
#
# and the hook PUTs the snapshot to <URL>/usage/<source> after each write — at
# most once per CLAUDE_USAGE_PUSH_EVERY_S (default 120) unless the figures
# changed, in the background, with a short timeout, so a bridge that is down
# costs the status line nothing. Without that file nothing is pushed.

set -u

OUT="${CLAUDE_USAGE_FILE:-$HOME/.claude/usage.json}"
PUSH_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/claude-watch/push.env"

input=$(cat)

# Hand the input straight on, whatever happens below.
printf '%s' "$input"

{
    mkdir -p "$(dirname "$OUT")"
    printf '%s' "$input" | jq -c \
        --argjson ts "$(date +%s)" \
        '{ts: $ts,
          model: (.model.display_name // null),
          five_hour: {pct: (.rate_limits.five_hour.used_percentage // null),
                      resets_at: (.rate_limits.five_hour.resets_at // null)},
          seven_day: {pct: (.rate_limits.seven_day.used_percentage // null),
                      resets_at: (.rate_limits.seven_day.resets_at // null)},
          context: {used_pct: (.context_window.used_percentage // null),
                    total_tokens: (.context_window.total_input_tokens // null)},
          session_id: (.session_id // null),
          cwd: (.workspace.current_dir // .cwd // null)}' \
        > "$OUT.tmp" 2>/dev/null \
        && mv -f "$OUT.tmp" "$OUT"
} 2>/dev/null || true

push() {
    [ -r "$PUSH_ENV" ] && [ -s "$OUT" ] || return 0
    # Read KEY=VALUE lines rather than sourcing the file: nothing in it gets
    # executed, and a value with a space or an '=' in it survives intact.
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            CLAUDE_USAGE_PUSH_URL|CLAUDE_USAGE_PUSH_TOKEN|CLAUDE_USAGE_SOURCE|CLAUDE_USAGE_PUSH_EVERY_S)
                v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
                printf -v "$k" '%s' "$v" ;;
        esac
    done < "$PUSH_ENV"
    [ -n "${CLAUDE_USAGE_PUSH_URL:-}" ] && [ -n "${CLAUDE_USAGE_PUSH_TOKEN:-}" ] || return 0

    local source now key mark last_at last_key
    source="${CLAUDE_USAGE_SOURCE:-$(hostname -s 2>/dev/null || hostname)}"
    source="$(printf '%s' "$source" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '-' | cut -c1-32)"
    now=$(date +%s)

    # Only the account-wide figures decide whether a push is worth making; the
    # timestamp is refreshed anyway by the periodic push, so age stays honest.
    key=$(jq -c '{model, five_hour, seven_day}' "$OUT") || return 0
    mark="$OUT.pushed"
    if [ -r "$mark" ]; then
        read -r last_at last_key < "$mark" || true
        if [ "${last_key:-}" = "$key" ] \
           && [ $(( now - ${last_at:-0} )) -lt "${CLAUDE_USAGE_PUSH_EVERY_S:-120}" ]; then
            return 0
        fi
    fi
    printf '%s %s\n' "$now" "$key" > "$mark.tmp" && mv -f "$mark.tmp" "$mark"

    # Detached: the status line must not wait on the network. The token goes
    # in a header, never on the command line where `ps` could show it.
    curl -sS -m 3 -o /dev/null -X PUT \
        -H @<(printf 'Authorization: Bearer %s\n' "$CLAUDE_USAGE_PUSH_TOKEN") \
        -H 'Content-Type: application/json' \
        --data-binary @"$OUT" \
        "${CLAUDE_USAGE_PUSH_URL%/}/usage/$source" >/dev/null 2>&1 </dev/null &
}

push 2>/dev/null || true

exit 0
