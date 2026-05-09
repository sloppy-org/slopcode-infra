#!/usr/bin/env bash
# Run a local llama.cpp model for FortBench inside one Slurm job.
# Network exposure is localhost-only; all services are killed on job exit.
set -euo pipefail

MODEL_KEY="${1:-}"
MODE="${2:-smoke}"
case "${MODEL_KEY}" in
  minimax-m27|step35-flash|deepseek-v4-flash|gemma4-31b|gemma4-26b|qwen35-122b|qwen35-397b|gpt-oss-120b|qwen36-35b|qwen36-27b|qwen35-9b|qwen35-4b|qwen35-2b|kimi-k26|mimo-v25|mimo-v25-pro|glm51|mistral-large-3|qwen3-coder-480b|qwen3-coder-next|qwen3-235b|mistral-small-4|devstral-2-123b|trinity-large-preview|trinity-large-thinking|nemotron-120b-a12b) ;;
  *) echo "usage: $0 {minimax-m27|step35-flash|deepseek-v4-flash|gemma4-31b|gemma4-26b|qwen35-122b|qwen35-397b|gpt-oss-120b|qwen36-35b|qwen36-27b|qwen35-9b|qwen35-4b|qwen35-2b|kimi-k26|mimo-v25|mimo-v25-pro|glm51|mistral-large-3|qwen3-coder-480b|qwen3-coder-next|qwen3-235b|mistral-small-4|devstral-2-123b|trinity-large-preview|trinity-large-thinking|nemotron-120b-a12b} [smoke|full]" >&2; exit 2 ;;
esac
case "${MODE}" in
  smoke|full) ;;
  *) echo "usage: $0 {minimax-m27|step35-flash|deepseek-v4-flash|gemma4-31b|gemma4-26b} [smoke|full]" >&2; exit 2 ;;
esac

INFRA_DIR="${SLOPCODE_INFRA_DIR:-${HOME}/infra/slopcode-infra}"
FORTBENCH_DIR="${FORTBENCH_DIR:-${HOME}/code/fortbench}"
STAMP="$(date +%Y%m%d-%H%M%S)"
JOB_ID="${SLURM_JOB_ID:-manual}"
RUN_ROOT="${FORTBENCH_RUN_ROOT:-${HOME}/fortbench-runs}"

