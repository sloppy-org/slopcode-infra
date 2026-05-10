#!/usr/bin/env bash
# Submit smoke jobs first, then 20-task FortBench jobs after each smoke succeeds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/slurm_frontier_fortbench.sh"
RUN_ROOT="${FORTBENCH_RUN_ROOT:-${HOME}/fortbench-runs}"
SLOPCODE_INFRA_DIR="${SLOPCODE_INFRA_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
FORTBENCH_DIR="${FORTBENCH_DIR:-${HOME}/code/fortbench}"
mkdir -p "${RUN_ROOT}/slurm"

if [[ "$#" -gt 0 ]]; then
  MODELS=("$@")
else
  MODELS=(minimax-m27 step35-flash deepseek-v4-flash gemma4-31b gemma4-26b)
fi

resources_for() {
  case "$1:$2" in
    deepseek-v4-flash:smoke) echo "--cpus-per-task=64 --mem=900G --time=12:00:00" ;;
    deepseek-v4-flash:full)  echo "--cpus-per-task=64 --mem=900G --time=72:00:00" ;;
    minimax-m27:smoke)       echo "--cpus-per-task=64 --mem=900G --time=10:00:00" ;;
    minimax-m27:full)        echo "--cpus-per-task=64 --mem=900G --time=72:00:00" ;;
    step35-flash:smoke)      echo "--cpus-per-task=64 --mem=900G --time=10:00:00" ;;
    step35-flash:full)       echo "--cpus-per-task=64 --mem=900G --time=72:00:00" ;;
    gemma4-31b:smoke)        echo "--cpus-per-task=32 --mem=256G --time=04:00:00" ;;
    gemma4-31b:full)         echo "--cpus-per-task=32 --mem=256G --time=48:00:00" ;;
    gemma4-26b:smoke)        echo "--cpus-per-task=32 --mem=256G --time=04:00:00" ;;
    gemma4-26b:full)         echo "--cpus-per-task=32 --mem=256G --time=48:00:00" ;;
    gpt-oss-120b:smoke)      echo "--cpus-per-task=32 --mem=256G --time=04:00:00" ;;
    gpt-oss-120b:full)       echo "--cpus-per-task=32 --mem=256G --time=48:00:00" ;;
    qwen35-122b:smoke)       echo "--cpus-per-task=32 --mem=256G --time=04:00:00" ;;
    qwen35-122b:full)        echo "--cpus-per-task=32 --mem=256G --time=72:00:00" ;;
    qwen35-397b:smoke)       echo "--cpus-per-task=64 --mem=900G --time=12:00:00" ;;
    qwen35-397b:full)        echo "--cpus-per-task=64 --mem=900G --time=96:00:00" ;;
    qwen36-35b:smoke)        echo "--cpus-per-task=32 --mem=256G --time=04:00:00" ;;
    qwen36-35b:full)         echo "--cpus-per-task=32 --mem=256G --time=48:00:00" ;;
    qwen36-27b:smoke)        echo "--cpus-per-task=32 --mem=256G --time=04:00:00" ;;
    qwen36-27b:full)         echo "--cpus-per-task=32 --mem=256G --time=48:00:00" ;;
    qwen35-9b:smoke)         echo "--cpus-per-task=32 --mem=256G --time=02:00:00" ;;
    qwen35-9b:full)          echo "--cpus-per-task=32 --mem=256G --time=24:00:00" ;;
    qwen35-4b:smoke)         echo "--cpus-per-task=16 --mem=128G --time=01:00:00" ;;
    qwen35-4b:full)          echo "--cpus-per-task=16 --mem=128G --time=16:00:00" ;;
    qwen35-2b:smoke)         echo "--cpus-per-task=16 --mem=128G --time=01:00:00" ;;
    qwen35-2b:full)          echo "--cpus-per-task=16 --mem=128G --time=12:00:00" ;;
    kimi-k26:smoke)          echo "--cpus-per-task=64 --mem=900G --time=14:00:00" ;;
    kimi-k26:full)           echo "--cpus-per-task=64 --mem=900G --time=96:00:00" ;;
    mimo-v25:smoke)          echo "--cpus-per-task=64 --mem=900G --time=12:00:00" ;;
    mimo-v25:full)           echo "--cpus-per-task=64 --mem=900G --time=72:00:00" ;;
    mimo-v25-pro:smoke)      echo "--cpus-per-task=64 --mem=900G --time=16:00:00" ;;
    mimo-v25-pro:full)       echo "--cpus-per-task=64 --mem=900G --time=96:00:00" ;;
    glm51:smoke)             echo "--cpus-per-task=64 --mem=900G --time=16:00:00" ;;
    glm51:full)              echo "--cpus-per-task=64 --mem=900G --time=96:00:00" ;;
    mistral-large-3:smoke)   echo "--cpus-per-task=64 --mem=900G --time=14:00:00" ;;
    mistral-large-3:full)    echo "--cpus-per-task=64 --mem=900G --time=96:00:00" ;;
    qwen3-coder-480b:smoke)  echo "--cpus-per-task=64 --mem=900G --time=14:00:00" ;;
    qwen3-coder-480b:full)   echo "--cpus-per-task=64 --mem=900G --time=96:00:00" ;;
    qwen3-coder-next:smoke)  echo "--cpus-per-task=32 --mem=256G --time=04:00:00" ;;
    qwen3-coder-next:full)   echo "--cpus-per-task=32 --mem=256G --time=48:00:00" ;;
    qwen3-235b:smoke)        echo "--cpus-per-task=64 --mem=900G --time=12:00:00" ;;
    qwen3-235b:full)         echo "--cpus-per-task=64 --mem=900G --time=96:00:00" ;;
    mistral-small-4:smoke)   echo "--cpus-per-task=32 --mem=256G --time=06:00:00" ;;
    mistral-small-4:full)    echo "--cpus-per-task=32 --mem=256G --time=72:00:00" ;;
    devstral-2-123b:smoke)   echo "--cpus-per-task=32 --mem=256G --time=06:00:00" ;;
    devstral-2-123b:full)    echo "--cpus-per-task=32 --mem=256G --time=72:00:00" ;;
    trinity-large-preview:smoke)  echo "--cpus-per-task=64 --mem=900G --time=12:00:00" ;;
    trinity-large-preview:full)   echo "--cpus-per-task=64 --mem=900G --time=96:00:00" ;;
    trinity-large-thinking:smoke) echo "--cpus-per-task=64 --mem=900G --time=12:00:00" ;;
    trinity-large-thinking:full)  echo "--cpus-per-task=64 --mem=900G --time=96:00:00" ;;
    nemotron-120b-a12b:smoke)     echo "--cpus-per-task=32 --mem=256G --time=06:00:00" ;;
    nemotron-120b-a12b:full)      echo "--cpus-per-task=32 --mem=256G --time=72:00:00" ;;
    *) echo "unknown model/mode: $1 $2" >&2; return 2 ;;
  esac
}

