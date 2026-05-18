#!/usr/bin/env bash
# Reverse slopgate watchdog — runs every 10 min on chat.computor.at via
# systemd timer. Checks that the primary heartbeat topic was updated within
# 15 min and pages if not.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/slopgate_watchdog_lib.sh"

WATCHDOG_ZULIPRC="${WATCHDOG_ZULIPRC:-/etc/slopbot/zuliprc}"
WATCHDOG_STATE_DIR="${WATCHDOG_STATE_DIR:-/var/lib/slopgate-watchdog}"

MAX_STALE=900   # 15 min
COMP="slopgate-watchdog-primary"
HEARTBEAT_TOPIC="slopgate-heartbeat"

main() {
    local ts now detail msg
    ts=$(zulip_newest_msg_ts "$HEARTBEAT_TOPIC")
    now=$(date +%s)

    state_read "$COMP"

    if [[ "$ts" -gt 0 && $(( now - ts )) -le $MAX_STALE ]]; then
        if [[ "$STATE_STATUS" == "fail" ]]; then
            local fail_msg_id="$STATE_MSG_ID"
            msg=$(zulip_post "slopgate-watchdog dead" "$(ok_msg "$COMP" "$STATE_SINCE" "$now")")
            zulip_resolve_topic "${fail_msg_id:-$msg}" "slopgate-watchdog dead" || true
            state_write "$COMP" "ok" "$now" "" || true
        fi
    else
        if [[ "$STATE_STATUS" == "ok" ]]; then
            if [[ "$ts" -eq 0 ]]; then
                detail="no heartbeat message found in topic $HEARTBEAT_TOPIC"
            else
                detail="heartbeat stale: last seen $(( (now - ts) / 60 ))m ago (threshold 15m)"
            fi
            local content
            content="$(fail_msg "$COMP" "$detail" "$(ts_to_iso "$now")")"
            msg=$(zulip_post "slopgate-watchdog dead" "$content" "[slopgate-watchdog] PRIMARY WATCHDOG SILENT")
            state_write "$COMP" "fail" "$now" "$msg" || true
        fi
    fi
}

main "$@"
