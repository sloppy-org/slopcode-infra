#!/usr/bin/env bash
# Install the macOS launchd agents for the MLX exclusive-big-model host:
#   com.slopcode.mlx                -> mlx_lm.server on 127.0.0.1:8090
#   com.slopcode.slopgate-agent-mlx -> static-slot (--slots 1) agent that
#                                      fronts the MLX server to the balancer
#
# The slopgate balancer keeps :8080/:8085 and every follower is untouched: the
# MLX server is just another peer, fronted as a static single-slot agent (the
# same path that fronts the OpenAI-compatible academic-ai / duck.ai daemons),
# so no slopgate code or balancer change is needed.
#
# Additive by default. With MLX_EXCLUSIVE=true it also boots out this host's
# llama.cpp servers and their qwen slopgate agents so the Mac serves only the
# one big MLX model. The balancer, whisper, and searxng agents are left alone.
#
# Env overrides:
#   MLX_ALIAS         registry alias to serve (default: mlx_models default)
#   MLX_PORT          mlx_lm.server port (default 8090)
#   MLX_AGENT_NAME    slopgate agent display name (default leader-mlx)
#   MLX_PROVIDER      slopgate provider slug (default faepmac1)
#   MLX_EXCLUSIVE     true to tear down local llama.cpp + qwen agents (the
#                     cutover). Default false (install MLX alongside).
#   SLOPGATE_ENV_FILE leader env for management addr + machine profile
#                     (default ~/.config/slopgate/leader.env)
#   INSTALL_DRY_RUN   true to write plists only, skip launchctl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "install_mac_mlx_launchagent.sh is macOS only"

MODELS_SCRIPT="${SCRIPT_DIR}/mlx_models.py"
AGENTS_DIR="${AGENTS_DIR:-${HOME}/Library/LaunchAgents}"
DRY_RUN="${INSTALL_DRY_RUN:-false}"
MLX_VENV="${MLX_VENV:-${HOME}/.venvs/mlx-lm}"
MLX_PORT="${MLX_PORT:-8090}"
MLX_AGENT_NAME="${MLX_AGENT_NAME:-leader-mlx}"
MLX_PROVIDER="${MLX_PROVIDER:-faepmac1}"
MLX_EXCLUSIVE="${MLX_EXCLUSIVE:-false}"
SLOPGATE_REQUEST_TIMEOUT="${SLOPGATE_LLAMACPP_REQUEST_TIMEOUT:-600}"
mkdir -p "${AGENTS_DIR}" "${RUN_DIR}"

SLOPGATE_BIN="${SLOPGATE_BIN:-${HOME}/.local/bin/slopgate}"
[[ -x "${SLOPGATE_BIN}" ]] || die "slopgate binary not found at ${SLOPGATE_BIN}"

ALIAS="${MLX_ALIAS:-$(python3 "${MODELS_SCRIPT}" default-alias)}"

# Pull the agent identity for this alias from the registry.
eval "$(python3 "${MODELS_SCRIPT}" agent-env "${ALIAS}")"

