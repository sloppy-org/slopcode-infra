#!/usr/bin/env bash
# Start llama-server, then run the passive OpenCode prewarm after it is ready.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

bash "${SCRIPT_DIR}/server_start_llamacpp.sh"

if [[ "${SLOPCODE_START_PREWARM:-true}" != "true" ]]; then
  exit 0
fi
if ! have opencode; then
  warn "opencode not found; skipping prewarm"
  exit 0
fi

probe_host="${LLAMACPP_HOST:-127.0.0.1}"
[[ "${probe_host}" == "0.0.0.0" ]] && probe_host="127.0.0.1"
LLAMACPP_HOST="${probe_host}" "${SCRIPT_DIR}/llamacpp_prewarm_opencode.sh" \
  >/tmp/slopcode-opencode-prewarm.log 2>&1 &