for model in "${MODELS[@]}"; do
  read -r -a smoke_resources <<<"$(resources_for "${model}" smoke)"
  smoke_job="$(sbatch --parsable \
    --job-name="${model}-smoke" \
    --partition=compute \
    --gres=gpu:1 \
    "${smoke_resources[@]}" \
    --output="${RUN_ROOT}/slurm/${model}-smoke-%j.out" \
    --error="${RUN_ROOT}/slurm/${model}-smoke-%j.err" \
    --export="ALL,SLOPCODE_INFRA_DIR=${SLOPCODE_INFRA_DIR},FORTBENCH_DIR=${FORTBENCH_DIR}" \
    "${RUNNER}" "${model}" smoke)"

  read -r -a full_resources <<<"$(resources_for "${model}" full)"
  full_job="$(sbatch --parsable \
    --dependency=afterok:${smoke_job} \
    --job-name="${model}-full" \
    --partition=compute \
    --gres=gpu:1 \
    "${full_resources[@]}" \
    --output="${RUN_ROOT}/slurm/${model}-full-%j.out" \
    --error="${RUN_ROOT}/slurm/${model}-full-%j.err" \
    --export="ALL,SLOPCODE_INFRA_DIR=${SLOPCODE_INFRA_DIR},FORTBENCH_DIR=${FORTBENCH_DIR}" \
    "${RUNNER}" "${model}" full)"

  echo "${model}: smoke_job=${smoke_job} full_job=${full_job}"
done
echo "logs=${RUN_ROOT}/slurm"
