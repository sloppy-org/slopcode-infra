#!/usr/bin/env bash
# Start the local SearXNG server behind Granian on a localhost-only endpoint.
#
# Env overrides:
#   SEARXNG_HOME          runtime home (default ~/.local/searxng)
#   SEARXNG_SRC           source checkout path
#   SEARXNG_VENV          virtualenv path
#   SEARXNG_SETTINGS_PATH config file path
#   SEARXNG_BIND_ADDRESS  listen host (default 127.0.0.1)
#   SEARXNG_PORT          listen port (default 8888)
#   SEARXNG_BASE_URL      base URL (default http://127.0.0.1:${SEARXNG_PORT})
#   SEARXNG_WORKERS       Granian worker count (default 1)
#   SEARXNG_THREADS       Granian blocking thread count (default 4)
#   SEARXNG_DRY_RUN       true to print the command and exit
#   SEARXNG_EXEC          true to exec granian in the foreground
#   SEARXNG_SMOKE_TEST    false to skip the JSON search probe
#   SEARXNG_START_TIMEOUT startup timeout in seconds (default 120)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

default_searxng_src() {
  if [[ -d "${HOME}/code/searxng/.git" ]]; then
    echo "${HOME}/code/searxng"
  else
    echo "${HOME}/.local/searxng/src"
  fi
}

SEARXNG_HOME="${SEARXNG_HOME:-${HOME}/.local/searxng}"
SEARXNG_SRC="${SEARXNG_SRC:-$(default_searxng_src)}"
SEARXNG_VENV="${SEARXNG_VENV:-${SEARXNG_HOME}/.venv}"
SEARXNG_SETTINGS_PATH="${SEARXNG_SETTINGS_PATH:-${HOME}/.config/searxng/settings.yml}"
SEARXNG_BIND_ADDRESS="${SEARXNG_BIND_ADDRESS:-127.0.0.1}"
SEARXNG_PORT="${SEARXNG_PORT:-8888}"
SEARXNG_BASE_URL="${SEARXNG_BASE_URL:-http://${SEARXNG_BIND_ADDRESS}:${SEARXNG_PORT}}"
SEARXNG_WORKERS="${SEARXNG_WORKERS:-1}"
SEARXNG_THREADS="${SEARXNG_THREADS:-4}"
SEARXNG_DRY_RUN="${SEARXNG_DRY_RUN:-false}"
SEARXNG_SMOKE_TEST="${SEARXNG_SMOKE_TEST:-true}"
SEARXNG_START_TIMEOUT="${SEARXNG_START_TIMEOUT:-120}"

GRANIAN_BIN="${SEARXNG_VENV}/bin/granian"
[[ -x "${GRANIAN_BIN}" ]] || die "granian not installed. Run: scripts/setup_searxng.sh"
[[ -f "${SEARXNG_SETTINGS_PATH}" ]] || die "settings not found: ${SEARXNG_SETTINGS_PATH} (run: scripts/setup_searxng.sh)"
[[ -d "${SEARXNG_SRC}" ]] || die "source checkout not found: ${SEARXNG_SRC} (run: scripts/setup_searxng.sh)"

PID_FILE="${RUN_DIR}/searxng.pid"
PORT_FILE="${RUN_DIR}/searxng.port"
LOG_FILE="${LOG_DIR}/searxng.log"

existing_pids="$(port_listener_pids "${SEARXNG_PORT}")"
if [[ -n "${existing_pids}" ]]; then
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    kill -0 "${pid}" 2>/dev/null || continue
    cmd="$(pid_command "${pid}")"
    if [[ -z "${cmd}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
      continue
    fi
    if [[ "${cmd}" == *"granian"* || ( "${cmd}" == *"python"* && "${cmd}" == *"searx"* ) ]]; then
      echo "stopping existing searxng listener on port ${SEARXNG_PORT} (pid ${pid})..."
      stop_pid "${pid}" "searxng"
    else
      die "port ${SEARXNG_PORT} is occupied by a non-searxng process (pid ${pid}: ${cmd})"
    fi
  done <<< "${existing_pids}"
fi

export SEARXNG_SETTINGS_PATH
export SEARXNG_BIND_ADDRESS
export SEARXNG_PORT
export SEARXNG_BASE_URL
export GRANIAN_INTERFACE="wsgi"
export GRANIAN_HOST="${SEARXNG_BIND_ADDRESS}"
export GRANIAN_PORT="${SEARXNG_PORT}"
export GRANIAN_WEBSOCKETS="false"
export GRANIAN_WORKERS="${SEARXNG_WORKERS}"
export GRANIAN_BLOCKING_THREADS="${SEARXNG_THREADS}"

CMD=("${GRANIAN_BIN}" "searx.webapp:app")

echo "starting searxng"
echo "- source:   ${SEARXNG_SRC}"
echo "- config:   ${SEARXNG_SETTINGS_PATH}"
echo "- bind:     ${SEARXNG_BIND_ADDRESS}:${SEARXNG_PORT}"
echo "- workers:  ${SEARXNG_WORKERS}"
echo "- threads:  ${SEARXNG_THREADS}"

if [[ "${SEARXNG_DRY_RUN}" == "true" ]]; then
  printf 'cd %q && ' "${SEARXNG_SRC}"
  printf '%q ' "${CMD[@]}"
  echo
  exit 0
fi

cd "${SEARXNG_SRC}"

if [[ "${SEARXNG_EXEC:-false}" == "true" ]]; then
  exec "${CMD[@]}"
fi

("${CMD[@]}" >"${LOG_FILE}" 2>&1) &
SERVER_PID=$!
disown "${SERVER_PID}" 2>/dev/null || true
echo "${SERVER_PID}" > "${PID_FILE}"
echo "${SEARXNG_PORT}" > "${PORT_FILE}"
echo "- pid:      ${SERVER_PID}"
echo "- log:      ${LOG_FILE}"

probe_host="${SEARXNG_BIND_ADDRESS}"
[[ "${probe_host}" == "0.0.0.0" ]] && probe_host="127.0.0.1"

echo "waiting for /search?q=ready&format=json (timeout ${SEARXNG_START_TIMEOUT}s)..."
deadline=$(( $(date +%s) + SEARXNG_START_TIMEOUT ))
while : ; do
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    tail -n 40 "${LOG_FILE}" >&2 || true
    die "searxng exited before becoming ready"
  fi
  if curl -fsS "http://${probe_host}:${SEARXNG_PORT}/search?q=ready&format=json" >/dev/null 2>&1; then
    break
  fi
  [[ $(date +%s) -ge ${deadline} ]] && die "timed out waiting for searxng"
  sleep 2
done
echo "server is ready on http://${probe_host}:${SEARXNG_PORT}"

if [[ "${SEARXNG_SMOKE_TEST}" == "true" ]]; then
  echo "running search smoke test..."
  resp="$(curl -fsS "http://${probe_host}:${SEARXNG_PORT}/search?q=ready&format=json")"
  if [[ "${resp}" == *'"results"'* ]]; then
    echo "smoke test OK"
  else
    echo "${resp}" >&2
    die "smoke test did not return JSON search results"
  fi
fi
