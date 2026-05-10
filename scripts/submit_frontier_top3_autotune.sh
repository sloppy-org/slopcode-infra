#!/usr/bin/env bash
# Reproducible top-3 FortBench process:
# 1) tune smoke settings for GLM-5.1 + Kimi-K2.6 via queued Slurm jobs
# 2) pick best setting by solved count, then average runtime
# 3) launch production full runs for top-3 (incl. Devstral)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/slurm_frontier_fortbench.sh"
RUN_ROOT="${FORTBENCH_RUN_ROOT:-${HOME}/fortbench-runs}"
POLL_SECONDS="${POLL_SECONDS:-60}"
SLOPCODE_INFRA_DIR="${SLOPCODE_INFRA_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
FORTBENCH_DIR="${FORTBENCH_DIR:-${HOME}/code/fortbench}"

mkdir -p "${RUN_ROOT}/slurm"

resources_for() {
  case "$1:$2" in
    devstral-2-123b:smoke) echo "--cpus-per-task=32 --mem=256G --time=06:00:00" ;;
    devstral-2-123b:full)  echo "--cpus-per-task=32 --mem=256G --time=72:00:00" ;;
    glm51:smoke)           echo "--cpus-per-task=64 --mem=900G --time=16:00:00" ;;
    glm51:full)            echo "--cpus-per-task=64 --mem=900G --time=96:00:00" ;;
    kimi-k26:smoke)        echo "--cpus-per-task=64 --mem=900G --time=14:00:00" ;;
    kimi-k26:full)         echo "--cpus-per-task=64 --mem=900G --time=96:00:00" ;;
    *) echo "unknown model/mode: $1 $2" >&2; return 2 ;;
  esac
}

wait_for_terminal_state() {
  local job_id="$1"
  local state=""
  while true; do
    state="$(sacct -n -P -j "${job_id}" --format=State | sed -n '1p' | cut -d'|' -f1 | tr -d '[:space:]' || true)"
    case "${state}" in
      COMPLETED|FAILED|CANCELLED|TIMEOUT|OUT_OF_MEMORY|PREEMPTED|BOOT_FAIL|DEADLINE|NODE_FAIL)
        printf '%s\n' "${state}"
        return 0
        ;;
    esac
    sleep "${POLL_SECONDS}"
  done
}

run_dir_for_job() {
  local model="$1"
  local mode="$2"
  local job_id="$3"
  local out_file="${RUN_ROOT}/slurm/${model}-${mode}-${job_id}.out"
  if [[ ! -f "${out_file}" ]]; then
    return 1
  fi
  grep -E '^run_dir=' "${out_file}" | tail -n 1 | sed 's/^run_dir=//'
}

metrics_for_run_dir() {
  local run_dir="$1"
  local summary="${run_dir}/fortbench/summary.csv"
  if [[ ! -f "${summary}" ]]; then
    printf '0,0,999999\n'
    return 0
  fi
  python3 - "${summary}" <<'PY'
import csv, sys
path = sys.argv[1]
rows = 0
solved = 0
runtime_total = 0.0
with open(path, newline="") as f:
    r = csv.DictReader(f)
    for row in r:
        rows += 1
        if row.get("final_status") == "solved":
            solved += 1
        try:
            runtime_total += float(row.get("runtime_seconds_total", "0") or "0")
        except ValueError:
            pass
avg = (runtime_total / rows) if rows else 999999.0
print(f"{rows},{solved},{avg:.2f}")
PY
}

submit_job() {
  local model="$1"
  local mode="$2"
  local job_name="$3"
  local env_csv="$4"
  local resources
  read -r -a resources <<<"$(resources_for "${model}" "${mode}")"
  sbatch --parsable \
    --job-name="${job_name}" \
    --partition=compute \
    --gres=gpu:1 \
    "${resources[@]}" \
    --output="${RUN_ROOT}/slurm/${model}-${mode}-%j.out" \
    --error="${RUN_ROOT}/slurm/${model}-${mode}-%j.err" \
    --export="ALL,SLOPCODE_INFRA_DIR=${SLOPCODE_INFRA_DIR},FORTBENCH_DIR=${FORTBENCH_DIR},${env_csv}" \
    "${RUNNER}" "${model}" "${mode}"
}

