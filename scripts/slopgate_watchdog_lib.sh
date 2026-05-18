# shellcheck shell=bash
# Shared helpers for slopgate watchdog scripts. Source after set -euo pipefail.
# Mirror of computor-infra/scripts/watchdog_lib.sh, with slopgate-scoped
# defaults so the two watchdogs share the same monitoring stream but keep
# independent state, zuliprc paths, and admin group mentions.
# Not executable directly.

WATCHDOG_ZULIP_STREAM="${WATCHDOG_ZULIP_STREAM:-monitoring}"
WATCHDOG_ZULIPRC="${WATCHDOG_ZULIPRC:-$HOME/.config/slopgate-watchdog/zuliprc}"
WATCHDOG_STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/.local/share/slopgate-watchdog}"
WATCHDOG_INCIDENT_MAIL="${WATCHDOG_INCIDENT_MAIL:-}"
WATCHDOG_SMTP_FROM="${WATCHDOG_SMTP_FROM:-albert@tugraz.at}"
WATCHDOG_ADMINS_GROUP="${WATCHDOG_ADMINS_GROUP:-computor-admins}"

_ZULIP_EMAIL=""
_ZULIP_KEY=""
_ZULIP_SITE=""

_zulip_init() {
    [[ -n "$_ZULIP_EMAIL" ]] && return 0
    if [[ ! -f "$WATCHDOG_ZULIPRC" ]]; then
        echo "slopgate-watchdog: zuliprc not found: $WATCHDOG_ZULIPRC" >&2; return 1
    fi
    _ZULIP_EMAIL=$(grep -E '^email' "$WATCHDOG_ZULIPRC" | head -1 | sed 's/.*=[ \t]*//' | tr -d '[:space:]')
    _ZULIP_KEY=$(grep -E '^key'   "$WATCHDOG_ZULIPRC" | head -1 | sed 's/.*=[ \t]*//' | tr -d '[:space:]')
    _ZULIP_SITE=$(grep -E '^site' "$WATCHDOG_ZULIPRC" | head -1 | sed 's/.*=[ \t]*//' | tr -d '[:space:]')
}

# http_check URL EXPECT_CODE
http_check() {
    local url="$1" expect="$2"
    local got
    got=$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")
    if [[ "$got" == "$expect" ]]; then return 0; fi
    printf 'HTTP %s on %s (want %s)' "$got" "$url" "$expect"
    return 1
}

# zulip_post TOPIC CONTENT [MAIL_SUBJECT]
zulip_post() {
    local topic="$1" content="$2" mail_subj="${3:-[slopgate-watchdog] $1}"
    _zulip_init || { _msmtp_send "$mail_subj" "$content"; return; }
    local resp msg_id
    resp=$(curl -s --max-time 10 \
        -u "$_ZULIP_EMAIL:$_ZULIP_KEY" \
        --data-urlencode "type=stream" \
        --data-urlencode "to=$WATCHDOG_ZULIP_STREAM" \
        --data-urlencode "topic=$topic" \
        --data-urlencode "content=$content" \
        "$_ZULIP_SITE/api/v1/messages" 2>/dev/null || echo '{"result":"error","msg":"curl failed"}')
    if echo "$resp" | grep -q '"result":"success"'; then
        msg_id=$(echo "$resp" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
        echo "${msg_id:-0}"
    else
        echo "slopgate-watchdog: Zulip post failed ($topic): $resp" >&2
        _msmtp_send "$mail_subj" "$content"
        echo "0"
    fi
}

# zulip_edit MSG_ID CONTENT
zulip_edit() {
    local msg_id="$1" content="$2"
    [[ -z "$msg_id" || "$msg_id" == "0" ]] && return 1
    _zulip_init || return 1
    curl -s --max-time 10 \
        -u "$_ZULIP_EMAIL:$_ZULIP_KEY" \
        -X PATCH \
        --data-urlencode "content=$content" \
        "$_ZULIP_SITE/api/v1/messages/$msg_id" >/dev/null 2>&1 || true
}

# zulip_newest_msg_ts TOPIC
zulip_newest_msg_ts() {
    local topic="$1"
    _zulip_init || { echo 0; return; }
    local narrow resp ts
    narrow="$(printf '[{"operator":"stream","operand":"%s"},{"operator":"topic","operand":"%s"}]' \
        "$WATCHDOG_ZULIP_STREAM" "$topic")"
    resp=$(curl -s --max-time 10 \
        -u "$_ZULIP_EMAIL:$_ZULIP_KEY" \
        -G \
        --data-urlencode "narrow=$narrow" \
        -d "anchor=newest" \
        -d "num_before=1" \
        -d "num_after=0" \
        "$_ZULIP_SITE/api/v1/messages" 2>/dev/null || echo '{}')
    ts=$(echo "$resp" | grep -o '"last_edit_timestamp":[0-9]*' | tail -1 | grep -o '[0-9]*')
    [[ -z "$ts" ]] && ts=$(echo "$resp" | grep -o '"timestamp":[0-9]*' | tail -1 | grep -o '[0-9]*')
    echo "${ts:-0}"
}

# state_read COMPONENT → sets STATE_STATUS STATE_SINCE STATE_MSG_ID
state_read() {
    local f="$WATCHDOG_STATE_DIR/$1.state"
    STATE_STATUS="ok"; STATE_SINCE="0"; STATE_MSG_ID=""
    if [[ -f "$f" ]]; then
        STATE_STATUS=$(sed -n '1p' "$f")
        STATE_SINCE=$(sed -n '2p' "$f")
        STATE_MSG_ID=$(sed -n '3p' "$f")
    fi
}

# state_write COMPONENT STATUS SINCE_EPOCH MSG_ID
state_write() {
    mkdir -p "$WATCHDOG_STATE_DIR"
    printf '%s\n%s\n%s\n' "$2" "$3" "${4:-}" > "$WATCHDOG_STATE_DIR/$1.state"
}

ts_to_iso() {
    date -u -r "$1" "+%Y-%m-%dT%H:%MZ" 2>/dev/null || date -u -d "@$1" "+%Y-%m-%dT%H:%MZ"
}

fail_msg() {
    local component="$1" detail="$2" since_iso="$3"
    printf ':rotating_light: **FAIL** %s — %s (since %s)\n\n@*%s*\n\nReact :hammer_and_wrench: to claim. Others stand down. Recovery will be posted in this topic.' \
        "$component" "$detail" "$since_iso" "$WATCHDOG_ADMINS_GROUP"
}

ok_msg() {
    local component="$1" since_epoch="$2" now_epoch="$3"
    local min=$(( (now_epoch - since_epoch) / 60 ))
    printf ':check: **OK** %s restored at %s (%dm outage)' \
        "$component" "$(ts_to_iso "$now_epoch")" "$min"
}

_msmtp_send() {
    [[ -z "$WATCHDOG_INCIDENT_MAIL" ]] && return 0
    local subject="$1" body="$2"
    {
        printf 'To: %s\nFrom: Slopgate watchdog <%s>\nSubject: %s\nContent-Type: text/plain; charset=utf-8\n\n%s\n' \
            "$WATCHDOG_INCIDENT_MAIL" "$WATCHDOG_SMTP_FROM" "$subject" "$body"
    } | msmtp --read-envelope-from -t 2>&1 | head -5 >&2 || true
}