case "${MODEL_KEY}" in
  minimax-m27)
    RUN_SLUG="minimax-m27-udq4-128k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-minimax-m2.7-ud-q4}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-minimax-m2.7}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-minimax-m27}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8091}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-minimax-m27-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4101}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-99}"
    SUITE_BASE="minimax-m2.7"
    ;;
  step35-flash)
    RUN_SLUG="step35-flash-q4ks-128k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-step-3.5-flash-q4ks}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-step-3.5-flash}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-step35-flash}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8092}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-step35-flash-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4102}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-99}"
    SUITE_BASE="step-3.5-flash"
    ;;
  deepseek-v4-flash)
    RUN_SLUG="deepseek-v4-flash-q4kexp-32k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-deepseek-v4-flash-q4kexp}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-deepseek-v4-flash}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-deepseek-v4-flash}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8093}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4103}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-deepseek-v4-stable-cuda-sm120}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-99}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-32768}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-512}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-128}"
    export LLAMACPP_THREADS="${LLAMACPP_THREADS:-48}"
    export LLAMACPP_START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-7200}"
    SUITE_BASE="deepseek-v4-flash"
    ;;
  gemma4-31b)
    RUN_SLUG="gemma4-31b-q4-128k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-gemma-4-31b-it-q4}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-gemma-4-31b-it}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-gemma4-31b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8094}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-gemma4-31b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4104}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    SUITE_BASE="gemma-4-31b-it"
    ;;
  gemma4-26b)
    RUN_SLUG="gemma4-26b-a4b-udq4-128k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-gemma-4-26b-a4b-it-ud-q4}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-gemma-4-26b-a4b-it}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-gemma4-26b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8095}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-gemma4-26b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4105}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    SUITE_BASE="gemma-4-26b-a4b-it"
    ;;
  qwen35-122b)
    # Qwen3.5-122B-A10B UD-Q4_K_XL (~77 GiB) — fits fully on GPU, N_CPU_MOE=0
    RUN_SLUG="qwen35-122b-udq4-128k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3.5-122b-a10b-ud-q4}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen3.5-122b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-qwen35-122b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8096}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-qwen35-122b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4106}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    SUITE_BASE="qwen3.5-122b-a10b-ud-q4"
    ;;
  gpt-oss-120b)
    # OpenAI GPT-OSS-120B Q4_K_M (~63 GiB) — 117B total / 5.1B active MoE, fits fully on GPU
    RUN_SLUG="gpt-oss-120b-q4km-128k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-gpt-oss-120b-q4km}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-gpt-oss-120b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-gpt-oss-120b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8098}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-gpt-oss-120b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4108}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    SUITE_BASE="gpt-oss-120b"
    ;;
  qwen35-397b)
    # Qwen3.5-397B-A17B UD-Q4_K_M (~244 GiB) — exceeds GPU VRAM, MoE experts offloaded to CPU
    RUN_SLUG="qwen35-397b-udq4-128k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3.5-397b-a17b-ud-q4}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen3.5-397b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-qwen35-397b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8097}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-qwen35-397b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4107}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-99}"
    SUITE_BASE="qwen3.5-397b-a17b-ud-q4"
    ;;
  qwen36-35b)
    # Qwen3.6-35B-A3B UD-Q4_K_M (~23 GiB) — MoE, 3B active, fits fully on GPU
    RUN_SLUG="qwen36-35b-udq4-128k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3.6-35b-a3b-q4}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen3.6-35b-a3b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-qwen36-35b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8099}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-qwen36-35b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4109}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    SUITE_BASE="qwen3.6-35b-a3b-q4"
    ;;
  qwen36-27b)
    # Qwen3.6-27B Q4_K_M (~16 GiB) — dense, fits fully on GPU
    RUN_SLUG="qwen36-27b-q4-128k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3.6-27b-q4}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen3.6-27b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-qwen36-27b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8100}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-qwen36-27b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4110}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    SUITE_BASE="qwen3.6-27b-q4"
    ;;
  qwen35-9b)
    # Qwen3.5-9B Q4_K_M (~5.9 GiB) — dense, fits fully on GPU
    RUN_SLUG="qwen35-9b-q4-128k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3.5-9b-q4}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen3.5-9b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-qwen35-9b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8101}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-qwen35-9b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4111}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    SUITE_BASE="qwen3.5-9b-q4"
    ;;
  qwen35-4b)
    # Qwen3.5-4B Q4_K_M (~2.9 GiB) — dense, fits fully on GPU
    RUN_SLUG="qwen35-4b-q4-128k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3.5-4b-q4}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen3.5-4b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-qwen35-4b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8102}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-qwen35-4b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4112}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    SUITE_BASE="qwen3.5-4b-q4"
    ;;
  qwen35-2b)
    # Qwen3.5-2B Q4_K_M (~1.3 GiB) — dense, fits fully on GPU
    RUN_SLUG="qwen35-2b-q4-128k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3.5-2b-q4}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen3.5-2b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-qwen35-2b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8103}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-qwen35-2b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4113}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    SUITE_BASE="qwen3.5-2b-q4"
    ;;
  kimi-k26)
    RUN_SLUG="kimi-k2.6-q4x-32k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-kimi-k2.6}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-kimi-k2.6}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-kimi-k26}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8104}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-kimi-k26-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4114}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-99}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-32768}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-512}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-128}"
    export LLAMACPP_START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-7200}"
    export LLAMACPP_THREADS="${LLAMACPP_THREADS:-48}"
    SUITE_BASE="kimi-k2.6"
    ;;
  mimo-v25)
    RUN_SLUG="mimo-v2.5-q4km-32k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-mimo-v2.5}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-mimo-v2.5}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-mimo-v25}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8105}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-mimo-v25-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4115}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-99}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-32768}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-512}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-128}"
    export LLAMACPP_START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-7200}"
    export LLAMACPP_THREADS="${LLAMACPP_THREADS:-48}"
    SUITE_BASE="mimo-v2.5"
    ;;
  mimo-v25-pro)
    RUN_SLUG="mimo-v2.5-pro-iq3s-16k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-mimo-v2.5-pro}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-mimo-v2.5-pro}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-mimo-v25-pro}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8106}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-mimo-v25-pro-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4116}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-99}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-16384}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-256}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-64}"
    export LLAMACPP_START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-10800}"
    export LLAMACPP_THREADS="${LLAMACPP_THREADS:-48}"
    SUITE_BASE="mimo-v2.5-pro"
    ;;
  glm51)
    RUN_SLUG="glm-5.1-iq3ks-32k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-glm-5.1}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-glm-5.1}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-glm51}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8107}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-glm51-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4117}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-99}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-32768}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-512}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-128}"
    export LLAMACPP_START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-10800}"
    export LLAMACPP_THREADS="${LLAMACPP_THREADS:-48}"
    SUITE_BASE="glm-5.1"
    ;;
  mistral-large-3)
    RUN_SLUG="mistral-large-3-675b-q4km-16k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-mistral-large-3-675b}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-mistral-large-3-675b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-mistral-large-3}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8108}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-mistral-large-3-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4118}"
    export LLAMACPP_NGL="${LLAMACPP_NGL:-18}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-16384}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-256}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-64}"
    export LLAMACPP_START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-10800}"
    export LLAMACPP_THREADS="${LLAMACPP_THREADS:-48}"
    SUITE_BASE="mistral-large-3-675b"
    ;;
  qwen3-coder-480b)
    RUN_SLUG="qwen3-coder-480b-a35b-iq4xs-32k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3-coder-480b-a35b}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen3-coder-480b-a35b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-qwen3-coder-480b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8109}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-qwen3-coder-480b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4119}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-99}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-32768}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-512}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-128}"
    export LLAMACPP_START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-10800}"
    export LLAMACPP_THREADS="${LLAMACPP_THREADS:-48}"
    SUITE_BASE="qwen3-coder-480b-a35b"
    ;;
  qwen3-coder-next)
    RUN_SLUG="qwen3-coder-next-q5km-32k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3-coder-next}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen3-coder-next}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-qwen3-coder-next}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8110}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-qwen3-coder-next-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4120}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-32768}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-1024}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-256}"
    SUITE_BASE="qwen3-coder-next"
    ;;
  qwen3-235b)
    RUN_SLUG="qwen3-235b-a22b-2507-q4km-32k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3-235b-a22b-2507}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen3-235b-a22b-2507}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-qwen3-235b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8111}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-qwen3-235b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4121}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-99}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-32768}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-512}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-128}"
    export LLAMACPP_START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-7200}"
    export LLAMACPP_THREADS="${LLAMACPP_THREADS:-48}"
    SUITE_BASE="qwen3-235b-a22b-2507"
    ;;
  mistral-small-4)
    RUN_SLUG="mistral-small-4-119b-q5km-32k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-mistral-small-4-119b}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-mistral-small-4-119b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-mistral-small-4}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8112}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-mistral-small-4-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4122}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-32768}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-1024}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-256}"
    SUITE_BASE="mistral-small-4-119b"
    ;;
  devstral-2-123b)
    RUN_SLUG="devstral-2-123b-q5km-32k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-devstral-2-123b}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-devstral-2-123b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-devstral-2-123b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8113}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-devstral-2-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4123}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-32768}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-1024}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-256}"
    SUITE_BASE="devstral-2-123b"
    ;;
  trinity-large-preview)
    RUN_SLUG="trinity-large-preview-q4km-32k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-trinity-large-preview}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-trinity-large-preview}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-trinity-large-preview}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8114}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-trinity-preview-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4124}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-99}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-32768}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-512}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-128}"
    export LLAMACPP_START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-7200}"
    export LLAMACPP_THREADS="${LLAMACPP_THREADS:-48}"
    SUITE_BASE="trinity-large-preview"
    ;;
  trinity-large-thinking)
    RUN_SLUG="trinity-large-thinking-q4km-32k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-trinity-large-thinking}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-trinity-large-thinking}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-trinity-large-thinking}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8115}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-trinity-thinking-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4125}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-99}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-32768}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-512}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-128}"
    export LLAMACPP_START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-7200}"
    export LLAMACPP_THREADS="${LLAMACPP_THREADS:-48}"
    SUITE_BASE="trinity-large-thinking"
    ;;
  nemotron-120b-a12b)
    RUN_SLUG="nemotron-120b-a12b-q4km-32k"
    export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-nemotron-120b-a12b}"
    export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-nemotron-120b-a12b}"
    export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-nemotron-120b-a12b}"
    export LLAMACPP_PORT="${LLAMACPP_PORT:-8116}"
    export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-nemotron-120b-cuda-sm120}"
    export FORTBENCH_LITELLM_PROXY_PORT="${FORTBENCH_LITELLM_PROXY_PORT:-4126}"
    export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
    export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-32768}"
    export LLAMACPP_BATCH="${LLAMACPP_BATCH:-1024}"
    export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-256}"
    SUITE_BASE="nemotron-120b-a12b"
    ;;
