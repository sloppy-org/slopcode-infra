#!/usr/bin/env bash
# Start one llama-server instance. Defaults match the blessed Qwen3.6 profile:
#   Q8_0 KV cache, flash attention, 256K per-slot context,
#   partial MoE offload (--n-cpu-moe 35, -ub 1024) tuned for a 16 GB CUDA
#   GPU coexisting with whisper-server (~1 GB) + Qwen3-TTS (~4.4 GB at synth
#   peak) on Linux/Windows; Metal (no MoE split) on Mac; reasoning enabled.
#
# Slot counts per platform:
#   Linux/Windows: -np 1 -c 262144           (1 slot x 256K, 16 GB GPU cap)
#   Mac:           -np 4 -c 1048576          (4 slots x 256K)
#
# Env overrides:
#   LLAMACPP_HOME         install dir (default ~/.local/llama.cpp)
#   LLAMACPP_SERVER_BIN   explicit llama-server binary
#   LLAMACPP_MODEL        explicit GGUF path (else resolved via llamacpp_models.py)
#   LLAMACPP_MMPROJ       explicit multimodal projector path; "off" disables
#   LLAMACPP_MODEL_ALIAS  alias from the model registry (default: blessed)
#   LLAMACPP_INSTANCE     name suffix for pid/port/log files (default: empty -> .run/llamacpp.*)
#   LLAMACPP_SERVED_ALIAS --alias served in /v1/models (default: qwen)
#   LLAMACPP_CONTEXT      total context size across slots (default 262144, full ctx for one slot)
#   LLAMACPP_PORT         listen port (default 8080; 8081 when the local
#                         slopgate-balancer/agent unit is installed so the
#                         proxy can take 8080)
#   LLAMACPP_HOST         bind host (default 0.0.0.0; 127.0.0.1 when the
#                         local slopgate-agent unit is installed)
#   LLAMACPP_BIND_LOOPBACK
#                         true to force --host 127.0.0.1 regardless of
#                         slopgate detection (followers behind a remote
#                         balancer)
#   LLAMACPP_PARALLEL     concurrent slots (default 1; Mac orchestrator passes 2)
#   LLAMACPP_N_CPU_MOE    number of MoE expert layers to keep on CPU
#                         (default 35 on non-Mac -> 5/40 expert layers on GPU;
#                         empty on Mac)
#   LLAMACPP_CPU_MOE      legacy on/off; true forces --n-cpu-moe 99 (all on CPU);
#                         only takes effect when LLAMACPP_N_CPU_MOE is unset.
#   LLAMACPP_UBATCH       physical batch (default 1024 on non-Mac; empty on Mac)
#   LLAMACPP_BATCH        logical batch (default 2048)
#   LLAMACPP_CACHE_TYPE_K KV cache quantization (default q8_0)
#   LLAMACPP_CACHE_TYPE_V KV cache quantization (default q8_0)
#   LLAMACPP_THREADS      compute threads (default: physical_cores - 2, min 2; Mac: unset)
#   LLAMACPP_THREADS_HTTP HTTP listener threads (default: 4 on CPU-MoE hosts; Mac: unset)
#   LLAMACPP_REASONING_BUDGET
#                         hidden-reasoning token cap (default: 4096;
#                         -1 restores unrestricted, 0 disables thinking)
#   LLAMACPP_DRY_RUN      true to print the command and exit
#   LLAMACPP_EXEC         true to exec llama-server in the foreground (for
#                         systemd/launchd ExecStart); skips nohup, pid files,
#                         ready polling, and the smoke test — the supervisor
#                         owns the PID and restart policy.
#   LLAMACPP_SMOKE_TEST   false to skip the post-start /v1/chat/completions probe
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
MODELS_SCRIPT="${SCRIPT_DIR}/llamacpp_models.py"

# --- Binary resolution ---
if ! LLAMA_SERVER="$(resolve_llamacpp_server_bin)"; then
  die "llama-server not installed. Run: scripts/setup_llamacpp.sh"
fi
[[ -x "${LLAMA_SERVER}" ]] || die "not executable: ${LLAMA_SERVER}"

