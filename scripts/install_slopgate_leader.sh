#!/usr/bin/env bash
# Install the slopgate balancer + a co-located agent on a leader node.
#
# Reads ~/.config/slopgate/leader.env (copy from
# config/slopgate/leader.env.example and fill in). Writes:
#   Linux: ~/.config/systemd/user/slopgate-{balancer,agent}.service
#   macOS: ~/Library/LaunchAgents/com.slopcode.slopgate-{balancer,agent}.plist
# and links ~/.local/bin/slopgate to the cargo build at
# $CODE/sloppy/slopgate/target/release/slopgate (override with SLOPGATE_BIN).
#
# No sudo required. systemd lingering is enabled where polkit allows, so the
# services survive logout and start at boot.
#
# Env overrides (mostly tests):
#   INSTALL_DRY_RUN   true to write units only and skip systemctl/launchctl
#   UNIT_DIR          systemd unit dir (default ~/.config/systemd/user)
#   AGENTS_DIR        launchd agents dir (default ~/Library/LaunchAgents)
#   SLOPGATE_BIN      explicit slopgate binary path
#   SLOPGATE_ENV_FILE explicit env file (default ~/.config/slopgate/leader.env)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
DRY_RUN="${INSTALL_DRY_RUN:-false}"
ENV_FILE="${SLOPGATE_ENV_FILE:-${HOME}/.config/slopgate/leader.env}"
EXAMPLE_ENV="${REPO_ROOT}/config/slopgate/leader.env.example"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-${HOME}/.local/bin}"
SLOPGATE_BIN="${SLOPGATE_BIN:-}"
SLOPGATE_BUILD_DIR_DEFAULT="${HOME}/code/sloppy/slopgate"
SLOPGATE_BUILD_DIR="${SLOPGATE_BUILD_DIR:-${SLOPGATE_BUILD_DIR_DEFAULT}}"

if [[ ! -f "${ENV_FILE}" ]]; then
  die "missing ${ENV_FILE}
copy the template and fill in your values:
  mkdir -p $(dirname "${ENV_FILE}")
  cp ${EXAMPLE_ENV} ${ENV_FILE}
  \$EDITOR ${ENV_FILE}"
fi

# Pull values out of the env file so we can decide which optional flags to
# emit. The unit/plist still references ${VAR} so updates to the file flow
# through without re-running the installer (Linux/systemd) or take effect on
# the next launchctl bootstrap (macOS).
set -o allexport
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +o allexport

canonicalize_path() {
  python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"
}

resolve_slopgate_bin() {
  local candidate=""
  if [[ -n "${SLOPGATE_BIN}" && -x "${SLOPGATE_BIN}" ]]; then
    candidate="${SLOPGATE_BIN}"
  elif [[ -x "${SLOPGATE_BUILD_DIR}/target/release/slopgate" ]]; then
    candidate="${SLOPGATE_BUILD_DIR}/target/release/slopgate"
  elif have slopgate; then
    candidate="$(command -v slopgate)"
  fi
  if [[ -z "${candidate}" ]]; then
    die "slopgate binary not found.
build it first:
  cd ${SLOPGATE_BUILD_DIR} && cargo build --release
or pass SLOPGATE_BIN=/path/to/slopgate"
  fi
  canonicalize_path "${candidate}"
}

if [[ "${DRY_RUN}" != "true" ]]; then
  SLOPGATE_BIN="$(resolve_slopgate_bin)"
  mkdir -p "${LOCAL_BIN_DIR}"
  if [[ "${SLOPGATE_BIN}" != "${LOCAL_BIN_DIR}/slopgate" ]]; then
    ln -sf "${SLOPGATE_BIN}" "${LOCAL_BIN_DIR}/slopgate"
  fi
  EXEC_BIN="${LOCAL_BIN_DIR}/slopgate"
else
  EXEC_BIN="${SLOPGATE_BIN:-${LOCAL_BIN_DIR}/slopgate}"
fi

