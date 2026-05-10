#!/usr/bin/env bash
#SBATCH --job-name=convert-deepseek-v4-pro
#SBATCH --partition=compute
#SBATCH --gres=gpu:0
#SBATCH --cpus-per-task=64
#SBATCH --mem=1100G
#SBATCH --time=24:00:00
#SBATCH --output=%x-%j.out
#SBATCH --error=%x-%j.err
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Use the Fringe210 build (built by the Flash smoke job prior to this)
FRINGE_HOME="${HOME}/.local/llama.cpp-deepseek-v4-fringe-cuda-sm120"
FRINGE_SRC="${HOME}/.local/llama.cpp-deepseek-v4-fringe-cuda-sm120-src"

HF_HOME="${HF_HOME:-${HOME}/models/huggingface}"
MODEL_CACHE="${HOME}/models/llama.cpp"
OUT_DIR="${MODEL_CACHE}/local_DeepSeek-V4-Pro-GGUF"
mkdir -p "${OUT_DIR}"

# Python env from an existing fortbench runtime (borrows huggingface-hub)
PYTHON="${HOME}/.local/fortbench-runtime-py311-gemma4-26b/venv/bin/python3"

echo "[$(date)] Downloading DeepSeek-V4-Pro BF16 weights..."
HF_HOME="${HF_HOME}" "${PYTHON}" -m huggingface_hub.commands.huggingface_cli download \
  deepseek-ai/DeepSeek-V4-Pro \
  --local-dir "${HF_HOME}/deepseek-ai_DeepSeek-V4-Pro" \
  --include "*.safetensors" "*.json" "tokenizer*"

# Fringe210 fork source tree should exist from the Flash smoke build.
# If not, clone it (no GPU needed for conversion).
if [[ ! -f "${FRINGE_SRC}/convert_hf_to_gguf.py" ]]; then
  echo "[$(date)] Cloning Fringe210 fork for conversion scripts..."
  git clone --depth 1 https://github.com/Fringe210/llama.cpp-deepseek-v4-flash-cuda.git \
    "${FRINGE_SRC}"
fi

# Convert BF16 -> F16 GGUF
F16_GGUF="${OUT_DIR}/DeepSeek-V4-Pro-F16.gguf"
echo "[$(date)] Converting to F16 GGUF..."
"${PYTHON}" "${FRINGE_SRC}/convert_hf_to_gguf.py" \
  "${HF_HOME}/deepseek-ai_DeepSeek-V4-Pro" \
  --outfile "${F16_GGUF}" \
  --outtype f16

# Quantize F16 -> Q4_K_M
Q4KM_GGUF="${OUT_DIR}/DeepSeek-V4-Pro-Q4_K_M.gguf"
echo "[$(date)] Quantizing to Q4_K_M..."
"${FRINGE_HOME}/llama-quantize" "${F16_GGUF}" "${Q4KM_GGUF}" Q4_K_M

# Remove intermediate F16 to free disk
rm -f "${F16_GGUF}"
echo "[$(date)] Done. Output: ${Q4KM_GGUF}"
ls -lh "${Q4KM_GGUF}"