LLAMA_SERVER_DIR="$(cd "$(dirname "${LLAMA_SERVER}")" && pwd)"
export LD_LIBRARY_PATH="${LLAMA_SERVER_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export DYLD_LIBRARY_PATH="${LLAMA_SERVER_DIR}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"

# --- Model resolution ---
DEFAULT_ALIAS="$(python3 "${MODELS_SCRIPT}" default-alias)"
MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-${DEFAULT_ALIAS}}"
MODEL_PATH="${LLAMACPP_MODEL:-}"
if [[ -z "${MODEL_PATH}" ]]; then
  if resolved="$(python3 "${MODELS_SCRIPT}" resolve "${MODEL_ALIAS}" 2>/dev/null)" && [[ -n "${resolved}" && -f "${resolved}" ]]; then
    MODEL_PATH="${resolved}"
  fi
fi
[[ -n "${MODEL_PATH}" ]] || die "model not found. Run: scripts/llamacpp_models.py prefetch"
[[ -f "${MODEL_PATH}" || "${LLAMACPP_DRY_RUN:-false}" == "true" ]] || die "model file missing: ${MODEL_PATH}"

MMPROJ_PATH="${LLAMACPP_MMPROJ:-}"
if [[ -z "${MMPROJ_PATH}" ]]; then
  if resolved_mmproj="$(python3 "${MODELS_SCRIPT}" resolve-mmproj "${MODEL_ALIAS}" 2>/dev/null)" \
      && [[ -n "${resolved_mmproj}" && -f "${resolved_mmproj}" ]]; then
    MMPROJ_PATH="${resolved_mmproj}"
  fi
fi
if [[ "${MMPROJ_PATH}" == "off" || "${MMPROJ_PATH}" == "none" ]]; then
  MMPROJ_PATH=""
elif [[ -z "${MMPROJ_PATH}" && "${MODEL_ALIAS}" == "${DEFAULT_ALIAS}" ]]; then
  die "mmproj not found for ${MODEL_ALIAS}. Run: scripts/llamacpp_models.py prefetch"
fi
[[ -z "${MMPROJ_PATH}" || -f "${MMPROJ_PATH}" || "${LLAMACPP_DRY_RUN:-false}" == "true" ]] \
  || die "mmproj file missing: ${MMPROJ_PATH}"

