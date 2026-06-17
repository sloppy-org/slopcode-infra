#!/usr/bin/env bash
# Install the slopgate EDGE agent on this host. Reads
# ~/.config/slopgate/edge.env (copy from config/slopgate/edge.env.example and
# fill in). Writes ~/.config/systemd/user/slopgate-agent-edge.service and
# links ~/.local/bin/slopgate to the Go build at
# $CODE/sloppy/slopgate/go/bin/slopgate (override with SLOPGATE_BIN).
#
# The edge agent registers the local llama-server with a separate edge
# balancer's management endpoint over WireGuard, tagged with a privacy tier
# (local for our own hardware). It is independent of the leader cluster: it
# never points at the leader. Run it alongside, not instead of, the
# leader-follower agent if a host serves both roles.
#
# Linux/systemd-user only: the local-tier peer is the Linux GPU host. No
# balancer is installed here.
#
# Env overrides:
#   INSTALL_DRY_RUN   true to write the unit only and skip systemctl/loginctl
#   UNIT_DIR          systemd unit dir (default ~/.config/systemd/user)
#   SLOPGATE_BIN      explicit slopgate binary path
#   SLOPGATE_ENV_FILE explicit env file (default ~/.config/slopgate/edge.env)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
case "${PLATFORM}" in
  linux|wsl) ;;
  *) die "install_slopgate_edge.sh supports linux only (got ${PLATFORM})" ;;
esac

DRY_RUN="${INSTALL_DRY_RUN:-false}"
ENV_FILE="${SLOPGATE_ENV_FILE:-${HOME}/.config/slopgate/edge.env}"
EXAMPLE_ENV="${REPO_ROOT}/config/slopgate/edge.env.example"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-${HOME}/.local/bin}"
SLOPGATE_BIN="${SLOPGATE_BIN:-}"
SLOPGATE_BUILD_DIR="${SLOPGATE_BUILD_DIR:-${HOME}/code/sloppy/slopgate}"

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

SLOPGATE_LLAMACPP_REQUEST_TIMEOUT="${SLOPGATE_LLAMACPP_REQUEST_TIMEOUT:-120}"
: "${SLOPGATE_PRIVACY_LEVEL:?set SLOPGATE_PRIVACY_LEVEL in ${ENV_FILE} (e.g. local)}"
: "${SLOPGATE_EDGE_MANAGEMENT_ADDR:?set SLOPGATE_EDGE_MANAGEMENT_ADDR in ${ENV_FILE}}"

resolve_slopgate_bin() {
  local candidate=""
  if [[ -n "${SLOPGATE_BIN}" && -x "${SLOPGATE_BIN}" ]]; then
    candidate="${SLOPGATE_BIN}"
  elif [[ -x "${SLOPGATE_BUILD_DIR}/go/bin/slopgate" ]]; then
    candidate="${SLOPGATE_BUILD_DIR}/go/bin/slopgate"
  elif have slopgate; then
    candidate="$(command -v slopgate)"
  fi
  [[ -n "${candidate}" ]] || die "slopgate binary not found.
build it first:
  cd ${SLOPGATE_BUILD_DIR} && make build
or pass SLOPGATE_BIN=/path/to/slopgate"
  python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${candidate}"
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

UNIT_DIR="${UNIT_DIR:-${HOME}/.config/systemd/user}"
mkdir -p "${UNIT_DIR}" "${RUN_DIR}"
AGENT_UNIT="${UNIT_DIR}/slopgate-agent-edge.service"

{
  cat <<UNIT
[Unit]
Description=slopgate agent (registers local llama-server with the edge balancer)
After=network.target slopcode-llamacpp.service
Wants=slopcode-llamacpp.service

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${EXEC_BIN} agent \\
  --management-addr \${SLOPGATE_EDGE_MANAGEMENT_ADDR} \\
  --external-llamacpp-addr \${SLOPGATE_EXTERNAL_LLAMACPP_ADDR} \\
  --local-llamacpp-addr \${SLOPGATE_LOCAL_LLAMACPP_ADDR} \\
  --llamacpp-request-timeout ${SLOPGATE_LLAMACPP_REQUEST_TIMEOUT} \\
  --max-context \${SLOPGATE_MAX_CONTEXT} \\
  --privacy-level \${SLOPGATE_PRIVACY_LEVEL} \\
  --model-alias \${SLOPGATE_MODEL_ALIAS} \\
  --canonical-model \${SLOPGATE_CANONICAL_MODEL} \\
  --model-aliases \${SLOPGATE_MODEL_ALIASES} \\
  --machine-profile \${SLOPGATE_MACHINE_PROFILE} \\
  --digest-extra \${SLOPGATE_DIGEST_EXTRA} \\
  --quant \${SLOPGATE_QUANT} \\
  --name \${SLOPGATE_AGENT_NAME}
Restart=on-failure
RestartSec=5
StandardOutput=append:${RUN_DIR}/slopgate-agent-edge.log
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
systemctl --user enable slopgate-agent-edge.service
systemctl --user restart slopgate-agent-edge.service

if loginctl enable-linger "${USER}" >/dev/null 2>&1; then
  echo "linger:  enabled for ${USER} (agent starts at boot)"
else
  echo "linger:  not enabled (polkit denied self-linger). One-time fix:"
  echo "         sudo loginctl enable-linger ${USER}"
fi

echo "slopgate edge agent installed."
echo "registers with edge management addr: ${SLOPGATE_EDGE_MANAGEMENT_ADDR}"
echo "privacy tier: ${SLOPGATE_PRIVACY_LEVEL}"