esac

RUN_DIR="${RUN_DIR:-${RUN_ROOT}/${RUN_SLUG}-${MODE}-${JOB_ID}-${STAMP}}"
mkdir -p "${RUN_DIR}"
exec > >(tee -a "${RUN_DIR}/driver.log") 2>&1

SERVER_PID=""
GPU_MONITOR_PID=""
cleanup() {
  set +e
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
  if [[ -f "${RUN_DIR}/llamacpp-${LLAMACPP_INSTANCE}.pid" ]]; then
    kill "$(cat "${RUN_DIR}/llamacpp-${LLAMACPP_INSTANCE}.pid")" 2>/dev/null || true
  fi
  if [[ -f "${RUN_DIR}/llamacpp.pid" ]]; then
    kill "$(cat "${RUN_DIR}/llamacpp.pid")" 2>/dev/null || true
  fi
  if [[ -n "${GPU_MONITOR_PID}" ]]; then
    kill "${GPU_MONITOR_PID}" 2>/dev/null || true
    wait "${GPU_MONITOR_PID}" 2>/dev/null || true
  fi
  pkill -f "litellm.*--port ${FORTBENCH_LITELLM_PROXY_PORT}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

select_cuda_home() {
  local candidate
  for candidate in "${CUDA_HOME:-}" /usr/local/cuda-13.1 /usr/local/cuda-13 /usr/local/cuda-12.9 /usr/local/cuda-12.8 /usr/local/cuda; do
    if [[ -n "${candidate}" && -x "${candidate}/bin/nvcc" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

CUDA_HOME_SELECTED="$(select_cuda_home)" || { echo "error: no CUDA toolkit with nvcc found in allocation" >&2; exit 1; }
export CUDA_HOME="${CUDA_HOME_SELECTED}"
export CUDACXX="${CUDACXX:-${CUDA_HOME}/bin/nvcc}"
export PATH="${HOME}/.local/bin:${CUDA_HOME}/bin:${PATH}"
export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${LD_LIBRARY_PATH:-}"

export LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp-frontier-cuda-sm120}"
export LD_LIBRARY_PATH="${LLAMACPP_HOME}:${CUDA_HOME}/lib64:${LD_LIBRARY_PATH:-}"
export LLAMACPP_CACHE_ROOT="${LLAMACPP_CACHE_ROOT:-${HOME}/models/llama.cpp}"
export HF_HOME="${HF_HOME:-${HOME}/models/huggingface}"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"
export GGML_CUDA_ENABLE_UNIFIED_MEMORY="${GGML_CUDA_ENABLE_UNIFIED_MEMORY:-1}"
export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-131072}"
export LLAMACPP_PARALLEL="${LLAMACPP_PARALLEL:-1}"
export LLAMACPP_HOST="${LLAMACPP_HOST:-127.0.0.1}"
export LLAMACPP_MMPROJ="${LLAMACPP_MMPROJ:-off}"
export LLAMACPP_CACHE_TYPE_K="${LLAMACPP_CACHE_TYPE_K:-q4_0}"
export LLAMACPP_CACHE_TYPE_V="${LLAMACPP_CACHE_TYPE_V:-q4_0}"
export LLAMACPP_BATCH="${LLAMACPP_BATCH:-2048}"
export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-512}"
export LLAMACPP_START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-5400}"
export LLAMACPP_SMOKE_TEST="${LLAMACPP_SMOKE_TEST:-true}"
export LLAMACPP_BUILD_JOBS="${LLAMACPP_BUILD_JOBS:-${SLURM_CPUS_PER_TASK:-16}}"
export LLAMACPP_BACKEND="${LLAMACPP_BACKEND:-cuda-source}"
export LLAMACPP_REPO="${LLAMACPP_REPO:-https://github.com/ggml-org/llama.cpp.git}"
export LLAMACPP_REF="${LLAMACPP_REF:-master}"
export LLAMACPP_CMAKE_EXTRA="${LLAMACPP_CMAKE_EXTRA:--DCMAKE_CUDA_ARCHITECTURES=120 -DGGML_CUDA_GRAPHS=ON -DLLAMA_CURL=OFF}"

