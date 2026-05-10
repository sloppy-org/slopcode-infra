#!/usr/bin/env bash
# Reproducible top-3 FortBench process:
# 1) run quick startup/OOM probes for GLM-5.1 + Kimi-K2.6 + Devstral
# 2) pick the first candidate that actually starts successfully
# 3) launch production full runs with the chosen settings
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

# Math / sizing basis for a 96 GB VRAM + ~1 TB RAM box:
# - GLM-5.1 UD-Q3_K_XL is ~316.8 GiB. At ctx=131072 and n_cpu_moe=35 the current
#   log reports ~189.9 GiB CUDA model buffer + ~5.4 GiB KV/compute, so 35 is far
#   too GPU-heavy for physical 96 GB VRAM. Probe higher n_cpu_moe values first.
# - Kimi-K2.6 Q4_X is ~543.6 GiB. The clean historical fit we actually have on
#   this box is the CPU-heavy split (n_cpu_moe=99) at ctx=32768 with only
#   ~11.2 GiB CUDA model buffer + ~3.7 GiB KV/compute. A fresh n_cpu_moe=0 probe
#   tried to allocate ~555 GiB of CUDA model buffer, so start from the known-safe
#   CPU-heavy side instead of assuming aggressive GPU placement will fit.
# - Devstral-2-123b Q5_K_M is ~82.2 GiB dense. At ctx=32768 it uses ~83.2 GiB
#   CUDA model buffer + ~3.2 GiB KV. KV scales linearly with ctx, so 98304 is a
#   safer production target than 131072 on a 96 GB card.
declare -A TUNE_CANDIDATES
# GLM-5.1 now has one real data point on this box: n58 / b512 / ub128 still
# allocates ~98.3 GiB of CUDA model buffer before KV/compute, so probe the
# smallest higher CPU-MoE values first and keep batch sizing conservative.
TUNE_CANDIDATES["glm51"]="60:512:128:131072 62:512:128:131072 64:512:128:131072"
TUNE_CANDIDATES["kimi-k26"]="99:1024:256:98304 99:512:128:98304 99:1024:256:32768"

declare -A BEST_N_CPU_MOE
declare -A BEST_BATCH
declare -A BEST_UBATCH
declare -A BEST_CONTEXT

TOP3_COMMON_ENV="GGML_CUDA_ENABLE_UNIFIED_MEMORY=0,LLAMACPP_CACHE_RAM=0"
TOP3_MOE_ENV="LLAMACPP_NO_MMAP=true,LLAMACPP_FIT=off"

for model in glm51 kimi-k26; do
  echo "=== startup probe ${model} ==="
  selected=false

  for candidate in ${TUNE_CANDIDATES["${model}"]}; do
    IFS=: read -r ncpu batch ubatch context <<<"${candidate}"
    tag="n${ncpu}-b${batch}-ub${ubatch}-c${context}"
    env_csv="LLAMACPP_N_CPU_MOE=${ncpu},LLAMACPP_BATCH=${batch},LLAMACPP_UBATCH=${ubatch},LLAMACPP_CONTEXT=${context},LLAMACPP_START_TIMEOUT=5400,FORTBENCH_SKIP_SUITE=true,${TOP3_COMMON_ENV},${TOP3_MOE_ENV}"
    tune_job="$(submit_job "${model}" smoke "${model}-tune-${tag}" "${env_csv}")"
    echo "submitted ${model} ${tag}: probe_job=${tune_job}"

    state="$(wait_for_terminal_state "${tune_job}")"
    echo "result ${model} ${tag}: state=${state}"

    if [[ "${state}" == "COMPLETED" ]]; then
      BEST_N_CPU_MOE["${model}"]="${ncpu}"
      BEST_BATCH["${model}"]="${batch}"
      BEST_UBATCH["${model}"]="${ubatch}"
      BEST_CONTEXT["${model}"]="${context}"
      selected=true
      echo "selected ${model}: n_cpu_moe=${ncpu} batch=${batch} ubatch=${ubatch} context=${context}"
      break
    fi
  done

  if [[ "${selected}" != "true" ]]; then
    echo "error: all startup probes failed for ${model}; refusing to launch production runs" >&2
    exit 1
  fi
done

# Devstral is dense: do one startup probe with the safer 98304 context.
BEST_N_CPU_MOE["devstral-2-123b"]="0"
BEST_BATCH["devstral-2-123b"]="1024"
BEST_UBATCH["devstral-2-123b"]="256"
BEST_CONTEXT["devstral-2-123b"]="98304"

echo "=== startup probe devstral-2-123b ==="
devstral_probe_env="LLAMACPP_N_CPU_MOE=0,LLAMACPP_BATCH=1024,LLAMACPP_UBATCH=256,LLAMACPP_CONTEXT=98304,LLAMACPP_START_TIMEOUT=3600,FORTBENCH_SKIP_SUITE=true,${TOP3_COMMON_ENV}"
devstral_probe_job="$(submit_job "devstral-2-123b" smoke "devstral-2-123b-probe-c98304" "${devstral_probe_env}")"
echo "submitted devstral-2-123b probe: probe_job=${devstral_probe_job}"
devstral_probe_state="$(wait_for_terminal_state "${devstral_probe_job}")"
echo "result devstral-2-123b probe: state=${devstral_probe_state}"
if [[ "${devstral_probe_state}" != "COMPLETED" ]]; then
  echo "error: devstral-2-123b startup probe failed; refusing to launch production runs" >&2
  exit 1
fi

echo "=== launching production full runs (top 3) ==="
for model in devstral-2-123b glm51 kimi-k26; do
  ncpu="${BEST_N_CPU_MOE["${model}"]}"
  batch="${BEST_BATCH["${model}"]}"
  ubatch="${BEST_UBATCH["${model}"]}"
  context="${BEST_CONTEXT["${model}"]}"
  extra_env="${TOP3_COMMON_ENV}"
  if [[ "${model}" != "devstral-2-123b" ]]; then
    extra_env="${extra_env},${TOP3_MOE_ENV}"
  fi
  env_csv="LLAMACPP_N_CPU_MOE=${ncpu},LLAMACPP_BATCH=${batch},LLAMACPP_UBATCH=${ubatch},LLAMACPP_CONTEXT=${context},${extra_env}"
  full_job="$(submit_job "${model}" full "${model}-full-prod" "${env_csv}")"
  echo "production ${model}: full_job=${full_job} n_cpu_moe=${ncpu} batch=${batch} ubatch=${ubatch} context=${context}"
done

echo "logs=${RUN_ROOT}/slurm"