# Top 3 from current shortlist:
# - devstral-2-123b: dense model => keep N_CPU_MOE=0
# - glm51 + kimi-k26: tune n-cpu-moe and batch/ubatch
declare -A TUNE_CANDIDATES
TUNE_CANDIDATES["glm51"]="35:512:128 24:512:128 16:1024:256 8:1024:256"
TUNE_CANDIDATES["kimi-k26"]="35:512:128 24:512:128 16:1024:256 8:1024:256"

declare -A BEST_N_CPU_MOE
declare -A BEST_BATCH
declare -A BEST_UBATCH

for model in glm51 kimi-k26; do
  echo "=== tuning ${model} ==="
  best_solved=-1
  best_avg=999999
  best_n=35
  best_b=512
  best_ub=128
  success_count=0

  for candidate in ${TUNE_CANDIDATES["${model}"]}; do
    IFS=: read -r ncpu batch ubatch <<<"${candidate}"
    tag="n${ncpu}-b${batch}-ub${ubatch}"
    env_csv="LLAMACPP_N_CPU_MOE=${ncpu},LLAMACPP_BATCH=${batch},LLAMACPP_UBATCH=${ubatch},LLAMACPP_CONTEXT=131072"
    tune_job="$(submit_job "${model}" smoke "${model}-tune-${tag}" "${env_csv}")"
    echo "submitted ${model} ${tag}: smoke_job=${tune_job}"

    state="$(wait_for_terminal_state "${tune_job}")"
    run_dir="$(run_dir_for_job "${model}" smoke "${tune_job}" || true)"
    IFS=, read -r rows solved avg_runtime <<<"$(metrics_for_run_dir "${run_dir:-/nonexistent}")"
    echo "result ${model} ${tag}: state=${state} rows=${rows} solved=${solved} avg_sec=${avg_runtime} run_dir=${run_dir:-n/a}"

    if [[ "${state}" == "COMPLETED" ]]; then
      ((success_count += 1))
      if (( solved > best_solved )) || { (( solved == best_solved )) && awk "BEGIN{exit !(${avg_runtime} < ${best_avg})}"; }; then
        best_solved="${solved}"
        best_avg="${avg_runtime}"
        best_n="${ncpu}"
        best_b="${batch}"
        best_ub="${ubatch}"
      fi
    fi
  done

  if (( success_count == 0 )); then
    echo "error: all tuning candidates failed for ${model}; refusing to launch production runs" >&2
    exit 1
  fi

  BEST_N_CPU_MOE["${model}"]="${best_n}"
  BEST_BATCH["${model}"]="${best_b}"
  BEST_UBATCH["${model}"]="${best_ub}"
  echo "selected ${model}: n_cpu_moe=${best_n} batch=${best_b} ubatch=${best_ub}"
done

# Devstral is dense: fixed no-CPU-MoE.
BEST_N_CPU_MOE["devstral-2-123b"]="0"
BEST_BATCH["devstral-2-123b"]="1024"
BEST_UBATCH["devstral-2-123b"]="256"

echo "=== launching production full runs (top 3) ==="
for model in devstral-2-123b glm51 kimi-k26; do
  ncpu="${BEST_N_CPU_MOE["${model}"]}"
  batch="${BEST_BATCH["${model}"]}"
  ubatch="${BEST_UBATCH["${model}"]}"
  env_csv="LLAMACPP_N_CPU_MOE=${ncpu},LLAMACPP_BATCH=${batch},LLAMACPP_UBATCH=${ubatch},LLAMACPP_CONTEXT=131072"
  full_job="$(submit_job "${model}" full "${model}-full-prod" "${env_csv}")"
  echo "production ${model}: full_job=${full_job} n_cpu_moe=${ncpu} batch=${batch} ubatch=${ubatch}"
done

echo "logs=${RUN_ROOT}/slurm"
