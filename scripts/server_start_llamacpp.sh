#!/usr/bin/env bash
# Start one llama-server instance. Defaults match the blessed Qwen3.6 profile:
#   Q8_0 KV cache, flash attention, 128K single-slot context,
#   partial MoE offload (--n-cpu-moe 35, -ub 1024) tuned for a 16 GB CUDA
#   GPU coexisting with whisper-server (~1 GB) + Qwen3-TTS (~4.4 GB at synth
#   peak) on Linux/Windows; Metal (no MoE split) on Mac; reasoning enabled.
#
# Slot counts per platform:
#   default: -np 1 -c 131072
#
# Env overrides:
#   LLAMACPP_HOME         install dir (default ~/.local/llama.cpp)
#   LLAMACPP_SERVER_BIN   explicit llama-server binary
#   LLAMACPP_MODEL        explicit GGUF path (else resolved via llamacpp_models.py)
#   LLAMACPP_MMPROJ       explicit multimodal projector path; "off" disables
#   LLAMACPP_MMPROJ_OFFLOAD
#                         true/false to force multimodal projector GPU offload
#                         (default false on Macs with <64 GiB RAM, true elsewhere)
#   LLAMACPP_MODEL_ALIAS  alias from the model registry (default: blessed)
#   LLAMACPP_INSTANCE     name suffix for pid/port/log files (default: empty -> .run/llamacpp.*)
#   LLAMACPP_SERVED_ALIAS --alias served in /v1/models (default: qwen)
#   LLAMACPP_CONTEXT      total context size across slots (default 131072)
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
#   LLAMACPP_SPEC_DRAFT_N_MAX
#                         draft tokens emitted per step under MTP speculative
#                         decoding (default 2; Unsloth recommends testing 1-6
#                         for your hardware). Only used by *-mtp-* aliases.
#   LLAMACPP_NO_MMAP      true to pass --no-mmap (useful when tensor overrides
#                         place part of the model on CPU)
#   LLAMACPP_TENSOR_SPLIT comma-separated GPU weight ratios, e.g. "0.55,0.45"
#                         (passed to --tensor-split; default: unset = even split)
#   LLAMACPP_RPC          comma-separated RPC worker endpoints (host:port) to
#                         offload part of the model to over the network, e.g.
#                         "10.78.5.2:50052" (passed to --rpc; default: unset =
#                         single-host). Used to span a model across two Macs
#                         over a Thunderbolt-5 bridge. With one remote worker the
#                         device order is local-Metal,remote, so a matching
#                         --tensor-split has two entries (e.g. "0.5,0.5").
#                         See docs/glm-rpc-thunderbolt.md.
#   LLAMACPP_FIT          explicit value passed to -fit (default: on; set to
#                         "off" to disable VRAM-fit autosizer)
#   LLAMACPP_CACHE_RAM    explicit value passed to --cache-ram; 0 disables the
#                         prompt cache
#   LLAMACPP_CACHE_REUSE  N tokens for --cache-reuse (default 256). Enables
#                         chunked KV-shifting so a mid-prompt divergence can
#                         reuse the matching suffix instead of cold-prefilling
#                         from the divergence point. 256 is also the
#                         Set 0 to
#                         disable.
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

MMPROJ_OFFLOAD_DEFAULT="true"
if [[ "$(detect_platform)" == "mac" && "$(detect_total_ram_gb)" -lt 64 ]]; then
  MMPROJ_OFFLOAD_DEFAULT="false"
fi
MMPROJ_OFFLOAD="${LLAMACPP_MMPROJ_OFFLOAD:-${MMPROJ_OFFLOAD_DEFAULT}}"
case "${MMPROJ_OFFLOAD}" in
  true|false) ;;
  *) die "LLAMACPP_MMPROJ_OFFLOAD must be true or false" ;;
esac

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
CONTEXT="${LLAMACPP_CONTEXT:-131072}"
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

# The local offline profile is on-demand and single-slot. Use LLAMACPP_PARALLEL
# and LLAMACPP_CONTEXT for multi-slot slopgate or benchmark runs.
PARALLEL="${LLAMACPP_PARALLEL:-1}"

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
if [[ "${PLATFORM}" != "mac" ]]; then
  case "${MODEL_ALIAS}" in
    *a3b*|*a10b*|*a12b*|*a17b*|*a22b*|*a35b*|minimax-*|nemotron-*)
      N_CPU_MOE_DEFAULT="35"
      ;;
  esac
