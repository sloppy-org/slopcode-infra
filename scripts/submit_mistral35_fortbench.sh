#!/usr/bin/env bash
# Submit smoke first, then the full 20-task Mistral Medium 3.5 run after smoke succeeds.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/slurm_mistral35_fortbench.sh"
RUN_ROOT="${FORTBENCH_RUN_ROOT:-${HOME}/fortbench-runs}"
mkdir -p "${RUN_ROOT}/slurm"

smoke_job="$(sbatch --parsable \
  --job-name=mistral35-smoke \
  --partition=compute \
  --gres=gpu:1 \
  --cpus-per-task=16 \
  --mem=256G \
  --time=04:00:00 \
  --output="${RUN_ROOT}/slurm/mistral35-smoke-%j.out" \
  --error="${RUN_ROOT}/slurm/mistral35-smoke-%j.err" \
  "${RUNNER}" smoke)"

full_job="$(sbatch --parsable \
  --dependency=afterok:${smoke_job} \
  --job-name=mistral35-full \
  --partition=compute \
  --gres=gpu:1 \
  --cpus-per-task=32 \
  --mem=512G \
  --time=72:00:00 \
  --output="${RUN_ROOT}/slurm/mistral35-full-%j.out" \
  --error="${RUN_ROOT}/slurm/mistral35-full-%j.err" \
  "${RUNNER}" full)"

echo "smoke_job=${smoke_job}"
echo "full_job=${full_job}"
echo "logs=${RUN_ROOT}/slurm"