# --- Runtime parameters ---
slopgate_present() {
  case "${PLATFORM}" in
    mac)
      [[ -f "${HOME}/Library/LaunchAgents/com.slopcode.slopgate-balancer.plist" \
        || -f "${HOME}/Library/LaunchAgents/com.slopcode.slopgate-agent.plist" ]]
      ;;
    linux|wsl)
      [[ -f "${HOME}/.config/systemd/user/slopgate-balancer.service" \
        || -f "${HOME}/.config/systemd/user/slopgate-agent.service" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

HOST_DEFAULT=0.0.0.0
PORT_DEFAULT=8080
if [[ "${LLAMACPP_BIND_LOOPBACK:-false}" == "true" ]]; then
  HOST_DEFAULT=127.0.0.1
  PORT_DEFAULT=8080
elif slopgate_present; then
  HOST_DEFAULT=127.0.0.1
  PORT_DEFAULT=8081
fi
HOST="${LLAMACPP_HOST:-${HOST_DEFAULT}}"
PORT="${LLAMACPP_PORT:-${PORT_DEFAULT}}"
if [[ "${PLATFORM}" == "mac" ]]; then
  CONTEXT="${LLAMACPP_CONTEXT:-1048576}"
else
  CONTEXT="${LLAMACPP_CONTEXT:-262144}"
fi
BATCH="${LLAMACPP_BATCH:-2048}"
# -ub sizes the GPU compute buffer. On a 16 GB RTX 5060 Ti with --n-cpu-moe 30
# and c=262144, -ub 1024 lands at ~11.0 GB VRAM (prefill 647 t/s, decode 39.7
# t/s on Qwen3.6-35B-A3B UD-Q4_K_M). Going to -ub 2048 pushes compute buffer up
# ~1.5 GB for +28% prefill with no decode gain — left as an override for
# lightly-loaded hosts.
UBATCH="${LLAMACPP_UBATCH:-1024}"
NGL="${LLAMACPP_NGL:-99}"
CACHE_TYPE_K="${LLAMACPP_CACHE_TYPE_K:-q8_0}"
CACHE_TYPE_V="${LLAMACPP_CACHE_TYPE_V:-q8_0}"

# One slot per instance on Linux/Windows by default — 16 GB GPU is the cap and
# halving the 262144 context across two slots made opencode auto-compaction fire
# at ~79K conversation tokens instead of ~210K. Mac defaults to four slots
# because unified memory has plenty of room (the previously-bundled 27B dense
# companion is gone) and a single user often runs concurrent opencode + student
# traffic through the slopgate proxy.
if [[ "${PLATFORM}" == "mac" ]]; then
  PARALLEL="${LLAMACPP_PARALLEL:-4}"
else
  PARALLEL="${LLAMACPP_PARALLEL:-1}"
fi

# Partial MoE offload: on a 16 GB CUDA GPU coexisting with whisper-server
# (~0.9 GB resident) and Qwen3-TTS (~4.4 GB at synth peak), --n-cpu-moe 35
# puts expert layers 0..34 on CPU and 35..39 on GPU. At c=262144 -ub 1024
# llama holds ~8.7 GB VRAM; with whisper + TTS at synth peak the full stack
# lands at ~14.6 GB / 16 GB, leaving ~1.3 GB headroom. Bench on RTX 5060 Ti
# (Qwen3.6-35B-A3B UD-Q4_K_M) measured 1.9x prefill and 1.12x decode vs the old
# all-CPU-moe baseline — slightly slower than the earlier --n-cpu-moe 30
# default but leaves room for TTS to load without OOM. See commit history.
# Mac keeps everything in unified memory; no split. Setting LLAMACPP_CPU_MOE=
# true forces the old all-CPU-moe path (--n-cpu-moe 99) for emergencies.
N_CPU_MOE_DEFAULT=""
[[ "${PLATFORM}" != "mac" ]] && N_CPU_MOE_DEFAULT="35"
N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-${N_CPU_MOE_DEFAULT}}"
if [[ -z "${LLAMACPP_N_CPU_MOE:-}" && "${LLAMACPP_CPU_MOE:-false}" == "true" ]]; then
  N_CPU_MOE="99"
fi

# Thread caps: on Mac Metal manages its own scheduler so no auto-pinning.
# Explicit overrides via LLAMACPP_THREADS / LLAMACPP_THREADS_HTTP are still
# honored so power users can tune. On Linux/Windows the CPU-resident expert
# layers peg every core for memory-bandwidth-bound decode, which starves
# unrelated userspace (Claude Code, opencode, DE) long enough for remote
# idle timeouts to send RSTs. Reserving 2 physical cores eliminates the
# host-side stall.
THREADS=""
THREADS_HTTP=""
if [[ "${PLATFORM}" != "mac" ]]; then
  THREADS="${LLAMACPP_THREADS:-$(default_compute_threads)}"
  THREADS_HTTP="${LLAMACPP_THREADS_HTTP:-4}"
elif [[ -n "${LLAMACPP_THREADS:-}" ]]; then
  THREADS="${LLAMACPP_THREADS}"
  THREADS_HTTP="${LLAMACPP_THREADS_HTTP:-}"
fi
REASONING_BUDGET="${LLAMACPP_REASONING_BUDGET:-$(default_reasoning_budget)}"

SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen}"
INSTANCE="${LLAMACPP_INSTANCE:-}"
if [[ -n "${INSTANCE}" ]]; then
  PID_FILE="${RUN_DIR}/llamacpp-${INSTANCE}.pid"
  PORT_FILE="${RUN_DIR}/llamacpp-${INSTANCE}.port"
  LOG_FILE="${LOG_DIR}/llamacpp-${INSTANCE}.log"
else
  PID_FILE="${RUN_DIR}/llamacpp.pid"
  PORT_FILE="${RUN_DIR}/llamacpp.port"
  LOG_FILE="${LOG_DIR}/llamacpp.log"
fi