fi
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
# Per-host presence-penalty override. The blessed per-model presets keep
# presence_penalty 0.0 (Qwen "precise coding"). Qwen3.x thinking models loop
# on open-ended prompts at 0.0; the model card recommends 0-2 to suppress
# endless repetition. Set this on a chat/agent host to raise it without
# changing the cluster default. Empty = keep the per-model preset value.
PRESENCE_PENALTY_OVERRIDE="${LLAMACPP_PRESENCE_PENALTY:-}"
NO_MMAP="${LLAMACPP_NO_MMAP:-false}"
FIT="${LLAMACPP_FIT:-on}"

CACHE_RAM="${LLAMACPP_CACHE_RAM:-}"
CACHE_REUSE="${LLAMACPP_CACHE_REUSE:-256}"
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
START_CONNECT_TIMEOUT="${LLAMACPP_START_CONNECT_TIMEOUT:-2}"
START_PROBE_TIMEOUT="${LLAMACPP_START_PROBE_TIMEOUT:-5}"
SMOKE_TEST_TIMEOUT="${LLAMACPP_SMOKE_TEST_TIMEOUT:-30}"

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
  glm-4.7-flash*)
    # Z.ai recommends tool-calling parameters for agentic runs. Unsloth also
    # notes llama.cpp needs min-p 0.01 instead of its higher default here.
    SAMPLER_ARGS+=(
      --temp 0.7
      --top-p 1.0
      --min-p 0.01
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --no-context-shift
    )
    ;;
  glm-4.7*)
    # GLM-4.7's official coding / terminal evaluation parameters use a lower
    # temperature and unconstrained top-p versus our older generic GLM preset.
    SAMPLER_ARGS+=(
      --temp 0.7
      --top-p 1.0
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
  glm-5*)
    # GLM-5.x (Z.ai): official guidance is temp 1.0, top-p 0.95, and to tune
    # only one of the two. Terminal-Bench 2.1 run with Claude Code used temp
    # 1.0 / top-p 0.95; that is the agentic-coding setting we serve. The older
    # generic glm-* preset below uses temp 0.6, which is too cold for GLM-5.x.
    SAMPLER_ARGS+=(
      --temp 1.0
      --top-p 0.95
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
  *-mtp-*|qwen3.6-35b-a3b-mtp*)
    # Qwen3.6 MTP variants ship a multi-token prediction head. llama.cpp
    # >= b9180 (PR #22673, 2026-05-16) drafts tokens via the MTP head and
    # verifies in parallel. Sampler is Qwen's "thinking + precise coding"
    # preset (temp 0.6, presence-penalty 0). MTP draft acceptance is
    # sampler-independent up to the slot KV; Jakob's 2026-05-22 bench on
    # the same MTP GGUF hit 0.88 acceptance at this preset, so the older
    # Unsloth "temp 1.0 pp 1.5" recipe is not MTP-specific — it was the
    # general-thinking preset, wrong default for agent loops.
    SAMPLER_ARGS+=(
      --temp 0.6
      --top-p 0.95
      --top-k 20
      --min-p 0.0
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --reasoning-format deepseek
      --reasoning-budget "${REASONING_BUDGET}"
      --spec-type draft-mtp
      --spec-draft-n-max "${LLAMACPP_SPEC_DRAFT_N_MAX:-2}"
      # Default the MTP draft KV to the same quant as the main KV. llama.cpp's
      # draft context otherwise defaults to f16, which on Qwen3.6-35B-A3B costs
      # ~1.5 GB more than q8_0 for no measurable acceptance gain. Matching the
      # main cache type keeps "q8_0 everywhere" and frees that VRAM (e.g. so a
      # 32 GB dual-GPU host can keep the vision projector on the GPU).
      --cache-type-k-draft "${CACHE_TYPE_K}"
      --cache-type-v-draft "${CACHE_TYPE_V}"
      --no-context-shift
    )
    ;;
  qwen3-235b-*)
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
  gpt-oss-*)
    # OpenAI gpt-oss (harmony response format). Per the llama.cpp gpt-oss
    # guide (discussion #15396): temp 1.0, top-p 1.0, and NO repetition
    # penalties (repeat-penalty 1.0 is neutral). top-k 40 is kept: the guide
    # warns that disabling top-k adds CPU overhead and a small chance of
    # sampling low-probability tokens. Reasoning rides the harmony "analysis"
    # channel, so --reasoning-format none (not deepseek) and no token budget.
    # No MTP head, so no --spec-type. Served GPU-only: the alias does not match
    # the *a3b* CPU-MoE rule above, so no --n-cpu-moe is emitted.
    SAMPLER_ARGS+=(
      --temp 1.0
      --top-p 1.0
      --top-k 40
      --min-p 0
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --reasoning-format none
      --no-context-shift
    )
    ;;
  qwen*)
    # Qwen3.6-35B-A3B "Thinking + precise coding" sampler — Qwen's own
    # recommendation for code-heavy agent loops (model card "precise coding
    # tasks, e.g. WebDev"). Cluster cohort (Jakob's bench 2026-05-22, the
    # windows-arc bundle, Mac launchagents) all converge on these values.
    # The "thinking + general" alternative (temp 1.0, pp 1.5) is for free-
    # form generation and is not what opencode/Aider/Claude-Code-style
    # agent loops want.
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
  --metrics
  --log-timestamps
)
if [[ "${NO_MMAP}" == "true" ]]; then
  CMD+=(--no-mmap)