export FORTBENCH_LOCAL_USER="${FORTBENCH_LOCAL_USER:-${USER}}"
export FORTBENCH_LITELLM_REQUEST_TIMEOUT_SECONDS="${FORTBENCH_LITELLM_REQUEST_TIMEOUT_SECONDS:-3600}"
export FORTBENCH_RUNTIME_DIR="${FORTBENCH_RUNTIME_DIR:-${HOME}/.local/fortbench-runtime-py311-${MODEL_KEY}}"
export FORTBENCH_PYTHON="${FORTBENCH_PYTHON:-${FORTBENCH_RUNTIME_DIR}/venv/bin/python3}"
export FORTBENCH_TOOLS_BIN="${FORTBENCH_TOOLS_BIN:-${FORTBENCH_RUNTIME_DIR}/bin}"
export FORTBENCH_LITELLM_PROXY_BIN="${FORTBENCH_LITELLM_PROXY_BIN:-${FORTBENCH_RUNTIME_DIR}/venv/bin/litellm}"
export FORTBENCH_OPENCODE_BIN="${FORTBENCH_OPENCODE_BIN:-${HOME}/.local/node_modules/.bin/opencode}"
export PATH="${FORTBENCH_TOOLS_BIN}:${FORTBENCH_RUNTIME_DIR}/venv/bin:${HOME}/.local/node_modules/.bin:${PATH}"