DRY_RUN="${LLAMACPP_DRY_RUN:-false}"
SMOKE_TEST="${LLAMACPP_SMOKE_TEST:-true}"
START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-900}"

# Skip the live-port check on dry runs — the test harness only inspects the
# emitted argv and shouldn't be confused by whatever is actually listening on
# the host (e.g., a real slopgate balancer on the leader).
if [[ "${DRY_RUN}" != "true" ]]; then
  stop_llamacpp_port_occupants "${PORT}" "llama.cpp server"
fi

SAMPLER_ARGS=()
case "${MODEL_ALIAS}" in
  minimax-*)
    SAMPLER_ARGS+=(
      --temp 1.0
      --top-p 0.95
      --top-k 40
      --no-context-shift
    )
    ;;
  step-3.5-flash-*)
    SAMPLER_ARGS+=(
      --temp 1.0
      --top-p 0.95
      --top-k 20
      --min-p 0
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --no-context-shift
    )
    ;;
  deepseek-v4-flash-*)
    SAMPLER_ARGS+=(
      --temp 0.6
      --top-p 0.95
      --top-k 20
      --min-p 0
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --no-context-shift
    )
    ;;
  gemma-4-*)
    SAMPLER_ARGS+=(
      --temp 1.0
      --top-p 0.95
      --top-k 40
      --min-p 0
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --no-context-shift
    )
    ;;
  mistral-medium-3.5-*)
    # Mistral Medium 3.5: reasoning is gated by --chat-template-kwargs
    # ('{"reasoning_effort":"high"}' for agentic coding) instead of the
    # deepseek tag-extraction path. Mistral guidance keeps presence and
    # repeat penalties at 0.0 / 1.0.
    SAMPLER_ARGS+=(
      --temp 0.7
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --chat-template-kwargs '{"reasoning_effort":"high"}'
      --no-context-shift
    )
    ;;
  mistral-small-4-*|mistral-large-3-*|devstral-2-*)
    SAMPLER_ARGS+=(
      --temp 0.15
      --top-p 0.95
      --min-p 0
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --no-context-shift
    )
    ;;
  nemotron-*)
    SAMPLER_ARGS+=(
      --temp 1.0
      --top-p 0.95
      --top-k 40
      --min-p 0
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --no-context-shift
    )
    ;;
  kimi-*|mimo-*|glm-*|trinity-*)
    SAMPLER_ARGS+=(
      --temp 0.6
      --top-p 0.95
      --top-k 40
      --min-p 0
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --no-context-shift
    )
    ;;
  qwen3-coder-*|qwen3-235b-*)
    SAMPLER_ARGS+=(
      --temp 0.7
      --top-p 0.8
      --top-k 20
      --min-p 0
      --presence-penalty 0.0
      --repeat-penalty 1.05
      --no-context-shift
    )
    ;;
  qwen*)
    SAMPLER_ARGS+=(
      --temp 0.6
      --top-p 0.95
      --top-k 20
      --min-p 0
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --reasoning-format deepseek
      --reasoning-budget "${REASONING_BUDGET}"
      --no-context-shift
    )
    ;;
  *)
    SAMPLER_ARGS+=(
      --temp 0.6
      --top-p 0.95
      --top-k 20
      --min-p 0
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --no-context-shift
    )
    ;;
esac

CMD=(
  "${LLAMA_SERVER}"
  -m "${MODEL_PATH}"
  -c "${CONTEXT}"
  -b "${BATCH}"
  -ub "${UBATCH}"
  -ngl "${NGL}"
  -fa on
  --cache-type-k "${CACHE_TYPE_K}"
  --cache-type-v "${CACHE_TYPE_V}"
  --host "${HOST}"
  --port "${PORT}"
  --alias "${SERVED_ALIAS}"
  --jinja
  -np "${PARALLEL}"
  --no-webui
)
if [[ -n "${MMPROJ_PATH}" ]]; then
  CMD+=(--mmproj "${MMPROJ_PATH}")
fi
CMD+=("${SAMPLER_ARGS[@]}")
if [[ -n "${N_CPU_MOE}" && "${N_CPU_MOE}" != "0" ]]; then
  CMD+=(--n-cpu-moe "${N_CPU_MOE}")
