#!/usr/bin/env bash
# Weekly slopgate summary — runs Mon 06:00 on the leader via launchd.
# Always posts a Markdown ring-state report; silence on Monday = dead-man signal.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/slopgate_watchdog_lib.sh"

TICK_FILE="$WATCHDOG_STATE_DIR/tick_count.txt"
LAST_OK="$WATCHDOG_STATE_DIR/last-ok"

ticks=0
[[ -f "$TICK_FILE" ]] && ticks=$(cat "$TICK_FILE")

last_ok_age="unknown"
if [[ -f "$LAST_OK" ]]; then
    lo_ts=$(date -r "$LAST_OK" +%s 2>/dev/null || stat -c %Y "$LAST_OK" 2>/dev/null || echo 0)
    last_ok_age="$(( ($(date +%s) - lo_ts) / 60 ))m ago"
fi

checks="slopgate-balancer slopgate-management slopgate-agents slopgate-launchd slopgate-disk"
rows=""
for comp in $checks; do
    state_read "$comp"
    icon=":white_check_mark:"
    [[ "$STATE_STATUS" == "fail" ]] && icon=":rotating_light:"
    since_str=""
    [[ "$STATE_SINCE" != "0" && -n "$STATE_SINCE" ]] && since_str=" (since $(ts_to_iso "$STATE_SINCE"))"
    rows="${rows}| ${icon} | \`${comp}\` | ${STATE_STATUS}${since_str} |\n"
done

report="**Slopgate watchdog — weekly summary** $(date -u "+%Y-%m-%d %H:%MZ")

| | check | status |
|---|---|---|
${rows}
- Ticks since last summary: **${ticks}** (5-min intervals, expected ~2016/week)
- Last all-OK tick: ${last_ok_age}

This post appearing is the success signal. No post Monday morning → investigate."

zulip_post "slopgate weekly summary" "$report" "[slopgate-watchdog] weekly summary $(date -u +%Y-%m-%d)"

echo 0 > "$TICK_FILE"
