#!/usr/bin/env bash
# Launch Mistral Medium 3.5 (bartowski Q4_K_M) on a side port for fortbench
# benchmarking. Bypasses slopgate so it doesn't interfere with the qwen
# routing alias on the leader's balancer.
#
# Defaults (override via env):
#   port    8082            (LLAMACPP_PORT)
#   bind    127.0.0.1       (LLAMACPP_HOST)
#   ctx     131072          (LLAMACPP_CONTEXT, 128K)
#   slots   1               (LLAMACPP_PARALLEL)
#   alias   mistral-medium-3.5  served on /v1/models (LLAMACPP_SERVED_ALIAS)
#   instance mistral        pid/port/log files under .run/llamacpp-mistral.*
#
# Sampler/reasoning come from the mistral-medium-3.5-* case in
# server_start_llamacpp.sh (temp 0.7, no penalties, reasoning_effort=high).
# KV is q8_0/q8_0 with -fa on, full Metal offload (-ngl 99).
#
# The launcher refuses to start if the local qwen llama-server is still on
# the GPU; stop it first:
#   launchctl bootout gui/$UID/com.slopcode.llamacpp
#   launchctl bootout gui/$UID/com.slopcode.slopgate-agent
# (the slopgate balancer keeps running and routes qwen traffic to remote
# follower agents until the local agent is bootstrapped back in)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-mistral-medium-3.5-q4}"
export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-mistral-medium-3.5}"
export LLAMACPP_INSTANCE="${LLAMACPP_INSTANCE:-mistral}"
export LLAMACPP_HOST="${LLAMACPP_HOST:-127.0.0.1}"
export LLAMACPP_PORT="${LLAMACPP_PORT:-8082}"
export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-131072}"
export LLAMACPP_PARALLEL="${LLAMACPP_PARALLEL:-1}"
# Mistral has no MoE expert layers; keep all on GPU.
export LLAMACPP_N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-0}"
# Mistral Medium 3.5 GGUF has no usable mmproj on bartowski yet (50KB stub).
# Skip multimodal explicitly so the launcher doesn't try to load it.
export LLAMACPP_MMPROJ="${LLAMACPP_MMPROJ:-off}"

exec "${SCRIPT_DIR}/server_start_llamacpp.sh" "$@"
