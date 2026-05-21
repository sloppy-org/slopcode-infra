#!/usr/bin/env bash
# Configure OpenCode for slopgate llama.cpp routing. The 122B-A10B MoE model
# is the default coding model; the 35B-A3B MoE model is the fast/agent model;
# the dense 27B model stays available as an explicit option.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

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
CONTEXT_SIZE_DEFAULT=180000
CONTEXT_SIZE="${OPENCODE_LOCAL_CONTEXT:-${CONTEXT_SIZE_DEFAULT}}"
OUTPUT_LIMIT="${OPENCODE_LOCAL_OUTPUT:-16384}"
THINKING_BUDGET="${OPENCODE_LOCAL_THINKING_BUDGET:-$(default_reasoning_budget)}"

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${CONFIG_DIR}/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"
EXISTING_CONFIG=""
if [[ -f "${CONFIG_PATH}" ]]; then
  EXISTING_CONFIG="$(mktemp)"
  cp "${CONFIG_PATH}" "${EXISTING_CONFIG}"
fi

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

session_id() {
  local session_id_file="${HOME}/.config/slopgate/opencode-session-id"
  local id=""
  if [[ -f "${session_id_file}" ]]; then
    id="$(<"${session_id_file}")"
  fi
  if [[ -z "${id}" ]]; then
    mkdir -p "$(dirname "${session_id_file}")"
    id="$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
    printf '%s\n' "${id}" > "${session_id_file}"
  fi
  printf '%s' "${id}"
}

providers_block() {
  local sid
  sid="$(session_id)"
  cat <<EOF
  "provider": {
    "slopgate": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "slopgate",
      "options": {"baseURL": "${BASE_URL}", "headers": {"x-session-affinity": "${sid}"}},
      "models": {
$(model_block "qwen122b" "qwen122b"),
$(model_block "qwen" "qwen"),
$(model_block "qwen27b" "qwen27b")
      }
    }
  }
EOF
}

DEFAULT_MODEL="${OPENCODE_LOCAL_DEFAULT_MODEL:-slopgate/qwen122b}"
SMALL_MODEL="${OPENCODE_LOCAL_SMALL_MODEL:-slopgate/qwen}"
PROVIDER_BLOCK="$(providers_block)"
DISABLED='"disabled_providers": ["exa", "opencode", "llmgateway", "github-copilot", "copilot", "openai", "anthropic", "google", "mistral", "groq", "xai", "ollama"]'

cat > "${CONFIG_PATH}" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "${DEFAULT_MODEL}",
  "small_model": "${SMALL_MODEL}",
  "agent": {
    "folder-note": {
      "description": "Text-only folder-note synthesis from attached payloads. All tools are disabled so source context comes only from the prompt.",
      "mode": "primary",
      "model": "${DEFAULT_MODEL}",
      "prompt": "You are a text-only Markdown synthesis agent. Use only the user message and attached files as context. Do not call tools. The confidential local-only subtree ~/Nextcloud/personal/ must not be summarized into shared brain notes or mentioned unless the user explicitly asks for a local-only Qwen task.",
      "permission": {"*": "deny"}
    },
    "explore": {
      "description": "Fast read-only codebase exploration. Search and locate; never edit.",
      "mode": "subagent",
      "model": "${SMALL_MODEL}"
    },
    "scout": {
      "description": "Read-only external docs and dependency research.",
      "mode": "subagent",
      "model": "${SMALL_MODEL}"
    },
    "brain-evidence-scout": {
      "description": "Bounded evidence discovery for Markdown brain notes. MCP tools may be used, but the agent writes only an evidence report.",
      "mode": "primary",
      "model": "${SMALL_MODEL}",
      "prompt": "You are an evidence scout for Christopher Albert's Markdown brain. Use the requested source classes only. Keep work and private spheres separate. Use sloppy only for mail, contacts, calendars, and tasks. Use helpy for web, TUGonline, ICS, office, and SAP-style sources. Do not edit files. Do not update canonical notes. Do not inspect or mention ~/Nextcloud/personal/ unless the user explicitly requests a local-only Qwen task; never write its contents or metadata into shared brain outputs. Return only a Markdown evidence report with source type, query, date or timestamp when available, stable identifier or URL/path, short finding, and open gaps. If evidence is weak or conflicting, say so explicitly.",
      "permission": {"*": "allow"}
    },
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

if [[ -n "${EXISTING_CONFIG}" ]]; then
  python3 - "${EXISTING_CONFIG}" "${CONFIG_PATH}" <<'PY'
import json
import sys

old_path, new_path = sys.argv[1:]
try:
    with open(old_path, encoding="utf-8") as f:
        old = json.load(f)
except Exception:
    old = {}
with open(new_path, encoding="utf-8") as f:
    new = json.load(f)
mcp = old.get("mcp")
if isinstance(mcp, dict) and mcp:
    new["mcp"] = mcp
with open(new_path, "w", encoding="utf-8") as f:
    json.dump(new, f, indent=2)
    f.write("\n")
PY
  rm -f "${EXISTING_CONFIG}"
fi

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