case "${PLATFORM}" in
  linux|wsl)
    UNIT_DIR="${UNIT_DIR:-${HOME}/.config/systemd/user}"
    mkdir -p "${UNIT_DIR}" "${RUN_DIR}"

    BALANCER_UNIT="${UNIT_DIR}/slopgate-balancer.service"
    AGENT_UNIT="${UNIT_DIR}/slopgate-agent.service"

    {
      cat <<UNIT
[Unit]
Description=slopgate balancer (slot-aware reverse proxy for llama.cpp)
After=network.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${EXEC_BIN} balancer \\
  --management-addr \${SLOPGATE_MANAGEMENT_ADDR} \\
  --management-dashboard-enable \\
  --reverseproxy-addr \${SLOPGATE_REVERSEPROXY_ADDR}
Restart=on-failure
RestartSec=5
StandardOutput=append:${RUN_DIR}/slopgate-balancer.log
StandardError=inherit

[Install]
WantedBy=default.target
UNIT
    } > "${BALANCER_UNIT}"

    {
      cat <<UNIT
[Unit]
Description=slopgate agent (registers local llama-server with the balancer)
After=network.target slopgate-balancer.service

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${EXEC_BIN} agent \\
  --management-addr \${SLOPGATE_MANAGEMENT_ADDR} \\
  --external-llamacpp-addr \${SLOPGATE_LOCAL_LLAMACPP_ADDR} \\
  --local-llamacpp-addr \${SLOPGATE_LOCAL_LLAMACPP_ADDR} \\
  --max-context \${SLOPGATE_LOCAL_MAX_CONTEXT} \\
  --model-alias \${SLOPGATE_LOCAL_MODEL_ALIAS} \\
  --name \${SLOPGATE_LOCAL_AGENT_NAME}
Restart=on-failure
RestartSec=5
StandardOutput=append:${RUN_DIR}/slopgate-agent.log
StandardError=inherit

[Install]
WantedBy=default.target
UNIT
    } > "${AGENT_UNIT}"

    echo "wrote: ${BALANCER_UNIT}"
    echo "wrote: ${AGENT_UNIT}"

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "INSTALL_DRY_RUN=true; skipping systemctl/loginctl."
      exit 0
    fi

    have systemctl || die "systemctl not found"
    systemctl --user daemon-reload
    systemctl --user enable slopgate-balancer.service
    systemctl --user enable slopgate-agent.service
    systemctl --user restart slopgate-balancer.service
    systemctl --user restart slopgate-agent.service

    if loginctl enable-linger "${USER}" >/dev/null 2>&1; then
      echo "linger:  enabled for ${USER} (services start at boot)"
    else
      echo "linger:  not enabled (polkit denied self-linger). One-time fix:"
      echo "         sudo loginctl enable-linger ${USER}"
    fi
    ;;

  mac)
    AGENTS_DIR="${AGENTS_DIR:-${HOME}/Library/LaunchAgents}"
    mkdir -p "${AGENTS_DIR}" "${RUN_DIR}"

    BALANCER_LABEL=com.slopcode.slopgate-balancer
    AGENT_LABEL=com.slopcode.slopgate-agent
    BALANCER_PLIST="${AGENTS_DIR}/${BALANCER_LABEL}.plist"
    AGENT_PLIST="${AGENTS_DIR}/${AGENT_LABEL}.plist"

    cat > "${BALANCER_PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${BALANCER_LABEL}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LimitLoadToSessionType</key><string>Background</string>
  <key>ProgramArguments</key>
  <array>
    <string>${EXEC_BIN}</string>
    <string>balancer</string>
    <string>--management-addr</string><string>${SLOPGATE_MANAGEMENT_ADDR}</string>
    <string>--management-dashboard-enable</string>
    <string>--reverseproxy-addr</string><string>${SLOPGATE_REVERSEPROXY_ADDR}</string>
  </array>
  <key>StandardOutPath</key><string>${RUN_DIR}/slopgate-balancer.log</string>
  <key>StandardErrorPath</key><string>${RUN_DIR}/slopgate-balancer.log</string>
</dict>
</plist>
XML

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
  <key>LimitLoadToSessionType</key><string>Background</string>
  <key>ProgramArguments</key>
  <array>
    <string>${EXEC_BIN}</string>
    <string>agent</string>
    <string>--management-addr</string><string>${SLOPGATE_MANAGEMENT_ADDR}</string>
    <string>--external-llamacpp-addr</string><string>${SLOPGATE_LOCAL_LLAMACPP_ADDR}</string>
    <string>--local-llamacpp-addr</string><string>${SLOPGATE_LOCAL_LLAMACPP_ADDR}</string>
    <string>--max-context</string><string>${SLOPGATE_LOCAL_MAX_CONTEXT}</string>
    <string>--model-alias</string><string>${SLOPGATE_LOCAL_MODEL_ALIAS}</string>
    <string>--name</string><string>${SLOPGATE_LOCAL_AGENT_NAME}</string>
  </array>
  <key>StandardOutPath</key><string>${RUN_DIR}/slopgate-agent.log</string>
  <key>StandardErrorPath</key><string>${RUN_DIR}/slopgate-agent.log</string>
</dict>
</plist>
XML

    echo "wrote: ${BALANCER_PLIST}"
    echo "wrote: ${AGENT_PLIST}"

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "INSTALL_DRY_RUN=true; skipping launchctl bootstrap."
      exit 0
    fi

    for label in "${BALANCER_LABEL}" "${AGENT_LABEL}"; do
      launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
      launchctl bootout "user/$(id -u)/${label}" 2>/dev/null || true
    done
    launchctl bootstrap "user/$(id -u)" "${BALANCER_PLIST}"
    launchctl bootstrap "user/$(id -u)" "${AGENT_PLIST}"
    launchctl enable "user/$(id -u)/${BALANCER_LABEL}" 2>/dev/null || true
    launchctl enable "user/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
    launchctl kickstart -k "user/$(id -u)/${BALANCER_LABEL}"
    launchctl kickstart -k "user/$(id -u)/${AGENT_LABEL}"
    echo "loaded ${BALANCER_LABEL} + ${AGENT_LABEL}"
    ;;

  *)
    die "install_slopgate_leader.sh does not support ${PLATFORM} yet"
    ;;
esac

echo "slopgate leader installed."
echo "balancer reverse-proxy:  ${SLOPGATE_REVERSEPROXY_ADDR:-(see env file)}"
echo "balancer management:     ${SLOPGATE_MANAGEMENT_ADDR:-(see env file)}"
echo "remember to run scripts/server_start_llamacpp.sh (or restart its service)"
echo "so llama-server flips to the loopback port that the proxy expects."