{
  echo "run_dir=${RUN_DIR}"
  echo "model_key=${MODEL_KEY}"
  echo "mode=${MODE}"
  echo "host=$(hostname)"
  echo "user=${USER}"
  echo "date=$(date -Is)"
  echo "slurm_job_id=${SLURM_JOB_ID:-}"
  echo "slurm_cpus_per_task=${SLURM_CPUS_PER_TASK:-}"
  echo "slurm_mem_per_node=${SLURM_MEM_PER_NODE:-}"
  echo "cuda_home=${CUDA_HOME}"
  uname -a
  df -h "${RUN_ROOT}" "${LLAMACPP_CACHE_ROOT}" "${HF_HOME}" 2>/dev/null || true
  env | sort
} > "${RUN_DIR}/env.txt"
cat "${RUN_DIR}/env.txt"

"${CUDACXX}" --version | tee "${RUN_DIR}/nvcc-version.txt"
nvidia-smi --query-gpu=name,memory.total,driver_version,power.limit --format=csv,noheader,nounits | tee "${RUN_DIR}/gpu-start.txt"
ss -ltnp 2>/dev/null | tee "${RUN_DIR}/listeners-before.txt" || true

python3 -m venv "${FORTBENCH_RUNTIME_DIR}/venv"
if ! command -v curl >/dev/null 2>&1; then
  cat > "${FORTBENCH_RUNTIME_DIR}/venv/bin/curl" <<'PYEOF'