fi
if [[ -n "${FIT}" ]]; then
  CMD+=(-fit "${FIT}")
fi
if [[ -n "${CACHE_RAM}" ]]; then
  CMD+=(--cache-ram "${CACHE_RAM}")
fi
if [[ -n "${CACHE_REUSE}" && "${CACHE_REUSE}" != "0" ]]; then
  CMD+=(--cache-reuse "${CACHE_REUSE}")
fi
if [[ -n "${MMPROJ_PATH}" ]]; then
  CMD+=(--mmproj "${MMPROJ_PATH}")
  if [[ "${MMPROJ_OFFLOAD}" == "false" ]]; then
    CMD+=(--no-mmproj-offload)
  else
    CMD+=(--mmproj-offload)
  fi
fi
# Apply the presence-penalty override by replacing the preset's pair, so the
# emitted command carries exactly one --presence-penalty.
if [[ -n "${PRESENCE_PENALTY_OVERRIDE}" ]]; then
  filtered=()
  skip_next=0
  for arg in "${SAMPLER_ARGS[@]}"; do
    if [[ "${skip_next}" == "1" ]]; then skip_next=0; continue; fi
    if [[ "${arg}" == "--presence-penalty" ]]; then skip_next=1; continue; fi
    filtered+=("${arg}")
  done
  filtered+=(--presence-penalty "${PRESENCE_PENALTY_OVERRIDE}")
  SAMPLER_ARGS=("${filtered[@]}")
fi
CMD+=("${SAMPLER_ARGS[@]}")
if [[ -n "${N_CPU_MOE}" && "${N_CPU_MOE}" != "0" ]]; then
  CMD+=(--n-cpu-moe "${N_CPU_MOE}")
fi
if [[ -n "${LLAMACPP_TENSOR_SPLIT:-}" ]]; then
  CMD+=(--tensor-split "${LLAMACPP_TENSOR_SPLIT}")
fi
if [[ -n "${LLAMACPP_RPC:-}" ]]; then
  CMD+=(--rpc "${LLAMACPP_RPC}")
fi
if [[ -n "${THREADS}" ]]; then
  CMD+=(--threads "${THREADS}" --threads-http "${THREADS_HTTP}")
fi

echo "starting llama.cpp server"
echo "- binary:  ${LLAMA_SERVER}"
"${LLAMA_SERVER}" --version 2>&1 | awk '/^version: / || /^built with /{print "- " $0}' || true
echo "- model:   ${MODEL_PATH}"
[[ -n "${MMPROJ_PATH}" ]] && echo "- mmproj:  ${MMPROJ_PATH}"
[[ -n "${MMPROJ_PATH}" ]] && echo "- mmproj offload: ${MMPROJ_OFFLOAD}"
echo "- alias:   ${MODEL_ALIAS} (served as ${SERVED_ALIAS})"
echo "- bind:    ${HOST}:${PORT}"
echo "- context: ${CONTEXT}"
echo "- slots:   ${PARALLEL}"
echo "- batch:   b=${BATCH} ub=${UBATCH}"
echo "- KV:      ${CACHE_TYPE_K} / ${CACHE_TYPE_V}"
[[ "${NO_MMAP}" == "true" ]] && echo "- mmap:    off"
[[ -n "${FIT}" ]] && echo "- fit:     ${FIT}"
[[ -n "${LLAMACPP_TENSOR_SPLIT:-}" ]] && echo "- tensor-split: ${LLAMACPP_TENSOR_SPLIT}"
[[ -n "${LLAMACPP_RPC:-}" ]] && echo "- rpc workers: ${LLAMACPP_RPC}"
[[ -n "${CACHE_RAM}" ]] && echo "- cache-ram: ${CACHE_RAM}"
if [[ -n "${N_CPU_MOE}" && "${N_CPU_MOE}" != "0" ]]; then
  echo "- n-cpu-moe: ${N_CPU_MOE} (first N expert layers on CPU; rest on GPU)"
