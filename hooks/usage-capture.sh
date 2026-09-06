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

set -u

OUT="${CLAUDE_USAGE_FILE:-$HOME/.claude/usage.json}"

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

exit 0
