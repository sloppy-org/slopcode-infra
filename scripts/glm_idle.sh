#!/usr/bin/env bash
# Decide whether the two-Mac GLM cluster is idle enough to run autonomous work.
#
# Idle is about resources, not people. Work runs whenever there is no
# significant compute or memory load beyond GLM itself. Interacting with a
# machine (editing, or chatting with Claude/Codex over ssh/tmux) does NOT make
# it busy; only real load does. Concretely, on BOTH faepmac1 and faepmac2:
#   - non-GLM CPU (sum of %CPU over processes that are not exo/mlx/GLM/this
#     worker) below BUSY_CPU, and
#   - no memory pressure beyond GLM: swap in use below SWAP_BUSY_MB (GLM is
#     sized to fit in RAM, so swap grows only when something else overcommits),
#   - and slopgate is not serving requests (nobody is delegating inference).
# The whole picture must hold for IDLE_SECONDS before work starts.
#
# check   exit 0 when idle (and held IDLE_SECONDS), 1 otherwise; reason on stderr
# status  human-readable breakdown of every signal, both hosts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

ACTION="${1:-check}"
PEER="${GLM_PEER_HOST:-10.78.5.2}"
REMOTE="${GLM_IDLE_REMOTE:-true}"
IDLE_SECONDS="${IDLE_SECONDS:-1800}"
BUSY_CPU="${GLM_IDLE_BUSY_CPU:-150}"
SWAP_BUSY_MB="${GLM_IDLE_SWAP_MB:-4096}"
SLOPGATE_METRICS="${SLOPGATE_METRICS:-http://127.0.0.1:8080/metrics}"
SINCE_FILE="${RUN_DIR}/glm-idle-since"

# Processes that do NOT count as load: GLM (exo/mlx), this worker, and
# kernel_task (spikes on thermal management, not user work).
GLM_EXCLUDE_RE='exo|mlx|GLM-5.2|glm_autonomous|glm_idle|kernel_task'

# Sum of %CPU across processes other than GLM/worker/kernel. %CPU is per-core,
# so 100 == one core fully busy.
nonglm_cpu_local() {
  ps -axo %cpu,command 2>/dev/null \
    | awk -v re="${GLM_EXCLUDE_RE}" 'NR>1 && $0 !~ re { s+=$1 } END { printf "%d", s+0 }'
}

# Swap in use, MB.
swap_local() { sysctl -n vm.swapusage 2>/dev/null | sed -nE 's/.*used = ([0-9]+)\..*/\1/p'; }

# Probe faepmac2 over Thunderbolt in one ssh: "nonglm_cpu swap". The TB link
# powers down while the cluster is idle, so wake it with a ping and retry a few
# times before giving up (a cold single ssh can hit "no route to host").
remote_probe() {
  local out
  for _ in 1 2 3; do
    ping -c1 -t2 "${PEER}" >/dev/null 2>&1 || true
    out="$(ssh -o BatchMode=yes -o ConnectTimeout="${GLM_SSH_TIMEOUT:-10}" "${PEER}" \
      'cpu=$(ps -axo %cpu,command 2>/dev/null | awk "NR>1 && \$0 !~ /exo|mlx|GLM-5.2|glm_autonomous|glm_idle|kernel_task/ { s+=\$1 } END { printf \"%d\", s+0 }"); swap=$(sysctl -n vm.swapusage 2>/dev/null | sed -nE "s/.*used = ([0-9]+)\..*/\1/p"); echo "$cpu ${swap:-0}"' \
      2>/dev/null || true)"
    [[ "$out" =~ ^[0-9] ]] && { printf '%s' "$out"; return 0; }
    sleep 1
  done
  printf '%s' "$out"
}

# True when slopgate is deferring or has a busy agent slot (someone delegating).
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

# Idle on one host: non-GLM CPU and swap both below thresholds. Echoes a reason;
# returns 0 idle, 1 busy/unreachable.
host_idle() {
  local name="$1" cpu="$2" swap="$3"
  if [[ -z "${cpu}" || ! "${cpu}" =~ ^[0-9]+$ ]]; then
    echo "${name}: unreachable"; return 1
  fi
  if (( cpu > BUSY_CPU )); then
    echo "${name}: non-GLM cpu ${cpu}% > ${BUSY_CPU}%"; return 1
  fi
  if [[ "${swap}" =~ ^[0-9]+$ ]] && (( swap > SWAP_BUSY_MB )); then
    echo "${name}: memory pressure (swap ${swap}MB > ${SWAP_BUSY_MB}MB)"; return 1
  fi
  echo "${name}: idle (non-GLM cpu ${cpu}%, swap ${swap:-0}MB)"; return 0
}

gather() {
  L_CPU="$(nonglm_cpu_local || true)"
  L_SWAP="$(swap_local || true)"
  if [[ "${REMOTE}" == "true" ]]; then
    read -r R_CPU R_SWAP <<<"$(remote_probe)"
  else
    R_CPU="0"; R_SWAP="0"
  fi
}

# Instantaneous cluster idle. Sets REASON.
instant_idle() {
  local l r
  l="$(host_idle faepmac1 "${L_CPU}" "${L_SWAP}")" || { REASON="$l"; return 1; }
  r="$(host_idle faepmac2 "${R_CPU}" "${R_SWAP}")" || { REASON="$r"; return 1; }
  if slopgate_busy; then REASON="slopgate serving requests"; return 1; fi
  REASON="both hosts idle, slopgate quiet"
  return 0
}

case "${ACTION}" in
  check)
    gather
    now="$(date +%s)"
    if instant_idle; then
      since="$(cat "${SINCE_FILE}" 2>/dev/null || echo "${now}")"
      boot="$(sysctl -n kern.boottime 2>/dev/null | sed -nE 's/^[{ ]*sec = ([0-9]+).*/\1/p')"
      if [[ ! "${since}" =~ ^[0-9]+$ ]] || (( since > now )) \
         || { [[ -n "${boot}" ]] && (( since < boot )); }; then
        since="${now}"
      fi
      echo "${since}" >"${SINCE_FILE}"
      held=$(( now - since ))
      if (( held >= IDLE_SECONDS )); then
        echo "idle: ${REASON}, held ${held}s" >&2
        exit 0
      fi
      echo "settling: ${REASON}, ${held}s/${IDLE_SECONDS}s" >&2
      exit 1
    fi
    rm -f "${SINCE_FILE}"
    echo "busy: ${REASON}" >&2
    exit 1
    ;;
  status)
    gather
    echo "faepmac1: nonglm_cpu=${L_CPU:-?}% swap=${L_SWAP:-?}MB"
    echo "faepmac2: nonglm_cpu=${R_CPU:-?}% swap=${R_SWAP:-?}MB"
    if slopgate_busy; then echo "slopgate: serving"; else echo "slopgate: quiet/unreachable"; fi
    echo "threshold: IDLE_SECONDS=${IDLE_SECONDS} BUSY_CPU=${BUSY_CPU}% SWAP_BUSY_MB=${SWAP_BUSY_MB}"
    if instant_idle; then echo "instant: idle (${REASON})"; else echo "instant: busy (${REASON})"; fi
    [[ -f "${SINCE_FILE}" ]] && echo "idle_since: $(cat "${SINCE_FILE}") (held $(( $(date +%s) - $(cat "${SINCE_FILE}") ))s)"
    exit 0
    ;;
  *)
    echo "usage: $0 {check|status}" >&2
    exit 2
    ;;
esac