else
  echo "- n-cpu-moe: off (all experts on GPU / unified memory)"
fi
if [[ -n "${THREADS}" ]]; then
  echo "- threads: ${THREADS} compute / ${THREADS_HTTP} http"
fi
echo "- reasoning budget: ${REASONING_BUDGET}"
[[ -n "${PRESENCE_PENALTY_OVERRIDE}" ]] && echo "- presence-penalty override: ${PRESENCE_PENALTY_OVERRIDE}"
[[ -n "${INSTANCE}" ]] && echo "- instance: ${INSTANCE}"

if [[ "${DRY_RUN}" == "true" ]]; then
  printf '%q ' "${CMD[@]}"
  echo
  exit 0
fi

wait_until_ready() {
  local server_pid="$1" probe_host="$2"
  echo "waiting for llama.cpp readiness (timeout ${START_TIMEOUT}s)..."
  local deadline
  deadline=$(( $(date +%s) + START_TIMEOUT ))
  while : ; do
    if readiness_probe "${probe_host}"; then
      break
    fi
    if ! kill -0 "${server_pid}" 2>/dev/null && ! llamacpp_process_running; then
      [[ -f "${LOG_FILE}" ]] && tail -n 40 "${LOG_FILE}" >&2 || true
      die "llama-server exited before becoming ready"
    fi
    [[ $(date +%s) -ge ${deadline} ]] && die "timed out waiting for llama-server"
    sleep 2
  done
  echo "server is ready on http://${probe_host}:${PORT}/v1"
}

readiness_probe() {
  local probe_host="$1" health_status
  health_status="$(curl -sS \
    -o /dev/null \
    -w "%{http_code}" \
    --connect-timeout "${START_CONNECT_TIMEOUT}" \
    --max-time "${START_PROBE_TIMEOUT}" \
    "http://${probe_host}:${PORT}/health" 2>/dev/null || echo 000)"
  case "${health_status}" in
    200)
      return 0
      ;;
    404)
      curl -fsS \
        --connect-timeout "${START_CONNECT_TIMEOUT}" \
        --max-time "${START_PROBE_TIMEOUT}" \
        "http://${probe_host}:${PORT}/v1/models" >/dev/null 2>&1
      return
      ;;
    *)
      return 1
      ;;
  esac
}

llamacpp_listener_pid() {
  local pid cmd
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    cmd="$(pid_command "${pid}")"
    if [[ "${cmd}" == *"llama-server"* ]]; then
      echo "${pid}"
      return 0
    fi
  done < <(port_listener_pids "${PORT}")
  return 1
}

llamacpp_process_running() {
  local pid cmd
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    cmd="$(pid_command "${pid}")"
    if [[ "${cmd}" == *"llama-server"* && "${cmd}" == *"--port ${PORT}"* ]]; then
      return 0
    fi
  done < <(pgrep -f "llama-server" 2>/dev/null || true)
  return 1
}

record_listener_pid() {
  local actual_pid
  if actual_pid="$(llamacpp_listener_pid)"; then
    if [[ "${actual_pid}" != "$(cat "${PID_FILE}" 2>/dev/null || true)" ]]; then
      echo "${actual_pid}" > "${PID_FILE}"
      echo "- listener pid: ${actual_pid}"
    fi
  fi
}

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

wait_until_ready "${SERVER_PID}" "${probe_host}"
record_listener_pid

if [[ "${SMOKE_TEST}" == "true" ]]; then
  echo "running chat smoke test..."
  smoke_body="$(mktemp /tmp/llamacpp-smoke.XXXXXX)"
  smoke_status="$(curl -sS \
    -o "${smoke_body}" \
    -w "%{http_code}" \
    --connect-timeout "${START_CONNECT_TIMEOUT}" \
    --max-time "${SMOKE_TEST_TIMEOUT}" \
    "http://${probe_host}:${PORT}/v1/chat/completions" \
    -H "content-type: application/json" \
    -d "{\"model\":\"${SERVED_ALIAS}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly READY.\"}],\"max_tokens\":16}")" \
    || {
      rm -f "${smoke_body}"
      die "smoke test request failed"
    }
  resp="$(cat "${smoke_body}")"
  rm -f "${smoke_body}"
  if [[ "${smoke_status}" != 2* ]]; then
    echo "${resp}" >&2
    die "smoke test failed with HTTP ${smoke_status}"
  fi
  if [[ "${resp}" == *'"content"'* ]]; then
    echo "smoke test OK"
  else
    echo "${resp}" >&2
    die "smoke test did not return a chat completion"
  fi
  record_listener_pid
fi
