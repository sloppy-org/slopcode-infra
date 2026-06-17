#!/usr/bin/env bash
# Start the Qwen3.6 27B dense profile — special mode for slopgate deployments
# on more powerful hardware. The standard local default is 35B-A3B MoE.
#
# MTP is on by default (qwen3.6-27b-mtp-q4). Measured on 2x RTX 5060 Ti 16 GB:
# MTP gives +94% decode (42 vs 22 t/s). The dense model's MTP head achieves
# high draft acceptance, roughly 2x the gain seen on the 35B MoE (+32%).
#
# --tensor-split 0.55,0.45 shifts base model weight pressure off GPU1 so the
# MTP draft context fits without hitting the FA VMM allocation threshold.
# Without it, GPU1 free drops to 1775 MiB (crash); with it, 4349 MiB (stable).
# No throughput cost: pp512/pp4096/decode are within measurement noise.
#
# ubatch 256 is the sweet spot for the dense 27B (pp4096 1486 t/s vs 1380 at
# 1024). Decode is flat regardless of ubatch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3.6-27b-mtp-q4}"
export LLAMACPP_SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen}"
export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-131072}"
export LLAMACPP_PARALLEL="${LLAMACPP_PARALLEL:-1}"
export LLAMACPP_HOST="${LLAMACPP_HOST:-127.0.0.1}"
export LLAMACPP_PORT="${LLAMACPP_PORT:-8080}"
export LLAMACPP_CACHE_TYPE_K="${LLAMACPP_CACHE_TYPE_K:-q8_0}"
export LLAMACPP_CACHE_TYPE_V="${LLAMACPP_CACHE_TYPE_V:-q8_0}"
export LLAMACPP_TENSOR_SPLIT="${LLAMACPP_TENSOR_SPLIT:-0.55,0.45}"
export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-256}"

exec "${SCRIPT_DIR}/server_start_llamacpp.sh"
