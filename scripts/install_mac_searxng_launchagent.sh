#!/usr/bin/env bash
# Install a macOS launchd background agent for local SearXNG.
#
# This uses the per-user GUI launchd domain. The service stays user-level,
# loopback-only, restartable on crash, and does not need admin rights.
#
# Env overrides:
#   AGENTS_DIR        launchd agents dir (default ~/Library/LaunchAgents)
#   SERVICE_LABEL     launchd label (default com.slopcode.searxng)
#   INSTALL_DRY_RUN   true to write the plist and stop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "install_mac_searxng_launchagent.sh is macOS only"

AGENTS_DIR="${AGENTS_DIR:-${HOME}/Library/LaunchAgents}"
SERVICE_LABEL="${SERVICE_LABEL:-com.slopcode.searxng}"
INSTALL_DRY_RUN="${INSTALL_DRY_RUN:-false}"
PLIST="${AGENTS_DIR}/${SERVICE_LABEL}.plist"
LOG_FILE="${RUN_DIR}/searxng.log"

mkdir -p "${AGENTS_DIR}" "${RUN_DIR}"

if [[ "${INSTALL_DRY_RUN}" != "true" ]]; then
  "${SCRIPT_DIR}/setup_searxng.sh"
fi

cat > "${PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${SERVICE_LABEL}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>WorkingDirectory</key><string>${REPO_ROOT}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_DIR}/server_start_searxng.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>SEARXNG_EXEC</key><string>true</string>
    <key>RUN_DIR</key><string>${RUN_DIR}</string>
    <key>LOG_DIR</key><string>${RUN_DIR}</string>
  </dict>
  <key>StandardOutPath</key><string>${LOG_FILE}</string>
  <key>StandardErrorPath</key><string>${LOG_FILE}</string>
</dict>
</plist>
XML

echo "wrote:   ${PLIST}"

if [[ "${INSTALL_DRY_RUN}" == "true" ]]; then
  echo "INSTALL_DRY_RUN=true; skipping launchctl/probe."
  exit 0
fi

launchctl bootout "gui/$(id -u)/${SERVICE_LABEL}" 2>/dev/null || true
launchctl bootout "user/$(id -u)/${SERVICE_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST}"
launchctl enable "gui/$(id -u)/${SERVICE_LABEL}" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/${SERVICE_LABEL}"

echo "waiting for SearXNG on :8888..."
deadline=$(( $(date +%s) + 180 ))
while : ; do
  if curl -fsS "http://127.0.0.1:8888/search?q=ready&format=json" >/dev/null 2>&1; then
    break
  fi
  if [[ $(date +%s) -ge ${deadline} ]]; then
    launchctl print "gui/$(id -u)/${SERVICE_LABEL}" | head -40 >&2 || true
    die "timed out waiting for searxng on :8888"
  fi
  sleep 2
done
echo "service: http://127.0.0.1:8888 (up)"
