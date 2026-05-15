#!/usr/bin/env bash
# Mount the AI share read-only at /Volumes/AI on a macOS client (e.g. faepmac2).
# Uses autofs so the mount comes back after reboot without a login script.
set -euo pipefail

SERVER="${AI_SHARE_SERVER:-faepmac1.tugraz.at}"
REMOTE_PATH="${AI_SHARE_REMOTE:-/Volumes/AI}"
MOUNT_POINT="${AI_SHARE_MOUNT:-/Volumes/AI}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS only"; exit 1; }

if [[ -d "${MOUNT_POINT}" ]] && mount | grep -q " on ${MOUNT_POINT} "; then
  echo "${MOUNT_POINT} already mounted"
  mount | grep " on ${MOUNT_POINT} "
  exit 0
fi

AUTO_FILE="/etc/auto_ai_share"
sudo tee "${AUTO_FILE}" >/dev/null <<EOF
# slopcode AI share - managed by install_mac_ai_client.sh
${MOUNT_POINT} -fstype=nfs,nfsv4,ro,nobrowse,noowners ${SERVER}:${REMOTE_PATH}
EOF

if ! grep -q "${AUTO_FILE}" /etc/auto_master; then
  sudo tee -a /etc/auto_master >/dev/null <<EOF
/-              ${AUTO_FILE}
EOF
fi

sudo automount -vc
ls "${MOUNT_POINT}/" >/dev/null && echo "mounted: ${MOUNT_POINT}"
mount | grep " on ${MOUNT_POINT} "