fi
if [[ -n "${THREADS}" ]]; then
  CMD+=(--threads "${THREADS}" --threads-http "${THREADS_HTTP}")
fi

echo "starting llama.cpp server"
echo "- binary:  ${LLAMA_SERVER}"
"${LLAMA_SERVER}" --version 2>&1 | awk '/^version: / || /^built with /{print "- " $0}' || true
echo "- model:   ${MODEL_PATH}"
[[ -n "${MMPROJ_PATH}" ]] && echo "- mmproj:  ${MMPROJ_PATH}"
echo "- alias:   ${MODEL_ALIAS} (served as ${SERVED_ALIAS})"
echo "- bind:    ${HOST}:${PORT}"
echo "- context: ${CONTEXT}"
echo "- slots:   ${PARALLEL}"
echo "- batch:   b=${BATCH} ub=${UBATCH}"
echo "- KV:      ${CACHE_TYPE_K} / ${CACHE_TYPE_V}"
if [[ -n "${N_CPU_MOE}" && "${N_CPU_MOE}" != "0" ]]; then
  echo "- n-cpu-moe: ${N_CPU_MOE} (first N expert layers on CPU; rest on GPU)"
else
  echo "- n-cpu-moe: off (all experts on GPU / unified memory)"
fi
if [[ -n "${THREADS}" ]]; then
  echo "- threads: ${THREADS} compute / ${THREADS_HTTP} http"
fi
echo "- reasoning budget: ${REASONING_BUDGET}"
[[ -n "${INSTANCE}" ]] && echo "- instance: ${INSTANCE}"

if [[ "${DRY_RUN}" == "true" ]]; then
  printf '%q ' "${CMD[@]}"
  echo
  exit 0
fi

# Foreground mode for systemd/launchd ExecStart: replace the shell with
# llama-server so the supervisor tracks the real process, captures stdout/
# stderr through its own logging, and applies Restart=on-failure directly.
if [[ "${LLAMACPP_EXEC:-false}" == "true" ]]; then
  exec "${CMD[@]}"
fi

# Avoid /usr/bin/nohup on macOS: SIP strips DYLD_LIBRARY_PATH when execing
# binaries from system-protected paths, which breaks llama-server's @rpath
# dylib lookup. Plain `& disown` keeps DYLD_LIBRARY_PATH intact and is
# equivalent for nohup's HUP-immunity purposes (the parent shell exits before
# the child can be HUPed by terminal close anyway).
("${CMD[@]}" >"${LOG_FILE}" 2>&1) &
SERVER_PID=$!
disown "${SERVER_PID}" 2>/dev/null || true
echo "${SERVER_PID}" > "${PID_FILE}"
echo "${PORT}" > "${PORT_FILE}"
echo "- pid:     ${SERVER_PID}"
echo "- log:     ${LOG_FILE}"

probe_host="${HOST}"
[[ "${probe_host}" == "0.0.0.0" ]] && probe_host="127.0.0.1"

echo "waiting for /v1/models (timeout ${START_TIMEOUT}s)..."
deadline=$(( $(date +%s) + START_TIMEOUT ))
while : ; do
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    tail -n 40 "${LOG_FILE}" >&2 || true
    die "llama-server exited before becoming ready"
  fi
  if curl -fsS "http://${probe_host}:${PORT}/v1/models" >/dev/null 2>&1; then
    break
  fi
  [[ $(date +%s) -ge ${deadline} ]] && die "timed out waiting for llama-server"
  sleep 2
done
echo "server is ready on http://${probe_host}:${PORT}/v1"

if [[ "${SMOKE_TEST}" == "true" ]]; then
  echo "running chat smoke test..."
  resp="$(curl -fsS "http://${probe_host}:${PORT}/v1/chat/completions" \
    -H "content-type: application/json" \
    -d "{\"model\":\"${SERVED_ALIAS}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly READY.\"}],\"max_tokens\":16}")"
  if [[ "${resp}" == *'"content"'* ]]; then
    echo "smoke test OK"
  else
    echo "${resp}" >&2
    die "smoke test did not return a chat completion"
  fi
fi
