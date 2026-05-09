#!/usr/bin/env bash
# Install a user-level systemd service for local SearXNG on Linux.
#
# The service binds only 127.0.0.1:8888, restarts on failure, and attempts to
# enable linger so it survives logout and boot without root in the common case.
#
# Env overrides:
#   INSTALL_DRY_RUN   true to write the unit and stop
#   UNIT_DIR          unit directory (default ~/.config/systemd/user)
#   SERVICE_NAME      systemd unit basename (default slopcode-searxng)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
case "${PLATFORM}" in
  linux|wsl) ;;
  *) die "install_linux_searxng_systemd.sh is Linux-only (got ${PLATFORM})" ;;
esac

DRY_RUN="${INSTALL_DRY_RUN:-false}"
SERVICE_NAME="${SERVICE_NAME:-slopcode-searxng}"
UNIT_DIR="${UNIT_DIR:-${HOME}/.config/systemd/user}"
UNIT_FILE="${UNIT_DIR}/${SERVICE_NAME}.service"

if [[ "${DRY_RUN}" != "true" ]]; then
  have systemctl || die "systemctl not found"
  have loginctl || die "loginctl not found"
  "${SCRIPT_DIR}/setup_searxng.sh"
fi

mkdir -p "${UNIT_DIR}" "${RUN_DIR}"

cat > "${UNIT_FILE}" <<UNIT
[Unit]
Description=SearXNG local web search (slopcode-infra)
After=network.target

[Service]
Type=simple
Environment=SEARXNG_EXEC=true
ExecStart=${SCRIPT_DIR}/server_start_searxng.sh
Restart=on-failure
RestartSec=5
StandardOutput=append:${RUN_DIR}/searxng.log
StandardError=append:${RUN_DIR}/searxng.log

[Install]
WantedBy=default.target
UNIT

echo "wrote:   ${UNIT_FILE}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "INSTALL_DRY_RUN=true; skipping systemctl/loginctl/probe."
  exit 0
fi

systemctl --user daemon-reload
systemctl --user enable "${SERVICE_NAME}.service"
systemctl --user restart "${SERVICE_NAME}.service"

if loginctl enable-linger "${USER}" >/dev/null 2>&1; then
  echo "linger:  enabled for ${USER} (service starts at boot)"
else
  cat <<LINGER
linger:  not enabled (polkit denied self-linger). The service will start at
         login but not at boot. One-time fix:
           sudo loginctl enable-linger ${USER}
LINGER
fi

echo "waiting for SearXNG on :8888..."
deadline=$(( $(date +%s) + 180 ))
while : ; do
  if curl -fsS "http://127.0.0.1:8888/search?q=ready&format=json" >/dev/null 2>&1; then
    break
  fi
  if [[ $(date +%s) -ge ${deadline} ]]; then
    systemctl --user status --no-pager "${SERVICE_NAME}.service" | head -30 >&2 || true
    die "timed out waiting for searxng on :8888"
  fi
  sleep 2
done
echo "service: http://127.0.0.1:8888 (up)"
