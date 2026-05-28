#!/usr/bin/env bash
# Switch which Qwen3.6 model this dual-GPU host serves, and re-stamp the
# slopgate follower identity to match.
#
# Built for a 32 GB-class box (e.g. 2x RTX 5060 Ti 16 GB) that serves the
# whole model GPU-only. Two profiles:
#
#   35b -> Qwen3.6-35B-A3B MoE, served as slopgate alias `qwen`
#   27b -> Qwen3.6-27B dense,   served as slopgate alias `qwen27b`
#
# Both run the UD-Q4_K_XL MTP GGUF with --n-cpu-moe disabled (all expert
# layers on the GPUs; MoE has no tensor-parallel path in llama.cpp, so the
# split is by layer). Because the 35B-A3B is hybrid-attention its KV is
# tiny; the dense 27B carries a larger KV but still fits in 32 GB at 128K.
#
# The two services are host-local state, not tracked in this repo:
#   - llama-server drop-in:  ~/.config/systemd/user/slopcode-llamacpp.service.d/wg-only.conf
#   - slopgate follower env: ~/.config/slopgate/follower.env
# This script edits the model-identity keys in place and leaves every
# host-specific value (WG addresses, agent name, machine profile, digest)
# untouched.
#
# Usage:
#   scripts/serve_switch.sh                 # print the active profile
#   scripts/serve_switch.sh 35b             # switch to 35B-A3B (alias qwen)
#   scripts/serve_switch.sh 27b             # switch to 27B dense (alias qwen27b)
#
# Env overrides:
#   SERVE_SWITCH_DROPIN   llama-server systemd drop-in path
#   SERVE_SWITCH_ENV_FILE slopgate follower env path
#   SERVE_SWITCH_DRY_RUN  true to edit files but skip systemctl restarts
#   SERVE_SWITCH_FORCE    true to switch even if the target GGUF is absent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

DROPIN="${SERVE_SWITCH_DROPIN:-${HOME}/.config/systemd/user/slopcode-llamacpp.service.d/wg-only.conf}"
ENV_FILE="${SERVE_SWITCH_ENV_FILE:-${HOME}/.config/slopgate/follower.env}"
DRY_RUN="${SERVE_SWITCH_DRY_RUN:-false}"
FORCE="${SERVE_SWITCH_FORCE:-false}"
MODELS_SCRIPT="${SCRIPT_DIR}/llamacpp_models.py"

# Profile table. Columns:
#   llamacpp_alias | canonical | slopgate_alias | slopgate_aliases | quant | max_context
profile_for() {
  case "$1" in
    35b|35B|qwen|qwen35|35b-a3b)
      echo "qwen3.6-35b-a3b-mtp-q4|unsloth/qwen3.6:35b-a3b@128k|qwen|35b,35b@128k,Q4|UD-Q4_K_XL-MTP|131072"
      ;;
    27b|27B|qwen27b|qwen27|27b-dense)
      echo "qwen3.6-27b-mtp-q4|unsloth/qwen3.6:27b@128k|qwen27b|qwen3.6-27b,qwen3.6-27b@128k|UD-Q4_K_XL-MTP|131072"
      ;;
    *)
      return 1
      ;;
  esac
}

# Update a "KEY=value" line in a file in place (preserving the rest), or
# append it if absent. PREFIX lets the same helper drive both plain dotenv
# (prefix "") and systemd "Environment=KEY=value" (prefix "Environment=").
set_kv() {
  local file="$1" key="$2" val="$3" prefix="${4:-}"
  python3 - "$file" "$key" "$val" "$prefix" <<'PY'
import sys
path, key, val, prefix = sys.argv[1:5]
with open(path) as f:
    lines = f.read().splitlines()
target = f"{prefix}{key}="
new = f"{prefix}{key}={val}"
for i, ln in enumerate(lines):
    s = ln.lstrip()
    if s.startswith(target):
        indent = ln[: len(ln) - len(s)]
        lines[i] = indent + new
        break
else:
    lines.append(new)
with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
PY
}

get_kv() {
  local file="$1" key="$2" prefix="${3:-}"
  [[ -f "${file}" ]] || return 1
  sed -n "s/^[[:space:]]*${prefix}${key}=//p" "${file}" | tail -n1
}

