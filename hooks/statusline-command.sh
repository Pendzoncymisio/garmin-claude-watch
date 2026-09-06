#!/bin/bash
#
# Optional: a status line renderer showing model, both rate-limit windows and
# context use. Nothing in the watch app depends on it — the capture is done by
# usage-capture.sh, which this script is meant to sit behind:
#
#   "command": "$HOME/.claude/hooks/usage-capture.sh | $HOME/.claude/hooks/statusline-command.sh"
#
# If you already have a status line you like, keep it and put usage-capture.sh
# in front of it instead. Times are rendered in the machine's local zone.

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // empty')

# Rate limits are present for Claude.ai subscriptions and absent otherwise.
five_pct=$(echo  "$input" | jq -r '.rate_limits.five_hour.used_percentage  // empty')
five_rst=$(echo  "$input" | jq -r '.rate_limits.five_hour.resets_at        // empty')
week_pct=$(echo  "$input" | jq -r '.rate_limits.seven_day.used_percentage  // empty')
week_rst=$(echo  "$input" | jq -r '.rate_limits.seven_day.resets_at        // empty')

ctx_used=$(echo  "$input" | jq -r '.context_window.used_percentage      // empty')
ctx_rem=$(echo   "$input" | jq -r '.context_window.remaining_percentage // empty')
ctx_total=$(echo "$input" | jq -r '.context_window.total_input_tokens   // empty')
ctx_size=$(echo  "$input" | jq -r '.context_window.context_window_size  // empty')

# Format a unix epoch in local time, or "soon" when under a minute away.
# $2 is a strftime format; GNU date first, BSD date as the fallback.
fmt_reset() {
    local epoch="$1" fmt="$2" now diff
    [ -z "$epoch" ] && return
    now=$(date +%s)
    diff=$(( epoch - now ))
    if [ "$diff" -le 60 ] 2>/dev/null; then
        echo "soon"
    else
        date -d "@${epoch}" +"$fmt" 2>/dev/null || date -r "${epoch}" +"$fmt" 2>/dev/null
    fi
}

fmt_num() {
    printf "%'.0f" "$1" 2>/dev/null || echo "$1"
}

parts=()

if [ -n "$model" ]; then
    parts+=( "$(printf '\033[01;36m%s\033[00m' "$model")" )
fi

if [ -n "$five_pct" ]; then
    label="5h: $(printf '%.0f' "$five_pct")% used"
    rst=$(fmt_reset "$five_rst" "%H:%M")
    [ -n "$rst" ] && label="${label} (resets ${rst})"
    parts+=( "$(printf '\033[01;33m%s\033[00m' "$label")" )
fi

if [ -n "$week_pct" ]; then
    label="7d: $(printf '%.0f' "$week_pct")% used"
    rst=$(fmt_reset "$week_rst" "%a %H:%M")
    [ -n "$rst" ] && label="${label} (resets ${rst})"
    parts+=( "$(printf '\033[01;33m%s\033[00m' "$label")" )
fi

if [ -n "$ctx_used" ] && [ -n "$ctx_rem" ]; then
    label="ctx: $(printf '%.1f' "$ctx_used")% used"
    if [ -n "$ctx_total" ] && [ -n "$ctx_size" ]; then
        label="${label} ($(fmt_num "$ctx_total")/$(fmt_num "$ctx_size") tok)"
    fi
    parts+=( "$(printf '\033[01;35m%s\033[00m' "$label")" )
fi

sep="$(printf '\033[00m | ')"
result=""
for part in "${parts[@]}"; do
    if [ -z "$result" ]; then result="$part"; else result="${result}${sep}${part}"; fi
done

printf "%s\033[00m" "$result"
