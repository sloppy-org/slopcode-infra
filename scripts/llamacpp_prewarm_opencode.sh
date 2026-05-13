#!/usr/bin/env bash
# Build or refresh the llama-server slot cache for OpenCode's startup prompt.
#
# The script runs one non-editing OpenCode request against the local
# llama.cpp endpoint, then asks llama-server to save slot 0. Re-run with
# --force after AGENTS.md, OpenCode, or MCP plugin changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

have curl || die "curl is required"
have python3 || die "python3 is required"
have opencode || die "opencode is required"

FORCE=false
CHECK_ONLY=false
START_SERVER=true
PRINT_FINGERPRINT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    --no-start) START_SERVER=false; shift ;;
    --print-fingerprint) PRINT_FINGERPRINT=true; shift ;;
    -h|--help)
      sed -n '1,28p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

PORT="${LLAMACPP_PORT:-8080}"
HOST="${LLAMACPP_HOST:-127.0.0.1}"
[[ "${HOST}" == "0.0.0.0" ]] && HOST="127.0.0.1"
BASE_URL="http://${HOST}:${PORT}"
SLOT_ID="${LLAMACPP_RESTORE_SLOT_ID:-0}"
SLOT_FILE="${LLAMACPP_RESTORE_SLOT_FILE:-opencode-prewarm-slot.bin}"
SLOT_SAVE_PATH="${LLAMACPP_SLOT_SAVE_PATH:-${LLAMACPP_CACHE_ROOT}/slots}"
MANIFEST="${SLOT_SAVE_PATH}/${SLOT_FILE}.manifest.json"
PROMPT="${SLOPCODE_PREWARM_PROMPT:-Reply with exactly SLOPCODE_PREWARM_READY. Do not edit files.}"
MODEL="${SLOPCODE_PREWARM_MODEL:-llamacpp/qwen}"
PREWARM_DIR="${SLOPCODE_PREWARM_DIR:-${PWD}}"

if ! LLAMA_SERVER="$(resolve_llamacpp_server_bin)"; then
  die "llama-server not installed. Run: scripts/setup_llamacpp.sh"
fi

WATCH_PATHS_DEFAULT="${HOME}/AGENTS.md:${HOME}/.config/opencode/AGENTS.md:${HOME}/.config/opencode/opencode.json:${HOME}/.config/opencode/plugin:${HOME}/.config/opencode/plugins:${HOME}/.config/opencode/mcp:${HOME}/.config/opencode/mcp.json:${HOME}/.config/helpy/mcp.env:${REPO_ROOT}/.sloptools:${PREWARM_DIR}/AGENTS.md:${PREWARM_DIR}/CLAUDE.md"
WATCH_PATHS="${SLOPCODE_PREWARM_WATCH_PATHS:-${WATCH_PATHS_DEFAULT}}"
OPENCODE_VERSION="$(opencode --version 2>/dev/null || true)"
LLAMA_VERSION="$("${LLAMA_SERVER}" --version 2>/dev/null | sed -n '1,2p' || true)"

fingerprint() {
  python3 - "${OPENCODE_VERSION}" "${LLAMA_VERSION}" "${WATCH_PATHS}" "${MODEL}" "${BASE_URL}" "${SLOT_FILE}" <<'PY'
import hashlib
import os
import sys

opencode_version, llama_version, watch_paths, model, base_url, slot_file = sys.argv[1:]
h = hashlib.sha256()
h.update(b"slopcode-opencode-prewarm-v1\0")
h.update(opencode_version.encode() + b"\0")
h.update(llama_version.encode() + b"\0")
h.update(model.encode() + b"\0")
h.update(base_url.encode() + b"\0")
h.update(slot_file.encode() + b"\0")
for raw in watch_paths.split(":"):
    if not raw:
        continue
    path = os.path.expanduser(raw)
    if not os.path.exists(path):
        h.update(f"missing\0{path}\0".encode())
        continue
    if os.path.isfile(path):
        paths = [path]
    else:
        paths = []
        for root, dirs, files in os.walk(path):
            dirs[:] = [d for d in dirs if d not in {".git", "node_modules", "__pycache__"}]
            for name in files:
                paths.append(os.path.join(root, name))
        paths.sort()
    for item in paths:
        h.update(f"file\0{item}\0".encode())
        try:
            with open(item, "rb") as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b""):
                    h.update(chunk)
        except OSError as exc:
            h.update(f"unreadable\0{exc}\0".encode())
print(h.hexdigest())
PY
}

CURRENT_FINGERPRINT="$(fingerprint)"
if [[ "${PRINT_FINGERPRINT}" == "true" ]]; then
  echo "${CURRENT_FINGERPRINT}"
  exit 0
fi

manifest_fingerprint() {
  [[ -f "${MANIFEST}" ]] || return 1
  python3 - "${MANIFEST}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f).get("fingerprint", ""))
PY
}

mkdir -p "${SLOT_SAVE_PATH}"
OLD_FINGERPRINT="$(manifest_fingerprint 2>/dev/null || true)"
if [[ "${CHECK_ONLY}" == "true" ]]; then
  if [[ -f "${SLOT_SAVE_PATH}/${SLOT_FILE}" && "${OLD_FINGERPRINT}" == "${CURRENT_FINGERPRINT}" ]]; then
    echo "fresh: ${SLOT_SAVE_PATH}/${SLOT_FILE}"
    exit 0
  fi
  echo "stale: ${SLOT_SAVE_PATH}/${SLOT_FILE}"
  exit 1
