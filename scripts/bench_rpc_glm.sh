#!/usr/bin/env bash
# Measure prefill (PP) and decode (TG) tok/s for a model split across this host
# and an rpc-server worker, using llama.cpp's own llama-bench. This is how we
# replace the GLM-5.2-over-RPC projections with real numbers before committing to
# a quant or interconnect. See docs/glm-rpc-thunderbolt.md.
#
# The worker endpoint is reached however the caller routes it: over the
# Thunderbolt-5 bridge (10.78.5.2:50052), or, before the cable is in, over an SSH
# tunnel to faepmac2 (127.0.0.1:50052 -> faepmac2:50052). RPC is unauthenticated,
# so the ethernet path is the tunnel, never a raw LAN bind.
#
# Env:
#   BENCH_RPC           worker RPC endpoint host:port (default 127.0.0.1:50052)
#   BENCH_TENSOR_SPLIT  device split "local,worker" (default 0.55,0.45 -- give the
#                       main node the larger share; the worker also hosts a tenant)
#   BENCH_MODEL_ALIAS   registry alias to resolve (default glm-5.2)
#   BENCH_MODEL         explicit GGUF path, overrides the alias
#   BENCH_PP            comma prefill lengths to test (default 512,4096)
#   BENCH_TG            comma decode lengths to test (default 128)
#   BENCH_CTK/BENCH_CTV KV cache types (default q8_0)
#   BENCH_REPS          repetitions per test (default 1; the model is huge)
#   LLAMACPP_CACHE_ROOT model cache root (default /Volumes/AI/llama.cpp)
#   LLAMACPP_HOME       llama.cpp install dir (default ~/.local/llama.cpp)
#   BENCH_RPC_DRY_RUN   true to print the llama-bench command and exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

RPC="${BENCH_RPC:-127.0.0.1:50052}"
SPLIT="${BENCH_TENSOR_SPLIT:-0.55,0.45}"
PP="${BENCH_PP:-512,4096}"
TG="${BENCH_TG:-128}"
CTK="${BENCH_CTK:-q8_0}"
CTV="${BENCH_CTV:-q8_0}"
REPS="${BENCH_REPS:-1}"
export LLAMACPP_CACHE_ROOT="${LLAMACPP_CACHE_ROOT:-/Volumes/AI/llama.cpp}"

MODEL="${BENCH_MODEL:-}"
if [[ -z "${MODEL}" ]]; then
  MODEL="$(python3 "${SCRIPT_DIR}/llamacpp_models.py" resolve "${BENCH_MODEL_ALIAS:-glm-5.2}")" \
    || die "could not resolve model; set BENCH_MODEL or prefetch the alias first"
fi

BENCH_BIN="${LLAMACPP_HOME}/llama-bench"
export DYLD_LIBRARY_PATH="${LLAMACPP_HOME}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"

CMD=("${BENCH_BIN}" -m "${MODEL}" --rpc "${RPC}"
  -ngl 99 -fa 1 -ctk "${CTK}" -ctv "${CTV}"
  -ts "${SPLIT}" -p "${PP}" -n "${TG}" -r "${REPS}")

echo "llama-bench RPC sweep"
echo "- model:  ${MODEL}"
echo "- worker: ${RPC}"
echo "- split:  ${SPLIT} (local,worker)"
echo "- pp/tg:  ${PP} / ${TG}  kv=${CTK}/${CTV}  reps=${REPS}"

if [[ "${BENCH_RPC_DRY_RUN:-false}" == "true" ]]; then
  printf '%q ' "${CMD[@]}"
  echo
  exit 0
fi

[[ -x "${BENCH_BIN}" ]] || die "llama-bench not found at ${BENCH_BIN}"
rpc_host="${RPC%%:*}"; rpc_port="${RPC##*:}"
nc -z -G 3 "${rpc_host}" "${rpc_port}" 2>/dev/null \
  || die "RPC worker ${RPC} unreachable; start scripts/server_start_rpc_worker.sh on the worker (and the SSH tunnel, if used)"

exec "${CMD[@]}"
