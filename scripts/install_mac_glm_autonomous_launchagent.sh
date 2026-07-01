#!/usr/bin/env bash
# Install the idle-gated autonomous GLM worker as a macOS LaunchAgent on the
# exo leader (faepmac1). It fires on a StartInterval; each tick checks whether
# the cluster is idle (glm_idle.sh) and, if so, starts GLM and works the GitHub
# backlog (glm_autonomous.sh run). A single-instance lock means overlapping
# ticks are harmless.
#
# Reboot resilience: RunAtLoad brings the tick up at login, and with auto-login
# on both Macs the whole chain (boot -> auto-login -> exo LaunchAgent ->
# glm_service.sh start places GLM -> this tick works the backlog) reforms with
# no human present. A tick that runs before faepmac2 is back simply finds the
# cluster not-ready, aborts, and retries at the next interval. KeepAlive is
# false: this is a periodic tick, not a resident daemon.
#
# Env (injected into the agent when set at install time):
#   GLM_TICK_INTERVAL   seconds between ticks (default 300)
#   GLM_GROUPS          override the target GitHub groups/owners
#   IDLE_SECONDS        idle threshold before work starts (default 1800)
#   GLM_IDLE_SETTLE     extra sustained-idle seconds before acting (default 0)
#   INSTALL_DRY_RUN     true to write the plist only, skip launchctl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "install_mac_glm_autonomous_launchagent.sh is macOS only"

WORKER="${SCRIPT_DIR}/glm_autonomous.sh"
[[ -f "${WORKER}" ]] || die "worker not found at ${WORKER}"

INTERVAL="${GLM_TICK_INTERVAL:-300}"
DRY_RUN="${INSTALL_DRY_RUN:-false}"
AGENTS_DIR="${AGENTS_DIR:-${HOME}/Library/LaunchAgents}"
LABEL="com.slopcode.glm-autonomous"
PLIST="${AGENTS_DIR}/${LABEL}.plist"
LOG_DIR="${RUN_DIR}"
mkdir -p "${AGENTS_DIR}" "${LOG_DIR}"

# Optional env passed through to the worker, injected only when set at install.
ENV_BLOCK=""
add_env() {
  [[ -n "${2:-}" ]] || return 0
  ENV_BLOCK+="    <key>${1}</key><string>${2}</string>
"
}
add_env GLM_GROUPS "${GLM_GROUPS:-}"
add_env IDLE_SECONDS "${IDLE_SECONDS:-}"
add_env GLM_IDLE_SETTLE "${GLM_IDLE_SETTLE:-}"

cat > "${PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WORKER}</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>${HOME}/.local/bin:${HOME}/.opencode/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
${ENV_BLOCK}  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StartInterval</key><integer>${INTERVAL}</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>${LOG_DIR}/glm-autonomous.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/glm-autonomous.log</string>
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
