#!/usr/bin/env bash
# Swap the running llama.cpp server (if any) for the Qwen3-Coder-30B-A3B-Instruct
# FIM profile. This is the "press the button" path when you want llama.vscode
# autocomplete instead of agentic chat — there is no sidecar, only one
# llama-server runs at a time on :8080.
#
# Recipe is the upstream `--fim-qwen-30b-default` preset
# (common/arg.cpp:3973), retargeted at the local UD-Q4_K_XL Unsloth GGUF
# (~17.7 GB, fits the same hardware budget as the chat 35B). Sampler block is
# Qwen3-Coder Best Practices.
#
# Swap back to chat with: scripts/server_stop_llamacpp.sh && scripts/server_start_llamacpp.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Skip the stop step when dry-running so callers can inspect the emitted argv
# without killing the running chat server.
if [[ "${LLAMACPP_DRY_RUN:-false}" != "true" ]]; then
  bash "${SCRIPT_DIR}/server_stop_llamacpp.sh"
fi

export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3-coder-30b-a3b-q4}"
export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen}"
export LLAMACPP_CACHE_REUSE="${LLAMACPP_CACHE_REUSE:-256}"
# Upstream FIM preset uses -b 1024 and -ub 1024.
export LLAMACPP_BATCH="${LLAMACPP_BATCH:-1024}"
export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-1024}"

exec "${SCRIPT_DIR}/server_start_llamacpp.sh"
