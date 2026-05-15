#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/.run}"
LOG_DIR="${LOG_DIR:-${RUN_DIR}}"
LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp}"
case "$(uname -s)" in
  Darwin) DEFAULT_CACHE_ROOT="${HOME}/Library/Caches/llama.cpp" ;;
  *)      DEFAULT_CACHE_ROOT="${HOME}/.cache/llama.cpp" ;;
esac
# Prefer the shared /Volumes/AI cache when the per-user path is missing or
# already a symlink into it. See docs/ai-share.md.
if [[ -d /Volumes/AI/llama.cpp ]] && { [[ ! -e "${DEFAULT_CACHE_ROOT}" ]] || [[ -L "${DEFAULT_CACHE_ROOT}" ]]; }; then
  DEFAULT_CACHE_ROOT="/Volumes/AI/llama.cpp"
fi
LLAMACPP_CACHE_ROOT="${LLAMACPP_CACHE_ROOT:-${DEFAULT_CACHE_ROOT}}"
export LLAMA_CACHE="${LLAMA_CACHE:-${LLAMACPP_CACHE_ROOT}}"

mkdir -p "${RUN_DIR}"

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

detect_platform() {
  case "$(uname -s)" in
    Darwin) echo "mac" ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) die "unsupported platform: $(uname -s)" ;;
  esac
}

detect_gpu() {
  case "$(detect_platform)" in
    mac) echo "metal" ;;
    linux|wsl)
      if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
        echo "cuda"
      elif have vulkaninfo && vulkaninfo --summary >/dev/null 2>&1; then
        echo "vulkan"
      else
        echo "cpu"
      fi
      ;;
    windows) echo "vulkan" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) echo "$(uname -m)" ;;
  esac
}

# Total physical RAM in GiB (rounded down). Used to decide single vs dual
# instance on Mac and to size context windows.
detect_total_ram_gb() {
  local gb=""
  case "$(uname -s)" in
    Darwin)
      local bytes
      bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
      gb=$(( bytes / 1073741824 ))
      ;;
    Linux)
      if [[ -r /proc/meminfo ]]; then
        local kb
        kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
        gb=$(( kb / 1048576 ))
      fi
      ;;
  esac
  [[ -z "${gb}" || "${gb}" -eq 0 ]] && gb=0
  echo "${gb}"
}

pid_command() { ps -p "$1" -o command= 2>/dev/null || true; }
port_listener_pids() { lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true; }

# Count physical CPU cores. Falls back to logical count if topology is hidden
# (containers, WSL without /proc/cpuinfo detail, BSDs). Output is always >= 1.
detect_physical_cores() {
  local n=""
  case "$(uname -s)" in
    Darwin)
      n="$(sysctl -n hw.physicalcpu 2>/dev/null || true)"
      ;;
    Linux)
      if have lscpu; then
        n="$(lscpu -p=core 2>/dev/null | awk -F, '!/^#/ && NF {print $1}' | sort -u | wc -l | tr -d ' ')"
      fi
      if [[ -z "${n}" || "${n}" == "0" ]] && [[ -r /proc/cpuinfo ]]; then
        n="$(awk '/^core id/ {print $NF}' /proc/cpuinfo | sort -u | wc -l | tr -d ' ')"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if have wmic; then
        n="$(wmic cpu get NumberOfCores /value 2>/dev/null | tr -d '\r' | awk -F= '/NumberOfCores=/{s+=$2} END{print s}')"
      fi
      ;;
  esac
  if [[ -z "${n}" || "${n}" == "0" ]]; then
    n="$(nproc 2>/dev/null || echo 1)"
  fi
  [[ "${n}" -ge 1 ]] || n=1
  echo "${n}"
}

# Reasonable --threads default: leave 2 physical cores for the host so the
# desktop, Claude Code's HTTP client, and opencode's Bun HTTP pool don't
# starve during --cpu-moe decode (which is the documented cause of stalls
# that trip idle-timeout RSTs on concurrent unrelated TCP streams). Floor
# at 2 for tiny hosts so we don't silently degrade into single-threaded.
default_compute_threads() {
  local available="" phys reserve=2 threads
  if [[ -n "${SLURM_CPUS_PER_TASK:-}" && "${SLURM_CPUS_PER_TASK}" =~ ^[0-9]+$ && "${SLURM_CPUS_PER_TASK}" -gt 0 ]]; then
    available="${SLURM_CPUS_PER_TASK}"
  elif [[ -n "${SLURM_CPUS_ON_NODE:-}" && "${SLURM_CPUS_ON_NODE}" =~ ^[0-9]+$ && "${SLURM_CPUS_ON_NODE}" -gt 0 ]]; then
    available="${SLURM_CPUS_ON_NODE}"
  else
    phys="$(detect_physical_cores)"
    available="${phys}"
  fi
  threads=$(( available - reserve ))
  [[ "${threads}" -lt 2 ]] && threads=2
  echo "${threads}"
}

default_reasoning_budget() {
  # Cap hidden reasoning so Qwen does not burn the whole turn in long agent
  # loops. Set LLAMACPP_REASONING_BUDGET=-1 to make thinking unrestricted.
  echo "4096"
}

resolve_llamacpp_server_bin() {
  local server_exe="llama-server"
  [[ "$(detect_platform)" == "windows" ]] && server_exe="llama-server.exe"

  if [[ -n "${LLAMACPP_SERVER_BIN:-}" ]]; then
    echo "${LLAMACPP_SERVER_BIN}"
  elif [[ -x "${LLAMACPP_HOME}/${server_exe}" ]]; then
    echo "${LLAMACPP_HOME}/${server_exe}"
  elif have "${server_exe}"; then
    command -v "${server_exe}"
  else
    return 1
  fi
}

stop_pid() {
  local pid="$1" label="${2:-process}"
  kill -0 "${pid}" 2>/dev/null || return 0
  kill "${pid}" 2>/dev/null || true
  for _ in {1..30}; do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 1
  done
  warn "${label} pid ${pid} did not exit after SIGTERM; sending SIGKILL"
  kill -9 "${pid}" 2>/dev/null || true
}

stop_llamacpp_port_occupants() {
  local port="$1" label="${2:-llama.cpp server}"
  local pids pid cmd
  pids="$(port_listener_pids "${port}")"
  [[ -n "${pids}" ]] || return 0
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    cmd="$(pid_command "${pid}")"
    if [[ "${cmd}" != *"llama-server"* ]]; then
      die "port ${port} is occupied by a non-llama process (pid ${pid}: ${cmd})"
    fi
    echo "stopping ${label} on port ${port} (pid ${pid})..."
    stop_pid "${pid}" "${label}"
  done <<< "${pids}"
}
