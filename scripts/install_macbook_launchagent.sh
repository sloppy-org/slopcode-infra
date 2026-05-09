#!/usr/bin/env bash
# Single-instance launchd agent for MacBooks with limited unified memory.
#
# Runs the blessed 35B-A3B Q4 (MoE) model on port 8080 with:
#   -c 131072 -np 1 (single slot, 128K context)
#   Q8_0 KV cache, flash attention, Metal (all layers on GPU)
#   No thread pinning (Metal schedules on its own)
#
# Intended for Macs with ~32 GB unified memory where the dual-instance deployment
# (server_start_mac.sh / install_mac_launchagents.sh) does not fit.
# The big-Mac scripts are untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "install_macbook_launchagent.sh is macOS only"

MODELS_SCRIPT="${SCRIPT_DIR}/llamacpp_models.py"
AGENTS_DIR="${HOME}/Library/LaunchAgents"
mkdir -p "${AGENTS_DIR}" "${RUN_DIR}"

DEFAULT_MODEL_ALIAS="$(python3 "${MODELS_SCRIPT}" default-alias)"
MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-${DEFAULT_MODEL_ALIAS}}"
if ! model_path="$(python3 "${MODELS_SCRIPT}" resolve "${MODEL_ALIAS}" 2>/dev/null)" \
  || [[ -z "${model_path}" || ! -f "${model_path}" ]]; then
  if [[ -n "${LLAMACPP_MODEL_ALIAS:-}" ]]; then
    die "model alias ${MODEL_ALIAS} not on disk. Run: python3 ${MODELS_SCRIPT} prefetch ${MODEL_ALIAS}"
  fi
  MODEL_ALIAS="qwen3.6-35b-a3b-bartowski-q4"
  model_path="$(python3 "${MODELS_SCRIPT}" resolve "${MODEL_ALIAS}" 2>/dev/null || true)"
fi
[[ -n "${model_path}" && -f "${model_path}" ]] \
  || die "35B-A3B model not on disk. Run: python3 ${MODELS_SCRIPT} prefetch"

SERVER_BIN="${LLAMACPP_SERVER_BIN:-}"
if [[ -z "${SERVER_BIN}" ]]; then
  if ! SERVER_BIN="$(resolve_llamacpp_server_bin)"; then
    die "llama-server not found. Run scripts/setup_llamacpp.sh or set LLAMACPP_SERVER_BIN"
  fi
fi
[[ -x "${SERVER_BIN}" ]] || die "not executable: ${SERVER_BIN}"
SERVER_DIR="$(cd "$(dirname "${SERVER_BIN}")" && pwd)"
REASONING_BUDGET="${LLAMACPP_REASONING_BUDGET:-$(default_reasoning_budget)}"

LABEL="com.slopcode.llamacpp-macbook"
PLIST="${AGENTS_DIR}/${LABEL}.plist"
LOG="${RUN_DIR}/llamacpp.log"

# Boot out any previous agent under this label (or the legacy single label).
wait_gone() {
  local label="$1" deadline=$(( $(date +%s) + 10 ))
  while launchctl list | awk '{print $3}' | grep -qx "${label}"; do
    [[ $(date +%s) -ge ${deadline} ]] && return 1
    sleep 1
  done
  return 0
}

for old_label in "${LABEL}" \
                 com.devstral.llamacpp-local \
                 com.devstral.llamacpp-35b-a3b \
                 com.devstral.llamacpp-27b \
                 com.devstral.llamacpp-macbook \
                 com.slopcode.llamacpp-local \
                 com.slopcode.llamacpp-35b-a3b \
                 com.slopcode.llamacpp-27b; do
  old_plist="${AGENTS_DIR}/${old_label}.plist"
  if launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "${old_label}"; then
    echo "unloading ${old_label}"
    launchctl bootout "gui/$(id -u)/${old_label}" 2>/dev/null \
      || launchctl unload "${old_plist}" 2>/dev/null || true
    wait_gone "${old_label}" || die "failed to unload existing ${old_label}"
  fi
  rm -f "${old_plist}"
done

# Also stop any nohup instance sitting on port 8080.
stop_llamacpp_port_occupants 8080 "existing instance"

# Resolve the launcher script's absolute path.
LAUNCHER="${SCRIPT_DIR}/server_start_llamacpp.sh"
[[ -f "${LAUNCHER}" ]] || die "launcher not found: ${LAUNCHER}"

cat > "${PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${LAUNCHER}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>LLAMACPP_EXEC</key><string>true</string>
    <key>LLAMACPP_MODEL_ALIAS</key><string>${MODEL_ALIAS}</string>
    <key>LLAMACPP_SERVED_ALIAS</key><string>qwen</string>
    <key>LLAMACPP_PORT</key><string>8080</string>
    <key>LLAMACPP_HOST</key><string>0.0.0.0</string>
    <key>LLAMACPP_CONTEXT</key><string>131072</string>
    <key>LLAMACPP_PARALLEL</key><string>1</string>
    <key>LLAMACPP_BATCH</key><string>2048</string>
    <key>LLAMACPP_UBATCH</key><string>1024</string>
    <key>LLAMACPP_REASONING_BUDGET</key><string>${REASONING_BUDGET}</string>
    <key>DYLD_LIBRARY_PATH</key><string>${SERVER_DIR}</string>
    <key>PATH</key><string>${SERVER_DIR}:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin</string>
  </dict>
  <key>StandardOutPath</key><string>${LOG}</string>
  <key>StandardErrorPath</key><string>${LOG}</string>
</dict>
</plist>
XML

launchctl bootstrap "gui/$(id -u)" "${PLIST}"
echo "loaded ${LABEL} (35B-A3B Q4 on :8080, alias qwen, model ${MODEL_ALIAS})"

echo
echo "waiting for /v1/models (up to 900s)..."
deadline=$(( $(date +%s) + 900 ))
while : ; do
  if curl -fsS "http://127.0.0.1:8080/v1/models" >/dev/null 2>&1; then
    echo "ready: http://127.0.0.1:8080/v1"
    exit 0
  fi
  [[ $(date +%s) -ge ${deadline} ]] && die "timed out waiting for llama-server"
  sleep 2
done