# Management addr + machine profile come from the leader env so the MLX agent
# registers against the same balancer with the same calibration profile.
ENV_FILE="${SLOPGATE_ENV_FILE:-${HOME}/.config/slopgate/leader.env}"
MANAGEMENT_ADDR="127.0.0.1:8085"
MACHINE_PROFILE="mac-studio-m3-ultra-256g"
if [[ -f "${ENV_FILE}" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +o allexport
  MANAGEMENT_ADDR="${SLOPGATE_MANAGEMENT_ADDR:-${MANAGEMENT_ADDR}}"
  MACHINE_PROFILE="${SLOPGATE_LOCAL_MACHINE_PROFILE:-${MACHINE_PROFILE}}"
fi

LAUNCH_PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:${HOME}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SERVER_LABEL="com.slopcode.mlx"
AGENT_LABEL="com.slopcode.slopgate-agent-mlx"
SERVER_PLIST="${AGENTS_DIR}/${SERVER_LABEL}.plist"
AGENT_PLIST="${AGENTS_DIR}/${AGENT_LABEL}.plist"

cat > "${SERVER_PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${SERVER_LABEL}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_DIR}/server_start_mlx.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MLX_EXEC</key><string>true</string>
    <key>MLX_VENV</key><string>${MLX_VENV}</string>
    <key>MLX_MODEL_ALIAS</key><string>${ALIAS}</string>
    <key>MLX_PORT</key><string>${MLX_PORT}</string>
    <key>PATH</key><string>${LAUNCH_PATH}</string>
  </dict>
  <key>StandardOutPath</key><string>${RUN_DIR}/mlx.log</string>
  <key>StandardErrorPath</key><string>${RUN_DIR}/mlx.log</string>
</dict>
</plist>
XML
echo "wrote: ${SERVER_PLIST}"

cat > "${AGENT_PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${AGENT_LABEL}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SLOPGATE_BIN}</string>
    <string>agent</string>
    <string>--management-addr</string><string>${MANAGEMENT_ADDR}</string>
    <string>--external-llamacpp-addr</string><string>127.0.0.1:${MLX_PORT}</string>
    <string>--local-llamacpp-addr</string><string>127.0.0.1:${MLX_PORT}</string>
    <string>--slots</string><string>1</string>
    <string>--llamacpp-request-timeout</string><string>${SLOPGATE_REQUEST_TIMEOUT}</string>
    <string>--max-context</string><string>${SLOPGATE_MAX_CONTEXT}</string>
    <string>--model-alias</string><string>${SLOPGATE_MODEL_ALIAS}</string>
    <string>--canonical-model</string><string>${SLOPGATE_CANONICAL_MODEL}</string>
    <string>--model-aliases</string><string>${SLOPGATE_MODEL_ALIASES}</string>
    <string>--upstream-model</string><string>${SLOPGATE_UPSTREAM_MODEL}</string>
    <string>--machine-profile</string><string>${MACHINE_PROFILE}</string>
    <string>--quant</string><string>${SLOPGATE_QUANT}</string>
    <string>--privacy-level</string><string>local</string>
    <string>--provider</string><string>${MLX_PROVIDER}</string>
    <string>--name</string><string>${MLX_AGENT_NAME}</string>
  </array>
  <key>StandardOutPath</key><string>${RUN_DIR}/slopgate-agent-mlx.log</string>
  <key>StandardErrorPath</key><string>${RUN_DIR}/slopgate-agent-mlx.log</string>
</dict>
</plist>
XML
echo "wrote: ${AGENT_PLIST}"
echo "MLX peer: alias ${SLOPGATE_MODEL_ALIAS} (${SLOPGATE_CANONICAL_MODEL}), quant ${SLOPGATE_QUANT}, 1 slot -> 127.0.0.1:${MLX_PORT}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "INSTALL_DRY_RUN=true; skipping launchctl."
  [[ "${MLX_EXCLUSIVE}" == "true" ]] && echo "(MLX_EXCLUSIVE=true would boot out local llama.cpp + qwen agents)"
  exit 0
fi

bootout() {
  local label="$1"
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
}

# Cutover: tear down this host's llama.cpp servers and their qwen agents so the
# Mac serves only the MLX model. Balancer / whisper / searxng stay up. Remote
# followers (faepmac2) keep serving qwen independently until separately retired.
if [[ "${MLX_EXCLUSIVE}" == "true" ]]; then
  echo "MLX_EXCLUSIVE=true: tearing down local llama.cpp + qwen slopgate agents"
  for label in \
    com.slopcode.slopgate-agent com.slopcode.slopgate-agent-27b \
    com.slopcode.slopgate-agent-122b com.slopcode.slopgate-agent-fim \
    com.slopcode.llamacpp com.slopcode.llamacpp-27b \
    com.slopcode.llamacpp-122b com.slopcode.llamacpp-fim; do
    bootout "${label}"
    rm -f "${AGENTS_DIR}/${label}.plist"
    echo "booted out ${label}"
  done
fi

for label in "${SERVER_LABEL}" "${AGENT_LABEL}"; do
  bootout "${label}"
done
launchctl bootstrap "gui/$(id -u)" "${SERVER_PLIST}"
launchctl enable "gui/$(id -u)/${SERVER_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${AGENT_PLIST}"
launchctl enable "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
echo "loaded ${SERVER_LABEL} + ${AGENT_LABEL}"
echo "watch model load:  tail -f ${RUN_DIR}/mlx.log"
echo "verify peer:       curl -s http://127.0.0.1:8085/api/v1/agents | python3 -m json.tool"