#!/usr/bin/env python3
from __future__ import annotations
import argparse
import sys
import urllib.error
import urllib.request

parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("-f", action="store_true")
parser.add_argument("-s", action="store_true")
parser.add_argument("-S", action="store_true")
parser.add_argument("-L", action="store_true")
parser.add_argument("-I", action="store_true")
parser.add_argument("-H", dest="headers", action="append", default=[])
parser.add_argument("-d", dest="data", default=None)
parser.add_argument("-o", dest="output", default=None)
parser.add_argument("-m", dest="timeout", type=float, default=300.0)
parser.add_argument("url")
args, _ = parser.parse_known_args()
headers = {}
for raw in args.headers:
    if ":" in raw:
        k, v = raw.split(":", 1)
        headers[k.strip()] = v.strip()
data = args.data.encode("utf-8") if args.data is not None else None
method = "HEAD" if args.I else ("POST" if data is not None else "GET")
req = urllib.request.Request(args.url, data=data, headers=headers, method=method)
try:
    with urllib.request.urlopen(req, timeout=args.timeout) as resp:
        body = resp.read()
        if args.I:
            sys.stdout.write(f"HTTP/1.1 {resp.status} {resp.reason}\n")
            for k, v in resp.headers.items():
                sys.stdout.write(f"{k}: {v}\n")
        elif args.output:
            with open(args.output, "wb") as f:
                f.write(body)
        else:
            sys.stdout.buffer.write(body)
except urllib.error.HTTPError as exc:
    if args.S:
        print(f"curl shim: HTTP {exc.code}: {exc.reason}", file=sys.stderr)
    sys.exit(22 if args.f else 0)
except Exception as exc:
    if args.S:
        print(f"curl shim: {exc}", file=sys.stderr)
    sys.exit(7)
PYEOF
  chmod +x "${FORTBENCH_RUNTIME_DIR}/venv/bin/curl"
fi

"${FORTBENCH_PYTHON}" -m pip install -U pip wheel setuptools
"${FORTBENCH_PYTHON}" -m pip install -e "${FORTBENCH_DIR}"
"${FORTBENCH_PYTHON}" -m pip install "huggingface_hub" "hf_transfer" "litellm[proxy]>=1.0"
mkdir -p "${FORTBENCH_TOOLS_BIN}"
if ! command -v fpm >/dev/null 2>&1; then
  tmp_fpm="$(mktemp -d)"
  fpm_url="https://github.com/fortran-lang/fpm/releases/download/v0.12.0/fpm-0.12.0-linux-x86_64-gcc-12"
  python3 - "${fpm_url}" "${tmp_fpm}/fpm" <<'PYEOF'
import sys, urllib.request
urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PYEOF
  install -m 0755 "${tmp_fpm}/fpm" "${FORTBENCH_TOOLS_BIN}/fpm"
  rm -rf "${tmp_fpm}"
fi
{
  echo "tool preflight"
  for c in git python3 cmake make gfortran fpm meson ninja pkg-config; do
    printf '%s: ' "$c"
    command -v "$c" || true
    "$c" --version 2>/dev/null | head -1 || true
  done
} | tee "${RUN_DIR}/tool-preflight.txt"

if [[ ! -x "${FORTBENCH_OPENCODE_BIN}" ]]; then
  npm install --prefix "${HOME}/.local" opencode-ai@1.14.41
fi
"${FORTBENCH_OPENCODE_BIN}" --version | tee "${RUN_DIR}/opencode-version.txt" || true

