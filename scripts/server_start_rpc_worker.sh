#!/usr/bin/env bash
# Run a llama.cpp rpc-server worker. On faepmac2 this exposes the local Metal
# device to the GLM-5.2 main node (faepmac1) over the Thunderbolt-5 bridge; the
# main node streams it a tensor shard and the worker runs those layers locally.
# See scripts/server_start_glm_rpc.sh (main node) and docs/glm-rpc-thunderbolt.md.
#
# The RPC protocol is unauthenticated, so the worker binds the point-to-point
# Thunderbolt-bridge address only, never 0.0.0.0 and never the LAN IP.
#
# Env:
#   RPC_WORKER_BIND   address to bind (default: the bridge0 / Thunderbolt Bridge
#                     IPv4, e.g. 10.78.5.2; run scripts/tb5_bridge_setup.sh first)
#   RPC_WORKER_PORT   port to bind (default 50052)
#   RPC_WORKER_CACHE  true to pass -c (local tensor cache, skips re-transfer on
#                     reconnect; default true)
#   RPC_WORKER_DEVICE expose only these ggml devices (-d), comma-separated. A
#                     bare rpc-server advertises BOTH its Metal and its 0-MiB
#                     BLAS device; the main node then sees two RPC devices and a
#                     two-value --tensor-split mismaps onto the 0-MiB one and
#                     aborts ("Remote RPC server crashed or returned malformed
#                     response"). Pin to the Metal device (e.g. MTL0) so the main
#                     sees exactly one RPC GPU.
#   RPC_WORKER_THREADS  CPU device threads (default: llama.cpp auto)
#   RPC_WORKER_EXEC   true to exec in the foreground (for launchd ExecStart);
#                     skips the pid/log/backgrounding path
#   LLAMACPP_HOME     llama.cpp install dir (default ~/.local/llama.cpp)
#   RPC_WORKER_DRY_RUN true to print the command and exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "this worker launcher targets the Mac Studio pair"

RPC_BIN="${LLAMACPP_HOME}/rpc-server"
[[ -x "${RPC_BIN}" ]] || die "rpc-server not found at ${RPC_BIN}. Build llama.cpp with -DGGML_RPC=ON (scripts/setup_llamacpp.sh on Mac already does)."

# @rpath dylib lookup needs the install dir on the loader path (same reason the
# main launcher sets these; avoid /usr/bin/nohup so SIP doesn't strip them).
export DYLD_LIBRARY_PATH="${LLAMACPP_HOME}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"

BIND="${RPC_WORKER_BIND:-}"
if [[ -z "${BIND}" ]]; then
  BIND="$(ipconfig getifaddr bridge0 2>/dev/null || true)"
  [[ -n "${BIND}" ]] || die "no IPv4 on the Thunderbolt Bridge (bridge0). Connect the Thunderbolt-5 cable and run scripts/tb5_bridge_setup.sh worker"
fi
PORT="${RPC_WORKER_PORT:-50052}"

CMD=("${RPC_BIN}" -H "${BIND}" -p "${PORT}")
if [[ "${RPC_WORKER_CACHE:-true}" == "true" ]]; then
  CMD+=(-c)
fi
if [[ -n "${RPC_WORKER_THREADS:-}" ]]; then
  CMD+=(-t "${RPC_WORKER_THREADS}")
fi
if [[ -n "${RPC_WORKER_DEVICE:-}" ]]; then
  CMD+=(-d "${RPC_WORKER_DEVICE}")
fi

echo "starting llama.cpp rpc-server worker"
echo "- binary: ${RPC_BIN}"
echo "- bind:   ${BIND}:${PORT}"
echo "- cache:  ${RPC_WORKER_CACHE:-true}"

if [[ "${RPC_WORKER_DRY_RUN:-false}" == "true" ]]; then
  printf '%q ' "${CMD[@]}"
  echo
  exit 0
fi

if [[ "${RPC_WORKER_EXEC:-false}" == "true" ]]; then
  exec "${CMD[@]}"
fi

PID_FILE="${RUN_DIR}/rpc-worker.pid"
LOG_FILE="${LOG_DIR}/rpc-worker.log"
("${CMD[@]}" >"${LOG_FILE}" 2>&1) &
WORKER_PID=$!
disown "${WORKER_PID}" 2>/dev/null || true
echo "${WORKER_PID}" > "${PID_FILE}"
echo "- pid:    ${WORKER_PID}"
echo "- log:    ${LOG_FILE}"

# rpc-server has no health endpoint; confirm the port is accepting.
for _ in {1..15}; do
  if nc -z -G 1 "${BIND}" "${PORT}" 2>/dev/null; then
    echo "rpc-server listening on ${BIND}:${PORT}"
    exit 0
  fi
  kill -0 "${WORKER_PID}" 2>/dev/null || { tail -n 20 "${LOG_FILE}" >&2 || true; die "rpc-server exited before binding"; }
  sleep 1
done
die "rpc-server did not begin listening on ${BIND}:${PORT}"
