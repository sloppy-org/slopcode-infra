#!/usr/bin/env bash
# Switch which MLX model the exclusive-big-model Mac serves and re-stamp the
# slopgate agent identity to match. One model is active at a time.
#
#   minimax  -> pipenetwork/MiniMax-M3-MLX-mixed-3_6bit  (alias minimax)
#   deepseek -> Deviad/DeepSeek-V4-Flash-MLX-Q4Q8        (alias deepseek)
#
# Re-runs install_mac_mlx_launchagent.sh for the chosen alias, which rewrites
# com.slopcode.mlx + com.slopcode.slopgate-agent-mlx and restarts both. The
# balancer and followers are untouched.
#
# Usage:
#   scripts/mlx_switch.sh                 # print the active alias
#   scripts/mlx_switch.sh minimax         # serve MiniMax M3 mixed-3/6-bit
#   scripts/mlx_switch.sh deepseek        # serve DeepSeek V4-Flash
#
# Env overrides:
#   MLX_SWITCH_FORCE   true to switch even if the target model is not on disk
#   INSTALL_DRY_RUN    forwarded to the installer (write plists, no launchctl)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

MODELS_SCRIPT="${SCRIPT_DIR}/mlx_models.py"
AGENTS_DIR="${HOME}/Library/LaunchAgents"
SERVER_PLIST="${AGENTS_DIR}/com.slopcode.mlx.plist"

alias_for() {
  case "$1" in
    minimax|minimax-m3|m3|mixed) echo "minimax-m3-mixed" ;;
    minimax-4bit|4bit)           echo "minimax-m3-4bit" ;;
    deepseek|v4-flash|deepseek-v4-flash) echo "deepseek-v4-flash" ;;
    *) return 1 ;;
  esac
}

print_status() {
  local active="<unset>"
  if [[ -f "${SERVER_PLIST}" ]]; then
    active="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:MLX_MODEL_ALIAS' "${SERVER_PLIST}" 2>/dev/null || echo '<unset>')"
  fi
  echo "active MLX alias: ${active}"
  python3 "${MODELS_SCRIPT}" inventory
}

TARGET="${1:-}"
if [[ -z "${TARGET}" || "${TARGET}" == "status" || "${TARGET}" == "--status" ]]; then
  print_status
  exit 0
fi

ALIAS="$(alias_for "${TARGET}")" || die "unknown model '${TARGET}'. Use: minimax | deepseek"

if [[ "${MLX_SWITCH_FORCE:-false}" != "true" ]]; then
  if ! python3 "${MODELS_SCRIPT}" resolve "${ALIAS}" >/dev/null 2>&1; then
    die "model for ${ALIAS} not on disk.
download it first:  python3 ${MODELS_SCRIPT} prefetch ${ALIAS}
or pass MLX_SWITCH_FORCE=true to switch anyway."
  fi
fi

echo "switching MLX host to ${ALIAS}"
MLX_ALIAS="${ALIAS}" exec "${SCRIPT_DIR}/install_mac_mlx_launchagent.sh"