LLAMACPP_NEEDS_BUILD=false
if [[ ! -x "${LLAMACPP_HOME}/llama-server" ]]; then
  LLAMACPP_NEEDS_BUILD=true
if [[ "${LLAMACPP_NEEDS_BUILD}" == "true" ]]; then
  echo "building CUDA llama.cpp into ${LLAMACPP_HOME}"
  bash "${INFRA_DIR}/scripts/setup_llamacpp.sh" 2>&1 | tee "${RUN_DIR}/llamacpp-build.log"
fi
"${LLAMACPP_HOME}/llama-server" --version | tee "${RUN_DIR}/llama-server-version.txt" || true

mkdir -p "${LLAMACPP_CACHE_ROOT}" "${HF_HOME}"
"${FORTBENCH_PYTHON}" "${INFRA_DIR}/scripts/llamacpp_models.py" prefetch "${LLAMACPP_MODEL_ALIAS}" 2>&1 | tee "${RUN_DIR}/model-prefetch.log"
"${FORTBENCH_PYTHON}" "${INFRA_DIR}/scripts/llamacpp_models.py" inventory 2>&1 | tee "${RUN_DIR}/model-inventory.log"

(
  while true; do
    date -Is
    nvidia-smi --query-gpu=timestamp,name,utilization.gpu,memory.used,memory.total,power.draw --format=csv,noheader,nounits
    sleep 30
  done
) > "${RUN_DIR}/gpu.log" 2>&1 &
GPU_MONITOR_PID=$!

export RUN_DIR
export LOG_DIR="${RUN_DIR}"
bash "${INFRA_DIR}/scripts/server_start_llamacpp.sh" 2>&1 | tee "${RUN_DIR}/server-start.log"
if [[ -f "${RUN_DIR}/llamacpp-${LLAMACPP_INSTANCE}.pid" ]]; then
  SERVER_PID="$(cat "${RUN_DIR}/llamacpp-${LLAMACPP_INSTANCE}.pid")"
elif [[ -f "${RUN_DIR}/llamacpp.pid" ]]; then
  SERVER_PID="$(cat "${RUN_DIR}/llamacpp.pid")"
fi
cp "${RUN_DIR}/llamacpp-${LLAMACPP_INSTANCE}.log" "${RUN_DIR}/llama-server.log" 2>/dev/null || true
ss -ltnp 2>/dev/null | tee "${RUN_DIR}/listeners-after.txt" || true
if ss -ltnp 2>/dev/null | grep -E "0\.0\.0\.0:${LLAMACPP_PORT}|\[::\]:${LLAMACPP_PORT}"; then
  echo "error: llama-server is externally bound" >&2
  exit 1
fi

curl -fsS "http://127.0.0.1:${LLAMACPP_PORT}/v1/models" | tee "${RUN_DIR}/models.json"
curl -fsS "http://127.0.0.1:${LLAMACPP_PORT}/v1/chat/completions" \
  -H "content-type: application/json" \
  -d "{\"model\":\"${LLAMACPP_SERVED_ALIAS}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly OK.\"}],\"max_tokens\":16}" \
  | tee "${RUN_DIR}/curl-smoke.json"

FORTBENCH_OUT="${RUN_DIR}/fortbench"
if [[ "${MODE}" == "smoke" ]]; then
  SUITE="${FORTBENCH_DIR}/suites/${SUITE_BASE}-smoke.yaml"
else
  SUITE="${FORTBENCH_DIR}/suites/${SUITE_BASE}-corpus20.yaml"
fi

"${FORTBENCH_PYTHON}" -m fortbench run-suite "${SUITE}" \
  --output-dir "${FORTBENCH_OUT}" \
  --continue-on-error \
  2>&1 | tee "${RUN_DIR}/fortbench.log"

if [[ -f "${FORTBENCH_OUT}/summary.md" ]]; then
  cp "${FORTBENCH_OUT}/summary.md" "${RUN_DIR}/summary.md"
fi

echo "completed ${MODE} run: ${RUN_DIR}"
