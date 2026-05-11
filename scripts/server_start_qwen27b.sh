#!/usr/bin/env bash
# Start the Qwen3.6 27B dense profile — special mode for slopgate deployments
# on more powerful hardware. The standard local default is 35B-A3B MoE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3.6-27b-q4}"
export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen}"
export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-131072}"
export LLAMACPP_PARALLEL="${LLAMACPP_PARALLEL:-1}"
export LLAMACPP_HOST="${LLAMACPP_HOST:-127.0.0.1}"
export LLAMACPP_PORT="${LLAMACPP_PORT:-8080}"
export LLAMACPP_CACHE_TYPE_K="${LLAMACPP_CACHE_TYPE_K:-q8_0}"
export LLAMACPP_CACHE_TYPE_V="${LLAMACPP_CACHE_TYPE_V:-q8_0}"

exec "${SCRIPT_DIR}/server_start_llamacpp.sh"
