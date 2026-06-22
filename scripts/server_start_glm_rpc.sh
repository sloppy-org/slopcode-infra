#!/usr/bin/env bash
# Serve GLM-5.2 (754B-A40B MoE) split across two M3 Ultra 256 GB Mac Studios
# via llama.cpp RPC. This is the MAIN node (faepmac1): it owns the GGUF on
# /Volumes/AI, runs llama-server, holds half the weights in local Metal memory,
# and streams the other half to the RPC worker over the Thunderbolt-5 bridge.
#
# Worker side (faepmac2): scripts/server_start_rpc_worker.sh.
# Bridge:                 scripts/tb5_bridge_setup.sh (both hosts).
# Wired limit:            scripts/install_mac_wired_limit.sh (both hosts).
# Full procedure + sizing: docs/glm-rpc-thunderbolt.md.
#
# Sizing (UD-Q4_K_S, ~436 GB): an even 0.5,0.5 split lands ~218 GB of weights
# plus its share of one 128K q8_0 KV slot on each node, inside the 248 GiB
# wired limit. Q4_K_M/XL (466/467 GB) overrun that budget; Q4_K_S is the
# largest Q4 that fits.
#
# The GLM-5.2 weights MUST be the only large model resident on this node. The
# co-located Qwen llama-servers (35B :8081, 27B :8082) each hold ~200 GB; leave
# them running and GLM OOMs. This script refuses to start while another
# llama-server is resident unless GLM_RPC_FORCE=true.
#
# Env:
#   GLM_RPC_WORKER   worker RPC endpoint host:port (default 10.78.5.2:50052,
#                    the faepmac2 Thunderbolt-bridge address)
#   GLM_RPC_FORCE    true to start even if another llama-server is resident
#   plus any LLAMACPP_* override honored by server_start_llamacpp.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "GLM-5.2 RPC serving is configured for the Mac Studio pair only"

WORKER="${GLM_RPC_WORKER:-10.78.5.2:50052}"

# Preflight: a resident Qwen/other llama-server would starve GLM of wired memory.
if [[ "${GLM_RPC_FORCE:-false}" != "true" && "${LLAMACPP_DRY_RUN:-false}" != "true" ]]; then
  others="$(pgrep -fl 'llama-server' 2>/dev/null | grep -v 'rpc-server' || true)"
  if [[ -n "${others}" ]]; then
    echo "${others}" >&2
    die "another llama-server is resident; stop it first (it holds wired memory GLM-5.2 needs), or set GLM_RPC_FORCE=true"
  fi
fi

# Reachability check for the worker so we fail fast instead of mid-load.
if [[ "${LLAMACPP_DRY_RUN:-false}" != "true" ]]; then
  worker_host="${WORKER%%:*}"
  worker_port="${WORKER##*:}"
  if ! nc -z -G 3 "${worker_host}" "${worker_port}" 2>/dev/null; then
    die "RPC worker ${WORKER} is not reachable; start scripts/server_start_rpc_worker.sh on faepmac2 and bring up the Thunderbolt bridge (scripts/tb5_bridge_setup.sh)"
  fi
fi

# Resolve and serve GLM-5.2 from the shared /Volumes/AI cache. Export the cache
# root so the model registry (a python subprocess) resolves it there too.
export LLAMACPP_CACHE_ROOT="${LLAMACPP_CACHE_ROOT:-/Volumes/AI/llama.cpp}"
export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-glm-5.2}"
export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-glm}"
export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-131072}"
export LLAMACPP_PARALLEL="${LLAMACPP_PARALLEL:-1}"
export LLAMACPP_CACHE_TYPE_K="${LLAMACPP_CACHE_TYPE_K:-q8_0}"
export LLAMACPP_CACHE_TYPE_V="${LLAMACPP_CACHE_TYPE_V:-q8_0}"
export LLAMACPP_TENSOR_SPLIT="${LLAMACPP_TENSOR_SPLIT:-0.5,0.5}"
export LLAMACPP_RPC="${LLAMACPP_RPC:-${WORKER}}"
export LLAMACPP_HOST="${LLAMACPP_HOST:-127.0.0.1}"
export LLAMACPP_PORT="${LLAMACPP_PORT:-8080}"
# Loading 436 GB into ~248 GiB wired + streaming the worker shard is slow to
# first token; give readiness a generous ceiling.
export LLAMACPP_START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-1800}"

exec "${SCRIPT_DIR}/server_start_llamacpp.sh"
