#!/usr/bin/env bash
# Raise the macOS GPU wired-memory limit (iogpu.wired_limit_mb) and make it
# survive reboots via a LaunchDaemon. This is the "VRAM fraction" tweak: by
# default macOS caps how much unified memory the GPU/Metal (and thus
# llama.cpp/MLX) may wire, well below physical RAM. A 256 GB Mac Studio serving
# half of GLM-5.2 needs ~228 GB wired; the default cap is far too low.
#
# On a 256 GB host we raise it to 253952 MiB (248 GiB), leaving ~8 GiB for
# macOS. This is the one part of the stack that needs root: it writes
# /Library/LaunchDaemons/com.slopcode.iogpu-wired-limit.plist (RunAtLoad), which
# re-applies the sysctl at every boot, and applies it immediately so no reboot
# is required. faepmac1 already runs this; install it the same way on faepmac2.
#
# Usage:
#   scripts/install_mac_wired_limit.sh           # 253952 MiB (248 GiB)
#   scripts/install_mac_wired_limit.sh 245760    # explicit MiB
#   WIRED_LIMIT_MB=253952 scripts/install_mac_wired_limit.sh
#
# Verify afterwards: sysctl iogpu.wired_limit_mb
#
# Env:
#   WIRED_LIMIT_DRY_RUN  true to print the plist + planned commands and exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "wired-limit tuning is macOS-only"

LABEL="com.slopcode.iogpu-wired-limit"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LIMIT_MB="${1:-${WIRED_LIMIT_MB:-253952}}"
[[ "${LIMIT_MB}" =~ ^[0-9]+$ ]] || die "wired limit must be an integer in MiB, got '${LIMIT_MB}'"

# Guard: never wire more than physical RAM minus a 4 GiB floor for macOS.
TOTAL_GB="$(detect_total_ram_gb)"
if [[ "${TOTAL_GB}" -gt 0 ]]; then
  MAX_MB=$(( (TOTAL_GB - 4) * 1024 ))
  [[ "${LIMIT_MB}" -le "${MAX_MB}" ]] \
    || die "requested ${LIMIT_MB} MiB exceeds safe max ${MAX_MB} MiB for a ${TOTAL_GB} GiB host"
fi

echo "installing ${LABEL}: iogpu.wired_limit_mb=${LIMIT_MB} (${TOTAL_GB} GiB host)"

TMP="$(mktemp /tmp/iogpu-wired-limit.XXXXXX.plist)"
cat > "${TMP}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/sbin/sysctl</string>
    <string>iogpu.wired_limit_mb=${LIMIT_MB}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST

if [[ "${WIRED_LIMIT_DRY_RUN:-false}" == "true" ]]; then
  echo "--- ${PLIST} ---"
  cat "${TMP}"
  echo "--- commands ---"
  echo "install -o root -g wheel -m 0644 <plist> ${PLIST}"
  echo "launchctl bootout system ${PLIST}"
  echo "launchctl bootstrap system ${PLIST}"
  echo "sysctl iogpu.wired_limit_mb=${LIMIT_MB}"
  rm -f "${TMP}"
  exit 0
fi

sudo install -o root -g wheel -m 0644 "${TMP}" "${PLIST}"
rm -f "${TMP}"

# Re-bootstrap so a changed limit takes effect; bootout first if already loaded.
sudo launchctl bootout system "${PLIST}" 2>/dev/null || true
sudo launchctl bootstrap system "${PLIST}"
# Apply now so no reboot is needed.
sudo sysctl "iogpu.wired_limit_mb=${LIMIT_MB}" >/dev/null

echo "- plist:   ${PLIST}"
echo "- active:  $(sysctl -n iogpu.wired_limit_mb) MiB"
echo "done. Re-applies automatically at every boot."