fi

if [[ "${FORCE}" != "true" && -f "${SLOT_SAVE_PATH}/${SLOT_FILE}" \
      && "${OLD_FINGERPRINT}" == "${CURRENT_FINGERPRINT}" ]]; then
  echo "prewarm cache already fresh: ${SLOT_SAVE_PATH}/${SLOT_FILE}"
  exit 0
fi

server_ready() {
  curl -fsS --connect-timeout 2 --max-time 5 "${BASE_URL}/v1/models" >/dev/null 2>&1
}

if ! server_ready; then
  [[ "${START_SERVER}" == "true" ]] || die "llama-server is not ready at ${BASE_URL}"
  echo "starting llama-server for prewarm..."
  LLAMACPP_SLOT_SAVE_PATH="${SLOT_SAVE_PATH}" \
  LLAMACPP_RESTORE_SLOT_CACHE=false \
  LLAMACPP_SMOKE_TEST=false \
  bash "${SCRIPT_DIR}/server_start_llamacpp.sh"
fi
server_ready || die "llama-server is not ready at ${BASE_URL}"

TMP_PROJECT=""
TMP_CONFIG=""
cleanup() {
  [[ -z "${TMP_PROJECT}" ]] || rm -rf "${TMP_PROJECT}"
  [[ -z "${TMP_CONFIG}" ]] || rm -f "${TMP_CONFIG}"
}
trap cleanup EXIT

if [[ ! -d "${PREWARM_DIR}" ]]; then
  TMP_PROJECT="$(mktemp -d /tmp/slopcode-opencode-prewarm.XXXXXX)"
  PREWARM_DIR="${TMP_PROJECT}"
  cat > "${PREWARM_DIR}/README.md" <<'EOF'
Temporary project for slopcode OpenCode prompt-cache prewarm.
EOF
fi

prepare_direct_config() {
  [[ "${SLOPCODE_PREWARM_DIRECT_CONFIG:-true}" == "true" ]] || return 0
  local config_path="${OPENCODE_CONFIG_PATH:-${HOME}/.config/opencode/opencode.json}"
  [[ -f "${config_path}" ]] || return 0

  TMP_CONFIG="$(mktemp /tmp/slopcode-opencode-config.XXXXXX.json)"
  python3 - "${config_path}" "${TMP_CONFIG}" "${MODEL}" "${BASE_URL}/v1" "${SLOPCODE_PREWARM_ROUTE_MODEL:-}" <<'PY'
import json
import sys

src, dst, model, base_url, route_model = sys.argv[1:]
provider, _, model_id = model.partition("/")
if not provider or not model_id:
    raise SystemExit(f"invalid OpenCode model id: {model}")
with open(src, encoding="utf-8") as f:
    data = json.load(f)
providers = data.get("provider")
if not isinstance(providers, dict) or provider not in providers:
    raise SystemExit(f"provider not found in OpenCode config: {provider}")
options = providers[provider].setdefault("options", {})
options["baseURL"] = base_url
if route_model:
    headers = options.setdefault("headers", {})
    headers["x-model"] = route_model
data["model"] = model
data["small_model"] = model
with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  export OPENCODE_CONFIG_PATH="${TMP_CONFIG}"
}

prepare_direct_config
echo "running OpenCode prewarm (${MODEL})..."
if have timeout; then
  timeout "${SLOPCODE_PREWARM_TIMEOUT:-600}" opencode run --model "${MODEL}" --dir "${PREWARM_DIR}" "${PROMPT}" >/tmp/slopcode-opencode-prewarm.log 2>&1
else
  opencode run --model "${MODEL}" --dir "${PREWARM_DIR}" "${PROMPT}" >/tmp/slopcode-opencode-prewarm.log 2>&1
fi

echo "saving slot ${SLOT_ID} to ${SLOT_SAVE_PATH}/${SLOT_FILE}..."
RESP="$(curl -fsS \
  --connect-timeout 2 \
  --max-time "${SLOPCODE_SLOT_SAVE_TIMEOUT:-120}" \
  "${BASE_URL}/slots/${SLOT_ID}?action=save" \
  -H "content-type: application/json" \
  -d "{\"filename\":\"${SLOT_FILE}\"}")"
[[ "${RESP}" == *'"n_saved"'* ]] || die "slot save returned unexpected response: ${RESP}"

python3 - "${MANIFEST}" "${CURRENT_FINGERPRINT}" "${OPENCODE_VERSION}" "${LLAMA_VERSION}" "${WATCH_PATHS}" "${MODEL}" "${BASE_URL}" "${SLOT_FILE}" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, fingerprint, opencode_version, llama_version, watch_paths, model, base_url, slot_file = sys.argv[1:]
data = {
    "fingerprint": fingerprint,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "opencode_version": opencode_version,
    "llama_version": llama_version,
    "model": model,
    "base_url": base_url,
    "slot_file": slot_file,
    "watch_paths": [p for p in watch_paths.split(":") if p],
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

echo "prewarm cache saved: ${SLOT_SAVE_PATH}/${SLOT_FILE}"
