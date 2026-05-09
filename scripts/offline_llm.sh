#!/usr/bin/env bash
# On-demand local offline coding model launcher.
#
# Defaults to localhost-only Qwen 35B A3B Q4 at 128K context on :8080.
# The server runs in the background and is stopped explicitly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

MODELS_SCRIPT="${SCRIPT_DIR}/llamacpp_models.py"
ACTION="${1:-start}"
[[ $# -gt 0 ]] && shift

usage() {
  cat <<'EOF'
Usage:
  offline_llm start          Start localhost llama.cpp at 128K.
  offline_llm stop           Stop the on-demand server.
  offline_llm restart        Restart it.
  offline_llm status         Show whether /v1/models is reachable.
  offline_llm logs           Tail the on-demand server log.
  offline_llm opencode ...   Start the server, then exec opencode.
  offline_llm pi ...         Start the server, then exec pi.

Env overrides:
  LLAMACPP_CONTEXT=131072
  LLAMACPP_MODEL_ALIAS=...
  LLAMACPP_HOST=127.0.0.1
  LLAMACPP_PORT=8080
EOF
}

probe_url() {
  local host="${LLAMACPP_HOST:-127.0.0.1}" port="${LLAMACPP_PORT:-8080}"
  printf 'http://%s:%s/v1/models' "${host}" "${port}"
}

server_ready() {
  curl -fsS -m 2 "$(probe_url)" >/dev/null 2>&1
}

choose_model_alias() {
  if [[ -n "${LLAMACPP_MODEL_ALIAS:-}" || -n "${LLAMACPP_MODEL:-}" ]]; then
    return 0
  fi
  local alias
  alias="$(python3 "${MODELS_SCRIPT}" default-alias)"
  if python3 "${MODELS_SCRIPT}" resolve "${alias}" >/dev/null 2>&1; then
    export LLAMACPP_MODEL_ALIAS="${alias}"
    return 0
  fi
  alias="qwen3.6-35b-a3b-bartowski-q4"
  if python3 "${MODELS_SCRIPT}" resolve "${alias}" >/dev/null 2>&1; then
    export LLAMACPP_MODEL_ALIAS="${alias}"
    return 0
  fi
  die "Qwen 35B A3B Q4 is not on disk. Run: python3 ${MODELS_SCRIPT} prefetch"
}

start_server() {
  if server_ready; then
    echo "offline model already reachable at $(probe_url)"
    return 0
  fi
  choose_model_alias
  LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-offline}" \
  LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-131072}" \
  LLAMACPP_PARALLEL="${LLAMACPP_PARALLEL:-1}" \
  LLAMACPP_HOST="${LLAMACPP_HOST:-127.0.0.1}" \
  LLAMACPP_PORT="${LLAMACPP_PORT:-8080}" \
  LLAMACPP_BATCH="${LLAMACPP_BATCH:-2048}" \
  LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-1024}" \
    bash "${SCRIPT_DIR}/server_start_llamacpp.sh"
}

stop_server() {
  LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-offline}" \
  LLAMACPP_PORT="${LLAMACPP_PORT:-8080}" \
    bash "${SCRIPT_DIR}/server_stop_llamacpp.sh"
}

disable_autostart() {
  if [[ "$(detect_platform)" != "mac" ]]; then
    echo "disable-autostart is only needed for macOS launchd here"
    return 0
  fi
  local agents="${HOME}/Library/LaunchAgents"
  local label
  for label in com.slopcode.llamacpp com.slopcode.llamacpp-macbook \
               com.devstral.llamacpp-macbook; do
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    rm -f "${agents}/${label}.plist"
  done
  echo "disabled llama.cpp launchd autostart"
}

case "${ACTION}" in
  start)
    start_server
    ;;
  stop)
    stop_server
    ;;
  restart)
    stop_server
    start_server
    ;;
  status)
    if server_ready; then
      echo "ready: $(probe_url)"
      curl -fsS "$(probe_url)"
      echo
    else
      echo "offline model is stopped"
    fi
    ;;
  logs)
    log="${LOG_DIR}/llamacpp-${LLAMACPP_INSTANCE:-offline}.log"
    [[ -f "${log}" ]] || die "log not found: ${log}"
    tail -n "${LLAMACPP_LOG_LINES:-80}" "${log}"
    ;;
  opencode)
    start_server
    exec opencode "$@"
    ;;
  pi)
    start_server
    exec pi "$@"
    ;;
  disable-autostart)
    disable_autostart
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
