#!/usr/bin/env bash
# Install the slopcode-infra llama.cpp user service on Linux.
#
# Writes ~/.config/systemd/user/slopcode-llamacpp.service, enables and starts
# it, and (if polkit permits) enables loginctl linger so it survives logout
# and starts at boot. No root required in the common path; if the distro
# denies self-linger, the script prints the one-time sudo command.
#
# Idempotent: re-run after editing scripts/server_start_llamacpp.sh to pick
# up launcher changes. The unit simply invokes the launcher with
# LLAMACPP_EXEC=true, so launcher updates (flags, threads, port, -np, ...)
# propagate on the next `systemctl --user restart slopcode-llamacpp`.
#
# Env overrides (mostly for tests):
#   INSTALL_DRY_RUN   true to write the unit into UNIT_DIR and stop — skips
#                     systemctl / loginctl / curl probe.
#   UNIT_DIR          target dir for the unit file (default
#                     ~/.config/systemd/user).
#   SERVICE_NAME      unit name without .service (default slopcode-llamacpp).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
case "${PLATFORM}" in
  linux|wsl) ;;
  *) die "install_linux_systemd.sh is Linux-only (got ${PLATFORM}); macOS uses scripts/install_mac_launchagents.sh" ;;
esac

DRY_RUN="${INSTALL_DRY_RUN:-false}"
SERVICE_NAME="${SERVICE_NAME:-slopcode-llamacpp}"
UNIT_DIR="${UNIT_DIR:-${HOME}/.config/systemd/user}"
UNIT_FILE="${UNIT_DIR}/${SERVICE_NAME}.service"

if [[ "${DRY_RUN}" != "true" ]]; then
  have systemctl || die "systemctl not found (non-systemd distro?)"
  have loginctl  || die "loginctl not found"

  # Boot out the previous user units (devstral-named, qwenstack) so the new
  # slopcode-llamacpp service doesn't race a stale ExecStart on the same port.
  for legacy in devstral-llamacpp qwenstack-llamacpp; do
    [[ "${legacy}" == "${SERVICE_NAME}" ]] && continue
    if systemctl --user list-unit-files "${legacy}.service" 2>/dev/null | grep -q "${legacy}.service"; then
      echo "removing legacy user unit ${legacy}.service"
      systemctl --user disable --now "${legacy}.service" 2>/dev/null || true
      rm -f "${UNIT_DIR}/${legacy}.service"
    fi
  done

  # Refuse to install alongside a root-owned unit of the same name; removing
  # root units is out of scope for an
  # unprivileged installer and would silently fight this one over port 8080.
  root_units="$(systemctl list-unit-files --full --no-pager 2>/dev/null \
    | awk '/^(slopcode-llamacpp|devstral-llamacpp|qwenstack-llamacpp)\.service /{print $1}')"
  if [[ -n "${root_units}" ]]; then
    die "system-wide llama.cpp unit(s) present: ${root_units//$'\n'/ }
remove first (one-time sudo), then re-run this installer:
  sudo systemctl disable --now ${root_units//$'\n'/ } || true
  sudo rm -f $(printf '/etc/systemd/system/%s ' ${root_units})
  sudo systemctl daemon-reload"
  fi
fi

# Make sure the launcher will succeed when systemd runs it.
MODELS_SCRIPT="${SCRIPT_DIR}/llamacpp_models.py"
DEFAULT_ALIAS="$(python3 "${MODELS_SCRIPT}" default-alias)"
if [[ "${DRY_RUN}" != "true" ]]; then
  [[ -x "${LLAMACPP_HOME}/llama-server" ]] || have llama-server \
    || die "llama-server not installed. Run: scripts/setup_llamacpp.sh"
  MODEL_PATH="$(python3 "${MODELS_SCRIPT}" resolve "${DEFAULT_ALIAS}" 2>/dev/null || true)"
  [[ -n "${MODEL_PATH}" && -f "${MODEL_PATH}" ]] \
    || die "model ${DEFAULT_ALIAS} not prefetched. Run: scripts/llamacpp_models.py prefetch"
fi

mkdir -p "${UNIT_DIR}" "${RUN_DIR}"

cat > "${UNIT_FILE}" <<UNIT
[Unit]
Description=llama.cpp inference server (slopcode-infra, ${DEFAULT_ALIAS})
After=network.target

[Service]
Type=simple
Environment=LLAMACPP_EXEC=true
Environment=LLAMACPP_SMOKE_TEST=false
ExecStart=${SCRIPT_DIR}/server_start_llamacpp.sh
Restart=on-failure
RestartSec=5
StandardOutput=append:${RUN_DIR}/llamacpp.log
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

echo "waiting for /v1/models on :8080..."
deadline=$(( $(date +%s) + 180 ))
while : ; do
  if curl -fsS "http://127.0.0.1:8080/v1/models" >/dev/null 2>&1; then
    break
  fi
  if [[ $(date +%s) -ge ${deadline} ]]; then
    systemctl --user status --no-pager "${SERVICE_NAME}.service" | head -30 >&2 || true
    die "timed out waiting for llama-server on :8080"
  fi
  sleep 2
done
echo "service: http://127.0.0.1:8080/v1 (up)"
