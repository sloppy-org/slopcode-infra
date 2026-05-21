#!/usr/bin/env bash
# Configure Pi Coding Agent to use the local llama.cpp OpenAI-compatible API.
#
# Every platform serves a single Qwen3.6-35B-A3B UD-Q4_K_XL instance:
#   * llamacpp -> 127.0.0.1:8080 (qwen, MoE, image input)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
HOST="${LLAMACPP_HOST:-127.0.0.1}"
CONTEXT_SIZE_DEFAULT=180000
if [[ "${PLATFORM}" == "mac" ]]; then
  ram_gb="$(detect_total_ram_gb)"
  [[ "${ram_gb}" -lt 64 ]] && CONTEXT_SIZE_DEFAULT=131072
fi
CONTEXT_SIZE="${PI_LOCAL_CONTEXT:-${CONTEXT_SIZE_DEFAULT}}"
OUTPUT_LIMIT="${PI_LOCAL_OUTPUT:-16384}"
THINKING_LEVEL="${PI_LOCAL_THINKING_LEVEL:-high}"

CONFIG_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
SETTINGS_PATH="${CONFIG_DIR}/settings.json"
MODELS_PATH="${CONFIG_DIR}/models.json"
mkdir -p "${CONFIG_DIR}"

python3 - "${SETTINGS_PATH}" "${MODELS_PATH}" "${HOST}" "${CONTEXT_SIZE}" "${OUTPUT_LIMIT}" "${THINKING_LEVEL}" <<'PY'
import json
import pathlib
import sys

settings_path = pathlib.Path(sys.argv[1])
models_path = pathlib.Path(sys.argv[2])
host = sys.argv[3]
context = int(sys.argv[4])
output = int(sys.argv[5])
thinking = sys.argv[6]

def read_json(path):
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        backup = path.with_suffix(path.suffix + ".slopcode-infra.bak")
        backup.write_text(path.read_text())
        return {}

compat = {
    "supportsDeveloperRole": False,
    "supportsReasoningEffort": False,
    "supportsUsageInStreaming": False,
    "maxTokensField": "max_tokens",
}
zero_cost = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}

def model_entry(model_id, name, image):
    return {
        "id": model_id,
        "name": name,
        "reasoning": True,
        "input": ["text", "image"] if image else ["text"],
        "contextWindow": context,
        "maxTokens": output,
        "cost": zero_cost,
    }

settings = read_json(settings_path)
models = read_json(models_path)
providers = models.setdefault("providers", {})

providers["llamacpp"] = {
    "baseUrl": f"http://{host}:8080/v1",
    "api": "openai-completions",
    "apiKey": "llamacpp",
    "compat": compat,
    "models": [model_entry("qwen", "Qwen3.6 35B A3B Q4 + KV-Q8 (Local llama.cpp)", image=True)],
}
settings.update({
    "defaultProvider": "llamacpp",
    "defaultModel": "qwen",
    "defaultThinkingLevel": thinking,
    "enabledModels": ["llamacpp/qwen"],
    "enableInstallTelemetry": False,
})
# Strip any orphaned dual-instance provider from previous installs.
providers.pop("llamacpp-moe", None)

settings_path.write_text(json.dumps(settings, indent=2) + "\n")
models_path.write_text(json.dumps(models, indent=2) + "\n")
PY

if [[ "${PI_SKIP_PRIVACY_ENV:-false}" != "true" ]]; then
  bash "${SCRIPT_DIR}/pi_privacy.sh"
fi

echo "configured Pi:"
echo "- settings: ${SETTINGS_PATH}"
echo "- models:   ${MODELS_PATH}"
echo "- provider: llamacpp -> :8080 (qwen, image)"
echo "- context:  ${CONTEXT_SIZE}"
echo "- output:   ${OUTPUT_LIMIT}"
echo "- thinking: ${THINKING_LEVEL}"