print_status() {
  local alias quant
  alias="$(get_kv "${DROPIN}" LLAMACPP_MODEL_ALIAS Environment= 2>/dev/null || true)"
  quant="$(get_kv "${ENV_FILE}" SLOPGATE_QUANT 2>/dev/null || true)"
  local sg_alias
  sg_alias="$(get_kv "${ENV_FILE}" SLOPGATE_MODEL_ALIAS 2>/dev/null || true)"
  echo "active model alias:   ${alias:-<unset>}"
  echo "slopgate alias/quant: ${sg_alias:-<unset>} / ${quant:-<unset>}"
}

TARGET="${1:-}"
if [[ -z "${TARGET}" || "${TARGET}" == "--status" || "${TARGET}" == "status" ]]; then
  print_status
  exit 0
fi

PROFILE="$(profile_for "${TARGET}")" || die "unknown model '${TARGET}'. Use: 35b | 27b"
IFS='|' read -r P_ALIAS P_CANONICAL P_SGALIAS P_SGALIASES P_QUANT P_CONTEXT <<< "${PROFILE}"

[[ -f "${DROPIN}" ]] || die "missing llama-server drop-in: ${DROPIN}
create it from config/slopcode/llamacpp-dual-gpu.conf.example and set your WG bind address."
[[ -f "${ENV_FILE}" ]] || die "missing slopgate follower env: ${ENV_FILE}
create it from config/slopgate/follower.env.example."

# Refuse to switch onto a model that isn't on disk (it would fail to start),
# unless forced. Resolve against the cache root the drop-in actually uses.
CACHE_ROOT="$(get_kv "${DROPIN}" LLAMACPP_CACHE_ROOT Environment= 2>/dev/null || true)"
if [[ "${FORCE}" != "true" ]]; then
  if ! LLAMACPP_CACHE_ROOT="${CACHE_ROOT}" python3 "${MODELS_SCRIPT}" resolve "${P_ALIAS}" >/dev/null 2>&1; then
    die "GGUF for ${P_ALIAS} not found under ${CACHE_ROOT:-<default cache>}.
download it first:  LLAMACPP_CACHE_ROOT=${CACHE_ROOT} scripts/llamacpp_models.py prefetch ${P_ALIAS}
or pass SERVE_SWITCH_FORCE=true to switch anyway."
  fi
fi

echo "switching to ${TARGET}:"
echo "- llama alias:    ${P_ALIAS}"
echo "- slopgate alias: ${P_SGALIAS} (aliases: ${P_SGALIASES})"
echo "- canonical:      ${P_CANONICAL}"
echo "- quant:          ${P_QUANT}"
echo "- max context:    ${P_CONTEXT}"

# llama-server side: pick the model, keep it GPU-only.
set_kv "${DROPIN}" LLAMACPP_MODEL_ALIAS "${P_ALIAS}" "Environment="
set_kv "${DROPIN}" LLAMACPP_N_CPU_MOE 0 "Environment="
set_kv "${DROPIN}" LLAMACPP_CONTEXT "${P_CONTEXT}" "Environment="

# slopgate side: re-stamp the model identity the agent advertises.
set_kv "${ENV_FILE}" SLOPGATE_CANONICAL_MODEL "${P_CANONICAL}"
set_kv "${ENV_FILE}" SLOPGATE_MODEL_ALIAS "${P_SGALIAS}"
set_kv "${ENV_FILE}" SLOPGATE_MODEL_ALIASES "${P_SGALIASES}"
set_kv "${ENV_FILE}" SLOPGATE_QUANT "${P_QUANT}"
set_kv "${ENV_FILE}" SLOPGATE_MAX_CONTEXT "${P_CONTEXT}"

echo "updated ${DROPIN}"
echo "updated ${ENV_FILE}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "SERVE_SWITCH_DRY_RUN=true; skipping service restarts."
  exit 0
fi

have systemctl || die "systemctl not found; restart slopcode-llamacpp + slopgate-agent manually."
echo "restarting llama-server (model reload can take ~1 min)..."
systemctl --user daemon-reload
systemctl --user restart slopcode-llamacpp.service
# The agent re-reads the env file and re-registers the new identity; it
# reconnects on its own once llama-server is back up.
systemctl --user restart slopgate-agent.service
echo "done. verify with:"
echo "  journalctl --user -u slopcode-llamacpp -n 30 --no-pager | grep -E 'offloaded|KV|alias'"
echo "  systemctl --user status slopgate-agent --no-pager"
