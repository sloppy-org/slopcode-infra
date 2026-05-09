#!/usr/bin/env bash
# Configure OpenCode for the local llama.cpp deployment.
#
# Every platform now serves a single Qwen3.6-35B-A3B UD-Q4_K_M instance with the
# blessed Qwen "precise coding + thinking" sampler (temp 0.6, top_p 0.95,
# top_k 20, min_p 0, presence 0, repeat_penalty 1.0) at 256K per-slot context.
# Linux/Windows run -c 262144 -np 1; macOS runs -c 1048576 -np 4 since the
# 27B dense companion is no longer bundled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
# Default to talking to the local llama-server. When SLOPGATE_LEADER is set
# (a host:port or bare host on the operator's WireGuard / LAN), point opencode
# at the slopgate balancer there instead. The balancer fronts every node's
# llama-server on a single port, so the rest of the config (model alias,
# context window, sampler) is identical to the local-only setup.
SLOPGATE_LEADER="${SLOPGATE_LEADER:-}"
if [[ -n "${SLOPGATE_LEADER}" ]]; then
  if [[ "${SLOPGATE_LEADER}" == *:* ]]; then
    BASE_URL="http://${SLOPGATE_LEADER}/v1"
  else
    BASE_URL="http://${SLOPGATE_LEADER}:8080/v1"
  fi
else
  HOST="${LLAMACPP_HOST:-127.0.0.1}"
  BASE_URL="http://${HOST}:8080/v1"
fi
# Per-slot context = model's native n_ctx_train (262144) on every platform.
# Linux/Windows: -c 262144 -np 1 (16 GB GPU cap). Mac M-series with >= 64 GB:
# -c 1048576 -np 4 (the freed 27B unified memory budget). Small Macs (< 64 GB)
# stay at 131072 per slot to keep KV within available memory.
CONTEXT_SIZE_DEFAULT=262144
if [[ "${PLATFORM}" == "mac" ]]; then
  ram_gb="$(detect_total_ram_gb)"
  [[ "${ram_gb}" -lt 64 ]] && CONTEXT_SIZE_DEFAULT=131072
fi
CONTEXT_SIZE="${OPENCODE_LOCAL_CONTEXT:-${CONTEXT_SIZE_DEFAULT}}"
OUTPUT_LIMIT="${OPENCODE_LOCAL_OUTPUT:-16384}"
THINKING_BUDGET="${OPENCODE_LOCAL_THINKING_BUDGET:-$(default_reasoning_budget)}"

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${CONFIG_DIR}/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.slopcode-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
  cp "${CONFIG_PATH}" "${BACKUP_PATH}"
  echo "backup: ${BACKUP_PATH}"
fi

sampler_opts() {
  cat <<EOF
"temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "presence_penalty": 0.0, "repeat_penalty": 1.0, "thinking_budget": ${THINKING_BUDGET}
EOF
}

model_block() {
  local id="$1" name="$2"
  cat <<EOF
        "${id}": {
          "name": "${name}",
          "limit": {"context": ${CONTEXT_SIZE}, "output": ${OUTPUT_LIMIT}},
          "reasoning": true,
          "interleaved": {"field": "reasoning_content"},
          "attachment": true,
          "tool_call": true,
          "modalities": {"input": ["text", "image"], "output": ["text"]},
          "options": {$(sampler_opts)}
        }
EOF
}

provider_block_single() {
  local id="$1" name="$2"
  local headers_block=""
  if [[ -n "${SLOPGATE_LEADER}" ]]; then
    # Stable per-host opaque session id so multi-turn opencode runs land on the
    # same backend agent (slopgate's optional x-session-affinity routing).
    local session_id_file="${HOME}/.config/slopgate/opencode-session-id"
    local session_id=""
    if [[ -f "${session_id_file}" ]]; then
      session_id="$(<"${session_id_file}")"
    fi
    if [[ -z "${session_id}" ]]; then
      mkdir -p "$(dirname "${session_id_file}")"
      session_id="$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
      printf '%s\n' "${session_id}" > "${session_id_file}"
    fi
    headers_block=", \"headers\": {\"x-session-affinity\": \"${session_id}\"}"
  fi
  cat <<EOF
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (Local)",
      "options": {"baseURL": "${BASE_URL}"${headers_block}},
      "models": {
$(model_block "${id}" "${name}")
      }
    }
  }
EOF
}

DEFAULT_MODEL="${OPENCODE_LOCAL_DEFAULT_MODEL:-llamacpp/qwen}"
SMALL_MODEL="${OPENCODE_LOCAL_SMALL_MODEL:-llamacpp/qwen}"
PROVIDER_BLOCK="$(provider_block_single qwen "Qwen3.6 35B A3B Q4 + KV-Q8 (Local)")"
DISABLED='"disabled_providers": ["exa", "opencode", "llmgateway", "github-copilot", "copilot", "openai", "anthropic", "google", "mistral", "groq", "xai", "ollama"]'

cat > "${CONFIG_PATH}" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "${DEFAULT_MODEL}",
  "small_model": "${SMALL_MODEL}",
  "agent": {
    "title": {"disable": true}
  },
  "share": "disabled",
  "autoupdate": false,
  "permission": "allow",
  "tools": {
    "websearch": false
  },
  "experimental": {
    "openTelemetry": false
  },
  ${DISABLED},
${PROVIDER_BLOCK}
}
EOF

if [[ "${OPENCODE_SKIP_PRIVACY_ENV:-false}" != "true" ]]; then
  bash "${SCRIPT_DIR}/opencode_privacy.sh"
fi

echo "configured OpenCode:"
echo "- config: ${CONFIG_PATH}"
echo "- default model: ${DEFAULT_MODEL}"
echo "- small model:   ${SMALL_MODEL}"
echo "- baseURL:    ${BASE_URL}"
echo "- title:      disabled"
echo "- permission: allow"
echo "- thinking budget: ${THINKING_BUDGET}"
echo "- mcp servers: (none — add via per-tool installers if you use any)"
