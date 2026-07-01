#!/usr/bin/env bash
# Decide whether the two-Mac GLM cluster is idle enough to run autonomous work.
#
# Idle means, on BOTH faepmac1 and faepmac2:
#   - no interactive input for IDLE_SECONDS (HID idle >= IDLE_SECONDS): screen
#     locked, logged out, or a human sitting inactive all count as idle;
#   - no significant compute job (1-min load average below LOAD_FRAC * cores):
#     an idle Chrome/Safari holding RAM does NOT count as busy, it is a cleanup
#     target;
#   - slopgate is not currently serving requests (nobody mid-delegation).
#
# The HID threshold already encodes IDLE_SECONDS of input stability, so that is
# the "idle for 30 minutes" gate. GLM_IDLE_SETTLE (default 0) optionally
# requires the whole idle picture to hold that many extra seconds across ticks
# as a flap guard. A bare ssh/tmux session that generates no load is idle.
#
# check   exit 0 when idle (and settled), 1 otherwise; one-line reason on stderr
# status  human-readable breakdown of every signal, both hosts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

ACTION="${1:-check}"
PEER="${GLM_PEER_HOST:-10.78.5.2}"
REMOTE="${GLM_IDLE_REMOTE:-true}"
IDLE_SECONDS="${IDLE_SECONDS:-1800}"
SETTLE_SECONDS="${GLM_IDLE_SETTLE:-0}"
LOAD_FRAC="${GLM_IDLE_LOAD_FRAC:-0.30}"
SLOPGATE_METRICS="${SLOPGATE_METRICS:-http://127.0.0.1:8080/metrics}"
SINCE_FILE="${RUN_DIR}/glm-idle-since"

# HID idle seconds on a host. macOS only; ioreg reports nanoseconds since the
# last human input event.
hid_idle_local() {
  ioreg -c IOHIDSystem 2>/dev/null \
    | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'
}

hid_idle_remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=6 "${PEER}" \
    "ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int(\$NF/1000000000); exit}'"
}

# 1-minute load average.
load1_local() { sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'; }
load1_remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=6 "${PEER}" \
    "sysctl -n vm.loadavg 2>/dev/null | awk '{print \$2}'"
}

cores_local() { detect_physical_cores; }
cores_remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=6 "${PEER}" \
    "sysctl -n hw.physicalcpu 2>/dev/null || echo 1"
}

# True when slopgate reports any deferred request or a busy agent slot, i.e. a
# human is delegating right now. Unreachable metrics are treated as quiet.
slopgate_busy() {
  local text
  text="$(curl -s -m4 "${SLOPGATE_METRICS}" 2>/dev/null || true)"
  [[ -n "${text}" ]] || return 1
  awk '
    /^llamacpp:requests_deferred / { if ($2+0 > 0) busy=1 }
    /^slopgate_agent_slots_active / { if ($2+0 > 0) busy=1 }
    END { exit busy?0:1 }
  ' <<<"${text}"
}

# Instantaneous idle on one host: input idle >= threshold AND load below the
# per-core fraction. Echoes "idle" or a reason.
host_idle() {
  local name="$1" hid="$2" load="$3" cores="$4" thresh
  if [[ -z "${hid}" || -z "${load}" || ! "${hid}" =~ ^[0-9]+$ ]]; then
    echo "${name}: unreachable"
    return 1
  fi
  if (( hid < IDLE_SECONDS )); then
    echo "${name}: active input ${hid}s ago (< ${IDLE_SECONDS}s)"
    return 1
  fi
  thresh="$(awk -v c="${cores:-1}" -v f="${LOAD_FRAC}" 'BEGIN{printf "%.2f", c*f}')"
  if awk -v l="${load}" -v t="${thresh}" 'BEGIN{exit (l+0 > t+0)?0:1}'; then
    echo "${name}: load ${load} above ${thresh}"
    return 1
  fi
  echo "${name}: idle (input ${hid}s, load ${load} <= ${thresh})"
  return 0
}

gather() {
  L_HID="$(hid_idle_local || true)"
  L_LOAD="$(load1_local || true)"
  L_CORES="$(cores_local || true)"
  if [[ "${REMOTE}" == "true" ]]; then
    R_HID="$(hid_idle_remote 2>/dev/null || true)"
    R_LOAD="$(load1_remote 2>/dev/null || true)"
    R_CORES="$(cores_remote 2>/dev/null || true)"
  else
    R_HID="${IDLE_SECONDS}"; R_LOAD="0.0"; R_CORES="1"
  fi
}

# Instantaneous idle across both hosts and slopgate. Sets REASON.
instant_idle() {
  local l r
  l="$(host_idle faepmac1 "${L_HID}" "${L_LOAD}" "${L_CORES}")" || { REASON="$l"; return 1; }
  r="$(host_idle faepmac2 "${R_HID}" "${R_LOAD}" "${R_CORES}")" || { REASON="$r"; return 1; }
  if slopgate_busy; then REASON="slopgate serving requests"; return 1; fi
  REASON="both hosts idle, slopgate quiet"
  return 0
}

case "${ACTION}" in
  check)
    gather
    now="$(date +%s)"
    if instant_idle; then
      if (( SETTLE_SECONDS <= 0 )); then
        rm -f "${SINCE_FILE}"
        echo "idle: ${REASON}" >&2
        exit 0
      fi
      since="$(cat "${SINCE_FILE}" 2>/dev/null || echo "${now}")"
      boot="$(sysctl -n kern.boottime 2>/dev/null | sed -nE 's/^[{ ]*sec = ([0-9]+).*/\1/p')"
      if [[ ! "${since}" =~ ^[0-9]+$ ]] || (( since > now )) \
         || { [[ -n "${boot}" ]] && (( since < boot )); }; then
        since="${now}"
      fi
      echo "${since}" >"${SINCE_FILE}"
      held=$(( now - since ))
      if (( held >= SETTLE_SECONDS )); then
        echo "idle: ${REASON}, settled ${held}s" >&2
        exit 0
      fi
      echo "settling: ${REASON}, ${held}s/${SETTLE_SECONDS}s" >&2
      exit 1
    fi
    rm -f "${SINCE_FILE}"
    echo "busy: ${REASON}" >&2
    exit 1
    ;;
  status)
    gather
    echo "faepmac1: hid_idle=${L_HID:-?}s load1=${L_LOAD:-?} cores=${L_CORES:-?}"
    echo "faepmac2: hid_idle=${R_HID:-?}s load1=${R_LOAD:-?} cores=${R_CORES:-?}"
    if slopgate_busy; then echo "slopgate: serving"; else echo "slopgate: quiet/unreachable"; fi
    echo "threshold: IDLE_SECONDS=${IDLE_SECONDS} SETTLE_SECONDS=${SETTLE_SECONDS} LOAD_FRAC=${LOAD_FRAC}"
    if instant_idle; then echo "instant: idle (${REASON})"; else echo "instant: busy (${REASON})"; fi
    [[ -f "${SINCE_FILE}" ]] && echo "idle_since: $(cat "${SINCE_FILE}") (held $(( $(date +%s) - $(cat "${SINCE_FILE}") ))s)"
    ;;
  *)
    echo "usage: $0 {check|status}" >&2
    exit 2
    ;;
esac
