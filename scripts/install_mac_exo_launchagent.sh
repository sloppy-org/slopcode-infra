#!/usr/bin/env bash
# Install a macOS LaunchAgent for an exo node (distributed MLX inference) so it
# comes up automatically and restarts on crash.
#
# exo MUST run as a LaunchAgent in the user's GUI session, NOT a system
# LaunchDaemon. exo discovers peers with IPv6 multicast, which macOS gates
# behind the per-app Local Network privacy permission. That permission only
# exists in a logged-in GUI session: a root daemon (or an SSH-spawned process)
# has no session to hold the grant, so macOS silently drops its outbound
# discovery announces and every node only ever sees itself. A LaunchAgent runs
# in the GUI session, so the grant applies.
#
# To still come up at boot with no manual login, enable automatic login (only
# possible with FileVault off). Then: boot -> auto-login -> agent starts exo ->
# Local Network grant applies -> the cluster forms.
#
# Two one-time actions per box (need the console / Screen Sharing, not SSH):
#   1. System Settings > Users & Groups > Automatically log in as <user>.
#   2. System Settings > Privacy & Security > Local Network: allow exo (python).
#
# Env:
#   EXO_DIR                    exo clone (default ~/exo)
#   EXO_API_PORT               API + discovery base port (default 52415)
#   EXO_MODELS_READ_ONLY_DIRS  pre-downloaded model root (default /Volumes/AI/mlx)
#   INSTALL_DRY_RUN            true to write the plist only, skip launchctl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "install_mac_exo_launchagent.sh is macOS only"

EXO_DIR="${EXO_DIR:-${HOME}/exo}"
EXO_BIN="${EXO_DIR}/.venv/bin/exo"
API_PORT="${EXO_API_PORT:-52415}"
RO_DIRS="${EXO_MODELS_READ_ONLY_DIRS:-/Volumes/AI/mlx}"
DRY_RUN="${INSTALL_DRY_RUN:-false}"
AGENTS_DIR="${AGENTS_DIR:-${HOME}/Library/LaunchAgents}"
LABEL="com.slopcode.exo"
PLIST="${AGENTS_DIR}/${LABEL}.plist"
LOG_DIR="${RUN_DIR}"
mkdir -p "${AGENTS_DIR}" "${LOG_DIR}"

[[ -x "${EXO_BIN}" ]] || die "exo not found at ${EXO_BIN}; run scripts/setup_exo.sh first"

cat > "${PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${EXO_BIN}</string>
    <string>--api-port</string><string>${API_PORT}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>${HOME}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>EXO_MODELS_READ_ONLY_DIRS</key><string>${RO_DIRS}</string>
  </dict>
  <key>WorkingDirectory</key><string>${EXO_DIR}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>${LOG_DIR}/exo.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/exo.log</string>
</dict>
</plist>
PLIST
echo "wrote ${PLIST}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "(dry-run) skipping launchctl bootstrap"
  exit 0
fi

GUI="gui/$(id -u)"
launchctl bootout "${GUI}/${LABEL}" 2>/dev/null || true
if launchctl bootstrap "${GUI}" "${PLIST}" 2>/dev/null; then
  launchctl enable "${GUI}/${LABEL}" 2>/dev/null || true
  echo "loaded ${LABEL} into ${GUI}"
else
  warn "could not bootstrap into ${GUI} now (no active GUI session over SSH)."
  warn "the plist is installed; it loads on the next GUI login / auto-login."
fi

echo
echo "One-time on this box (console or Screen Sharing, not SSH):"
echo "  1. System Settings > Users & Groups > Automatically log in as <you> (FileVault must be off)."
echo "  2. System Settings > Privacy & Security > Local Network: allow exo (python)."
