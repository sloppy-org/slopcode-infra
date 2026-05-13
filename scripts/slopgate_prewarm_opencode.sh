#!/usr/bin/env bash
# Refresh OpenCode slot caches for every enabled slopgate llama-server model.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

FORCE=false
CHECK_ONLY=false
PRINT_TARGETS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    --print-targets) PRINT_TARGETS=true; shift ;;
    -h|--help)
      sed -n '1,24p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

TARGETS_DEFAULT=$'slopgate/qwen|qwen|127.0.0.1|8081|opencode-prewarm-qwen.bin|com.slopcode.llamacpp\nslopgate/qwen27b|qwen27b|127.0.0.1|8082|opencode-prewarm-qwen27b.bin|com.slopcode.llamacpp-27b\nslopgate/qwen122b|qwen122b|127.0.0.1|8083|opencode-prewarm-qwen122b.bin|com.slopcode.llamacpp-122b'
TARGETS="${SLOPGATE_PREWARM_TARGETS:-${TARGETS_DEFAULT}}"
AGENTS_DIR="${AGENTS_DIR:-${HOME}/Library/LaunchAgents}"
if [[ -z "${SLOPCODE_PREWARM_DIR:-}" && -d "${HOME}/code/sloppy/slopgate" ]]; then
  export SLOPCODE_PREWARM_DIR="${HOME}/code/sloppy/slopgate"
fi

target_enabled() {
  local host="$1" port="$2" label="$3"
  curl -fsS --connect-timeout 1 --max-time 2 "http://${host}:${port}/v1/models" >/dev/null 2>&1 \
    && return 0
  [[ -f "${AGENTS_DIR}/${label}.plist" ]] && return 0
  return 1
}

args=()
[[ "${FORCE}" == "true" ]] && args+=(--force)
[[ "${CHECK_ONLY}" == "true" ]] && args+=(--check)
args+=(--no-start)

ran=0
while IFS='|' read -r model route_model host port slot_file label; do
  [[ -n "${model}" ]] || continue
  if [[ "${PRINT_TARGETS}" == "true" ]]; then
    printf '%s|%s|%s|%s|%s|%s\n' "${model}" "${route_model}" "${host}" "${port}" "${slot_file}" "${label}"
    continue
  fi
  if ! target_enabled "${host}" "${port}" "${label}"; then
    echo "skipping ${model} (${label} not enabled and ${host}:${port} not ready)"
    continue
  fi
  echo "prewarming ${model} via ${host}:${port} -> ${slot_file}"
  LLAMACPP_HOST="${host}" \
  LLAMACPP_PORT="${port}" \
  LLAMACPP_RESTORE_SLOT_FILE="${slot_file}" \
  SLOPCODE_PREWARM_MODEL="${model}" \
  SLOPCODE_PREWARM_ROUTE_MODEL="${route_model}" \
  bash "${SCRIPT_DIR}/llamacpp_prewarm_opencode.sh" "${args[@]}"
  ran=$((ran + 1))
done <<< "${TARGETS}"

if [[ "${PRINT_TARGETS}" == "true" ]]; then
  exit 0
fi
[[ "${ran}" -gt 0 ]] || die "no enabled slopgate llama-server targets found"
echo "prewarmed ${ran} slopgate target(s)"
