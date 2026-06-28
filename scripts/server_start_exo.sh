#!/usr/bin/env bash
# Launch this host as an exo node. Run it on each Mac; nodes on the same subnet
# auto-discover via mDNS and form one cluster. With no Thunderbolt-5 cable, exo
# uses the Ring (TCP) backend automatically. API and dashboard serve on :52415,
# OpenAI-compatible at /v1/chat/completions. See docs/exo-cluster.md.
#
# Env:
#   EXO_DIR                    exo clone (default ~/exo)
#   EXO_MODELS_READ_ONLY_DIRS  colon-separated dirs of pre-downloaded MLX models
#                              (each node loads its shard from local disk, so a
#                              model must be present on every node)
#   EXO_HOME                   exo data/cache home (default ~/.exo)
#   EXO_EXEC                   true to exec in the foreground (launchd ExecStart)
#   EXO_EXTRA_ARGS             extra args passed to `uv run exo`
#   EXO_DRY_RUN                true to print the command and exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "exo targets Apple silicon Macs"

EXO_DIR="${EXO_DIR:-${HOME}/code/exo}"
[[ "${EXO_DRY_RUN:-false}" == "true" || -d "${EXO_DIR}" ]] \
  || die "exo not found at ${EXO_DIR}; run scripts/setup_exo.sh first"

CMD=(uv run exo)
# shellcheck disable=SC2206
[[ -n "${EXO_EXTRA_ARGS:-}" ]] && CMD+=(${EXO_EXTRA_ARGS})

echo "starting exo node"
echo "- dir:    ${EXO_DIR}"
echo "- api:    http://0.0.0.0:52415 (OpenAI-compatible /v1/chat/completions)"
echo "- net:    mDNS discovery on the local subnet, Ring/TCP backend (no RDMA)"
[[ -n "${EXO_MODELS_READ_ONLY_DIRS:-}" ]] && echo "- models: ${EXO_MODELS_READ_ONLY_DIRS}"

if [[ "${EXO_DRY_RUN:-false}" == "true" ]]; then
  printf '(cd %q && ' "${EXO_DIR}"; printf '%q ' "${CMD[@]}"; echo ')'
  exit 0
fi

cd "${EXO_DIR}"
if [[ "${EXO_EXEC:-false}" == "true" ]]; then
  exec "${CMD[@]}"
fi

LOG_FILE="${LOG_DIR}/exo.log"
PID_FILE="${RUN_DIR}/exo.pid"
("${CMD[@]}" >"${LOG_FILE}" 2>&1) &
EXO_PID=$!
disown "${EXO_PID}" 2>/dev/null || true
echo "${EXO_PID}" > "${PID_FILE}"
echo "- pid:    ${EXO_PID}"
echo "- log:    ${LOG_FILE}"
echo "verify both nodes: curl http://127.0.0.1:52415/state"
