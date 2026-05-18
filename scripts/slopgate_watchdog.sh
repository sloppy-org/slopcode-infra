#!/usr/bin/env bash
# Primary slopgate watchdog — runs every 5 min on the leader (faepmac1) via
# launchd. Checks the balancer, management API, agent population, launchd
# services, and local disk; posts to Zulip on state transitions only.
# Heartbeat is pushed out-of-band via SSH to the chat host so it never
# touches Zulip; the reverse watchdog stats that file's mtime.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/slopgate_watchdog_lib.sh"

BALANCER_ADDR="${SLOPGATE_BALANCER_ADDR:-127.0.0.1:8080}"
MGMT_ADDR="${SLOPGATE_MGMT_ADDR:-127.0.0.1:8085}"
REQUIRED_LAUNCHD="${SLOPGATE_LAUNCHD_LABELS:-com.slopcode.slopgate-balancer com.slopcode.slopgate-agent}"
MIN_AGENTS="${SLOPGATE_MIN_AGENTS:-1}"
DISK_THRESHOLD="${SLOPGATE_DISK_THRESHOLD:-85}"

_check_balancer() {
    http_check "http://$BALANCER_ADDR/v1/models" "200"
}

_check_management() {
    http_check "http://$MGMT_ADDR/healthz" "200"
}

_check_agents() {
    local json count
    json=$(curl -sk --max-time 10 "http://$MGMT_ADDR/api/v1/monitor" 2>/dev/null || echo "")
    if [[ -z "$json" ]]; then
        printf 'could not read /api/v1/monitor on %s' "$MGMT_ADDR"
        return 1
    fi
    count=$(echo "$json" | grep -o '"usable_agents":[0-9]*' | head -1 | grep -o '[0-9]*')
    count="${count:-0}"
    if [[ "$count" -ge "$MIN_AGENTS" ]]; then return 0; fi
    printf 'usable_agents=%s (threshold %s)' "$count" "$MIN_AGENTS"
    return 1
}

_check_launchd() {
    local missing="" label state
    for label in $REQUIRED_LAUNCHD; do
        state=$(launchctl list 2>/dev/null | awk -v l="$label" '$3==l{print $1"|"$2}')
        if [[ -z "$state" ]]; then
            missing="$missing $label(absent)"
            continue
        fi
        local pid="${state%%|*}" last="${state##*|}"
        if [[ "$pid" == "-" || "$pid" == "0" ]]; then
            missing="$missing $label(not-running,last_exit=$last)"
        fi
    done
    if [[ -z "$missing" ]]; then return 0; fi
    printf 'launchd services degraded:%s' "$missing"
    return 1
}

_check_disk() {
    local pct
    pct=$(df -P / 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
    if [[ -z "$pct" ]]; then
        printf 'could not read local disk usage'
        return 1
    fi
    if [[ "$pct" -lt "$DISK_THRESHOLD" ]]; then return 0; fi
    printf 'leader / disk %s%% (threshold %s%%)' "$pct" "$DISK_THRESHOLD"
    return 1
}

run_check() {
    local comp="$1"; shift
    local detail now since msg_id fail_msg_id
    state_read "$comp"
    fail_msg_id="$STATE_MSG_ID"

    if detail=$("$@" 2>/dev/null); then
        if [[ "$STATE_STATUS" == "fail" ]]; then
            now=$(date +%s)
            msg_id=$(zulip_post "$comp" "$(ok_msg "$comp" "$STATE_SINCE" "$now")")
            # Resolve the incident topic. Prefer the original fail msg id;
            # fall back to the recovery msg id if state was missing it.
            zulip_resolve_topic "${fail_msg_id:-$msg_id}" "$comp" || true
            state_write "$comp" "ok" "$now" "" || true
        fi
        return 0
    else
        now=$(date +%s)
        if [[ "$STATE_STATUS" == "ok" ]]; then
            since=$now
            local content
            content=$(fail_msg "$comp" "$detail" "$(ts_to_iso "$since")")
            msg_id=$(zulip_post "$comp" "$content" "[slopgate-watchdog] FAIL: $comp")
            state_write "$comp" "fail" "$since" "$msg_id" || true
        fi
        return 1
    fi
}

main() {
    local all_ok=1

    run_check "slopgate-balancer"   _check_balancer    || all_ok=0
    run_check "slopgate-management" _check_management  || all_ok=0
    run_check "slopgate-agents"     _check_agents      || all_ok=0
    run_check "slopgate-launchd"    _check_launchd     || all_ok=0
    run_check "slopgate-disk"       _check_disk        || all_ok=0

    if [[ "$all_ok" -eq 1 ]]; then
        mkdir -p "$WATCHDOG_STATE_DIR"
        touch "$WATCHDOG_STATE_DIR/last-ok"
        local tick_file="$WATCHDOG_STATE_DIR/tick_count.txt"
        local ticks=0
        [[ -f "$tick_file" ]] && ticks=$(cat "$tick_file")
        echo $(( ticks + 1 )) > "$tick_file"
        _heartbeat_push_remote
    fi
}

main "$@"
