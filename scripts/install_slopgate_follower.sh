#!/usr/bin/env bash
# Install the slopgate agent on a follower node. Reads
# ~/.config/slopgate/follower.env (copy from
# config/slopgate/follower.env.example and fill in). Writes:
#   Linux: ~/.config/systemd/user/slopgate-agent.service
#   macOS: ~/Library/LaunchAgents/com.slopcode.slopgate-agent.plist
# and links ~/.local/bin/slopgate to the cargo build at
# $CODE/sloppy/slopgate/target/release/slopgate (override with SLOPGATE_BIN).
#
# The agent registers the local llama-server with the leader's management
# endpoint over the user's private network (WireGuard/LAN). No balancer is
# installed here.
#
# Env overrides:
#   INSTALL_DRY_RUN   true to write units only and skip systemctl/launchctl
#   UNIT_DIR          systemd unit dir (default ~/.config/systemd/user)
#   AGENTS_DIR        launchd agents dir (default ~/Library/LaunchAgents)
#   SLOPGATE_BIN      explicit slopgate binary path
#   SLOPGATE_ENV_FILE explicit env file (default ~/.config/slopgate/follower.env)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
DRY_RUN="${INSTALL_DRY_RUN:-false}"
ENV_FILE="${SLOPGATE_ENV_FILE:-${HOME}/.config/slopgate/follower.env}"
EXAMPLE_ENV="${REPO_ROOT}/config/slopgate/follower.env.example"
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

    AGENT_UNIT="${UNIT_DIR}/slopgate-agent.service"

    {
      cat <<UNIT
[Unit]
Description=slopgate agent (registers local llama-server with the leader)
After=network.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${EXEC_BIN} agent \\
  --management-addr \${SLOPGATE_LEADER_MANAGEMENT_ADDR} \\
  --external-llamacpp-addr \${SLOPGATE_EXTERNAL_LLAMACPP_ADDR} \\
  --local-llamacpp-addr \${SLOPGATE_LOCAL_LLAMACPP_ADDR} \\
  --max-context \${SLOPGATE_MAX_CONTEXT} \\
  --model-alias \${SLOPGATE_MODEL_ALIAS} \\
  --name \${SLOPGATE_AGENT_NAME}
Restart=on-failure
RestartSec=5
StandardOutput=append:${RUN_DIR}/slopgate-agent.log
StandardError=inherit

[Install]
WantedBy=default.target
UNIT
    } > "${AGENT_UNIT}"

    echo "wrote: ${AGENT_UNIT}"

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "INSTALL_DRY_RUN=true; skipping systemctl/loginctl."
      exit 0
    fi

    have systemctl || die "systemctl not found"
    systemctl --user daemon-reload
    systemctl --user enable slopgate-agent.service
    systemctl --user restart slopgate-agent.service

    if loginctl enable-linger "${USER}" >/dev/null 2>&1; then
      echo "linger:  enabled for ${USER} (agent starts at boot)"
    else
      echo "linger:  not enabled (polkit denied self-linger). One-time fix:"
      echo "         sudo loginctl enable-linger ${USER}"
    fi
    ;;

  mac)
    AGENTS_DIR="${AGENTS_DIR:-${HOME}/Library/LaunchAgents}"
    mkdir -p "${AGENTS_DIR}" "${RUN_DIR}"

    AGENT_LABEL=com.slopcode.slopgate-agent
    AGENT_PLIST="${AGENTS_DIR}/${AGENT_LABEL}.plist"

    cat > "${AGENT_PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${AGENT_LABEL}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProgramArguments</key>
  <array>
    <string>${EXEC_BIN}</string>
    <string>agent</string>
    <string>--management-addr</string><string>${SLOPGATE_LEADER_MANAGEMENT_ADDR}</string>
    <string>--external-llamacpp-addr</string><string>${SLOPGATE_EXTERNAL_LLAMACPP_ADDR}</string>
    <string>--local-llamacpp-addr</string><string>${SLOPGATE_LOCAL_LLAMACPP_ADDR}</string>
    <string>--max-context</string><string>${SLOPGATE_MAX_CONTEXT}</string>
    <string>--model-alias</string><string>${SLOPGATE_MODEL_ALIAS}</string>
    <string>--name</string><string>${SLOPGATE_AGENT_NAME}</string>
  </array>
  <key>StandardOutPath</key><string>${RUN_DIR}/slopgate-agent.log</string>
  <key>StandardErrorPath</key><string>${RUN_DIR}/slopgate-agent.log</string>
</dict>
</plist>
XML

    echo "wrote: ${AGENT_PLIST}"

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "INSTALL_DRY_RUN=true; skipping launchctl bootstrap."
      exit 0
    fi

    launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "${AGENT_PLIST}"
    echo "loaded ${AGENT_LABEL}"
    ;;

  *)
    die "install_slopgate_follower.sh does not support ${PLATFORM} yet"
    ;;
esac

echo "slopgate follower installed."
echo "registers with leader management addr: ${SLOPGATE_LEADER_MANAGEMENT_ADDR:-(see env file)}"
echo "remember to start scripts/server_start_llamacpp.sh with"
echo "LLAMACPP_BIND_LOOPBACK=true (or via the slopcode-llamacpp service)."
