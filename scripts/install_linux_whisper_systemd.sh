#!/usr/bin/env bash
# Install the slopcode-infra whisper.cpp user service on Linux.
#
# Writes ~/.config/systemd/user/whisper-server.service, enables and starts
# it, and (if polkit permits) enables loginctl linger so it survives logout
# and starts at boot. No root required in the common path.
#
# The unit invokes scripts/server_start_whisper.sh with WHISPER_EXEC=true
# so whisper-server runs in the foreground under systemd. Re-run after
# editing the launcher (or after rebuilding whisper.cpp) to pick up
# changes — the unit only references the launcher path.
#
# This installer also evicts the AUR-shipped /etc/systemd/system/whisper-
# server.service if it gets in the way (refuses to clobber, prints the
# one-time sudo command), and any pre-existing user unit pointing at
# /usr/bin/whisper-server (the Arch package layout). The new unit lives
# under ~/.config/systemd/user and points at the locally-built binary.
#
# Env overrides:
#   INSTALL_DRY_RUN   true to write the unit into UNIT_DIR and stop —
#                     skips systemctl / loginctl / curl probe.
#   UNIT_DIR          target dir for the unit file (default
#                     ~/.config/systemd/user).
#   SERVICE_NAME      unit name without .service (default whisper-server).
#   WHISPER_HOST      bind host (default 127.0.0.1)
#   WHISPER_PORT      bind port (default 8427)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
case "${PLATFORM}" in
  linux|wsl) ;;
  *) die "install_linux_whisper_systemd.sh is Linux-only (got ${PLATFORM}); macOS uses scripts/install_mac_launchagents.sh" ;;
esac

DRY_RUN="${INSTALL_DRY_RUN:-false}"
SERVICE_NAME="${SERVICE_NAME:-whisper-server}"
UNIT_DIR="${UNIT_DIR:-${HOME}/.config/systemd/user}"
UNIT_FILE="${UNIT_DIR}/${SERVICE_NAME}.service"
WHISPER_HOST="${WHISPER_HOST:-127.0.0.1}"
WHISPER_PORT="${WHISPER_PORT:-8427}"

# Resolve the same default WHISPER_HOME server_start_whisper.sh uses, so
# the unit description and the readiness probe agree.
default_whisper_home() {
  if [[ -x "${HOME}/code/whisper.cpp/build/bin/whisper-server" ]]; then
    echo "${HOME}/code/whisper.cpp"
  elif [[ -x "${HOME}/.local/whisper.cpp/build/bin/whisper-server" ]]; then
    echo "${HOME}/.local/whisper.cpp"
  elif [[ -d "${HOME}/code" ]]; then
    echo "${HOME}/code/whisper.cpp"
  else
    echo "${HOME}/.local/whisper.cpp"
  fi
}
WHISPER_HOME="${WHISPER_HOME:-$(default_whisper_home)}"

if [[ "${DRY_RUN}" != "true" ]]; then
  have systemctl || die "systemctl not found (non-systemd distro?)"
  have loginctl  || die "loginctl not found"

  # Refuse to install alongside the AUR system unit — removing root units
  # is out of scope for an unprivileged installer and would silently fight
  # this one over port 8427.
  root_units="$(systemctl list-unit-files --full --no-pager 2>/dev/null \
    | awk '/^whisper-server\.service /{print $1}')"
  if [[ -n "${root_units}" ]]; then
    die "system-wide whisper-server unit present: ${root_units//$'\n'/ }
remove first (one-time sudo), then re-run this installer:
  sudo systemctl disable --now ${root_units//$'\n'/ } || true
  sudo rm -f /etc/systemd/system/whisper-server.service
  sudo systemctl daemon-reload
  sudo pacman -Rns whisper.cpp-cuda whisper.cpp-model-large-v3-turbo-q5_0 || true"
  fi

  # Stop a stale user unit pointing at /usr/bin/whisper-server (the Arch
  # package binary) before we overwrite it.
  if [[ -f "${UNIT_FILE}" ]] && grep -q '/usr/bin/whisper-server' "${UNIT_FILE}"; then
    echo "stopping legacy whisper-server.service (was pointing at /usr/bin)"
    systemctl --user stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl --user disable "${SERVICE_NAME}.service" 2>/dev/null || true
  fi

  # Make sure the launcher will succeed when systemd runs it.
  [[ -x "${WHISPER_HOME}/build/bin/whisper-server" ]] \
    || die "whisper-server not built under ${WHISPER_HOME}. Run: scripts/setup_whisper.sh"
  default_model="${WHISPER_HOME}/models/ggml-large-v3-turbo.bin"
  [[ -f "${default_model}" ]] \
    || die "whisper model missing: ${default_model}. Run: scripts/setup_whisper.sh"
fi

mkdir -p "${UNIT_DIR}" "${RUN_DIR}"

cat > "${UNIT_FILE}" <<UNIT
[Unit]
Description=whisper.cpp OpenAI-compatible STT server (slopcode-infra, ${WHISPER_HOME})
After=network.target

[Service]
Type=simple
Environment=WHISPER_EXEC=true
Environment=WHISPER_HOME=${WHISPER_HOME}
Environment=WHISPER_HOST=${WHISPER_HOST}
Environment=WHISPER_PORT=${WHISPER_PORT}
ExecStart=${SCRIPT_DIR}/server_start_whisper.sh
Restart=on-failure
RestartSec=2
StandardOutput=append:${RUN_DIR}/whisper-server.log
StandardError=inherit

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

probe_host="${WHISPER_HOST}"
[[ "${probe_host}" == "0.0.0.0" ]] && probe_host="127.0.0.1"
echo "waiting for ${probe_host}:${WHISPER_PORT}/ (timeout 120s)..."
deadline=$(( $(date +%s) + 120 ))
while : ; do
  if curl -fsS -m 2 "http://${probe_host}:${WHISPER_PORT}/" >/dev/null 2>&1; then
    echo "service: http://${probe_host}:${WHISPER_PORT}/"
    break
  fi
  if [[ $(date +%s) -ge ${deadline} ]]; then
    systemctl --user status --no-pager "${SERVICE_NAME}.service" | head -30 >&2 || true
    die "timed out waiting for whisper-server on :${WHISPER_PORT}"
  fi
  sleep 2
done
