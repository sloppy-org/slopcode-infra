#!/usr/bin/env bash
# Compare prefill and decode tok/s for one model under MLX (mlx_lm.generate) and
# llama.cpp (llama-bench), single node, cold cache. This weighs the MLX vs
# llama.cpp tradeoff on Apple silicon: MLX tends to win decode and large-MoE
# prefill, while llama.cpp is competitive on dense-model prefill and gains from
# MTP speculative decode. See docs/exo-cluster.md for measured numbers.
#
# Env:
#   BENCH_MLX_PY      python that has mlx_lm (default: first venv found with it)
#   BENCH_MLX_MODEL   MLX model directory (mlx-community layout)
#   BENCH_GGUF        llama.cpp GGUF of the same model
#   BENCH_PROMPT_REPS filler-sentence repeats for the MLX prompt
#                     (default 180, ~1800 tokens)
#   BENCH_PP          llama-bench prompt lengths (default 512,2048)
#   BENCH_TG          generated tokens (default 128)
#   LLAMACPP_HOME     llama.cpp install dir (default ~/.local/llama.cpp)
#   BENCH_DRY_RUN     true to print the plan and exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "this benchmark targets Apple silicon"

MLX_PY="${BENCH_MLX_PY:-}"
MLX_MODEL="${BENCH_MLX_MODEL:-}"
GGUF="${BENCH_GGUF:-}"
REPS="${BENCH_PROMPT_REPS:-180}"
PP="${BENCH_PP:-512,2048}"
TG="${BENCH_TG:-128}"

echo "MLX vs llama.cpp benchmark (single node, cold)"
echo "- mlx model: ${MLX_MODEL:-<unset>}"
echo "- gguf:      ${GGUF:-<unset>}"
echo "- pp/tg:     ${PP} / ${TG}"

if [[ "${BENCH_DRY_RUN:-false}" == "true" ]]; then
  echo "(dry-run) mlx:        mlx_lm.generate --model <mlx> --max-tokens ${TG}"
  echo "(dry-run) llama-bench -m <gguf> -ngl 99 -fa 1 -ctk q8_0 -ctv q8_0 -p ${PP} -n ${TG}"
  exit 0
fi

[[ -n "${MLX_MODEL}" && -d "${MLX_MODEL}" ]] || die "set BENCH_MLX_MODEL to an MLX model dir"
[[ -n "${GGUF}" && -f "${GGUF}" ]] || die "set BENCH_GGUF to a llama.cpp GGUF"

if [[ -z "${MLX_PY}" ]]; then
  for p in "${HOME}/exo/.venv/bin/python" /Volumes/AI/*/.venv/bin/python; do
    [[ -x "${p}" ]] && "${p}" -c "import mlx_lm" 2>/dev/null && { MLX_PY="${p}"; break; }
  done
fi
[[ -n "${MLX_PY}" ]] || die "no python with mlx_lm found; set BENCH_MLX_PY"
MLX_BIN="$(dirname "${MLX_PY}")"

echo
echo "=== MLX (${MLX_PY}) ==="
PROMPT="$(python3 -c "print('The quick brown fox jumps over the lazy dog. '*${REPS}, end='')")"
"${MLX_BIN}/mlx_lm.generate" --model "${MLX_MODEL}" --prompt "${PROMPT}" \
  --max-tokens "${TG}" --temp 0.6 2>&1 | grep -iE 'prompt:|generation:|peak'

echo
echo "=== llama.cpp (llama-bench, fa + q8_0 KV) ==="
export DYLD_LIBRARY_PATH="${LLAMACPP_HOME}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
"${LLAMACPP_HOME}/llama-bench" -m "${GGUF}" -ngl 99 -fa 1 \
  -ctk q8_0 -ctv q8_0 -p "${PP}" -n "${TG}" -r 2 2>&1 | grep -E 'pp[0-9]|tg[0-9]|test'
