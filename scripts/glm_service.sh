#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

ACTION="${1:-status}"
PEER="${GLM_PEER_HOST:-10.78.5.2}"
API="${EXO_API:-http://127.0.0.1:52415}"
MODEL="${GLM_MODEL_ID:-mlx-community/GLM-5.2-mxfp4}"
LABEL_EXO="${GLM_EXO_LABEL:-com.slopcode.exo}"
LABEL_AUTOLOAD="${GLM_AUTOLOAD_LABEL:-com.slopcode.exo-glm}"
DRY_RUN="${GLM_SERVICE_DRY_RUN:-false}"
REMOTE="${GLM_SERVICE_REMOTE:-true}"

run_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

run_remote() {
  [[ "${REMOTE}" == "true" ]] || return 0
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf 'DRY-RUN: ssh %q' "${PEER}"
    printf ' %q' "$*"
    printf '\n'
    return 0
  fi
  ssh "${PEER}" "$@"
}

launchctl_target() {
  echo "gui/$(id -u)"
}

remote_launchctl_target() {
  run_remote 'printf "gui/%s\n" "$(id -u)"'
}

free_gui_ram_local() {
  local patterns=(
    'Google Chrome'
    'Chrome Helper'
    'Safari'
    'com.apple.Safari'
    'Photos'
    'Weather'
    'VTDecoder'
    'photoanalysisd'
    'mediaanalysisd'
  )
  local pat
  for pat in "${patterns[@]}"; do
    run_cmd pkill -TERM -u "$(id -u)" -f "${pat}" 2>/dev/null || true
  done
}

free_gui_ram_remote() {
  run_remote 'uid=$(id -u); for pat in "Google Chrome" "Chrome Helper" Safari com.apple.Safari Photos Weather VTDecoder photoanalysisd mediaanalysisd; do pkill -TERM -u "$uid" -f "$pat" 2>/dev/null || true; done'
}

launchctl_start_local() {
  local gui
  gui="$(launchctl_target)"
  run_cmd launchctl enable "${gui}/${LABEL_EXO}" 2>/dev/null || true
  run_cmd launchctl bootstrap "${gui}" "${HOME}/Library/LaunchAgents/${LABEL_EXO}.plist" 2>/dev/null || true
  run_cmd launchctl kickstart -k "${gui}/${LABEL_EXO}" 2>/dev/null || true
}

launchctl_start_remote() {
  run_remote "uid=\$(id -u); gui=gui/\$uid; launchctl enable \"\$gui/${LABEL_EXO}\" 2>/dev/null || true; launchctl bootstrap \"\$gui\" \"\$HOME/Library/LaunchAgents/${LABEL_EXO}.plist\" 2>/dev/null || true; launchctl kickstart -k \"\$gui/${LABEL_EXO}\" 2>/dev/null || true"
}

launchctl_stop_local() {
  local gui
  gui="$(launchctl_target)"
  run_cmd launchctl disable "${gui}/${LABEL_AUTOLOAD}" 2>/dev/null || true
  run_cmd launchctl bootout "${gui}/${LABEL_AUTOLOAD}" 2>/dev/null || true
  run_cmd launchctl disable "${gui}/${LABEL_EXO}" 2>/dev/null || true
  run_cmd launchctl bootout "${gui}/${LABEL_EXO}" 2>/dev/null || true
}

launchctl_stop_remote() {
  run_remote "uid=\$(id -u); gui=gui/\$uid; launchctl disable \"\$gui/${LABEL_AUTOLOAD}\" 2>/dev/null || true; launchctl bootout \"\$gui/${LABEL_AUTOLOAD}\" 2>/dev/null || true; launchctl disable \"\$gui/${LABEL_EXO}\" 2>/dev/null || true; launchctl bootout \"\$gui/${LABEL_EXO}\" 2>/dev/null || true"
}

wait_exo_nodes() {
  local deadline state nodes
  deadline=$((SECONDS + ${GLM_EXO_WAIT_SECONDS:-180}))
  while (( SECONDS < deadline )); do
    state="$(curl -s -m6 "${API}/state" 2>/dev/null || true)"
    if [[ -n "${state}" ]]; then
      nodes="$(printf '%s' "${state}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("topology",{}).get("nodes",[])))' 2>/dev/null || echo 0)"
      [[ "${nodes}" -ge 2 ]] && return 0
      echo "glm-service: exo has ${nodes} node(s), waiting"
    else
      echo "glm-service: exo API not ready, waiting"
    fi
    sleep 5
  done
  die "exo did not report two nodes before timeout"
}

place_glm_instance() {
  local state instances preview instance
  state="$(curl -s -m6 "${API}/state")"
  instances="$(printf '%s' "${state}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("instances",{})))')"
  if [[ "${instances}" -gt 0 ]]; then
    echo "glm-service: exo already has ${instances} instance(s)"
    return 0
  fi

  curl -s -m10 -X POST "${API}/models/add" \
    -H 'content-type: application/json' \
    -d "{\"model_id\":\"${MODEL}\"}" >/dev/null

  preview="${RUN_DIR}/glm-preview.json"
  instance="${RUN_DIR}/glm-instance.json"
  curl -s -m30 "${API}/instance/previews?model_id=${MODEL}" > "${preview}"
  python3 - "${preview}" "${instance}" <<'PY'
import json, sys
preview_path, instance_path = sys.argv[1:]
data = json.load(open(preview_path))
previews = data.get("previews", data) if isinstance(data, dict) else data
pick = next((p for p in previews if p.get("instance_meta") == "MlxRing" and not p.get("error")), None)
if pick is None:
    raise SystemExit("no usable MlxRing placement")
json.dump({"instance": pick["instance"]}, open(instance_path, "w"))
print("glm-service: placement selected")
PY
  curl -s -m30 -X POST "${API}/instance" \
    -H 'content-type: application/json' \
    --data-binary @"${instance}" >/dev/null
  curl -s -m310 "${API}/instance/await?model_id=${MODEL}&timeout_seconds=300" >/dev/null || true
}

status_local() {
  echo "local:"
  ps -axo pid,ppid,rss,etime,command \
    | grep -E 'exo --api-port|mlx-community/GLM|multiprocessing.spawn.*python@3.13' \
    | grep -v grep || true
  launchctl list | grep -E "${LABEL_EXO}|${LABEL_AUTOLOAD}" || true
  curl -s -m2 "${API}/state" 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print({"nodes": len(d.get("topology",{}).get("nodes",[])), "instances": list(d.get("instances",{}).keys())})' \
    2>/dev/null || true
}

status_remote() {
  [[ "${REMOTE}" == "true" ]] || return 0
  echo "remote ${PEER}:"
  run_remote "ps -axo pid,ppid,rss,etime,command | grep -E 'exo --api-port|mlx-community/GLM|multiprocessing.spawn.*python@3.13' | grep -v grep || true; launchctl list | grep -E '${LABEL_EXO}|${LABEL_AUTOLOAD}' || true"
}

case "${ACTION}" in
  free-ram)
    free_gui_ram_local
    free_gui_ram_remote
    ;;
  start)
    free_gui_ram_local
    free_gui_ram_remote
    launchctl_start_remote
    launchctl_start_local
    [[ "${DRY_RUN}" == "true" ]] || wait_exo_nodes
    [[ "${DRY_RUN}" == "true" ]] || place_glm_instance
    status_local
    status_remote
    ;;
  stop|tear-down|teardown)
    launchctl_stop_remote
    launchctl_stop_local
    sleep 2
    status_local
    status_remote
    ;;
  status)
    status_local
    status_remote
    ;;
  *)
    echo "usage: $0 {start|stop|status|free-ram}" >&2
    exit 2
    ;;
esac
