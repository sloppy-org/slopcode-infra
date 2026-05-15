#!/usr/bin/env bash
# Mount the faepmac1 AI share read-only at /Volumes/AI on a Linux client.
# Uses NFSv4 over the ITP LAN; if the host is reachable only via WireGuard
# the same path resolves but transfers will be WG-limited.
set -euo pipefail

SERVER="${AI_SHARE_SERVER:-faepmac1.tugraz.at}"
REMOTE_PATH="${AI_SHARE_REMOTE:-/Volumes/AI}"
MOUNT_POINT="${AI_SHARE_MOUNT:-/Volumes/AI}"
UNIT_NAME="$(systemd-escape -p --suffix=mount "${MOUNT_POINT}")"

[[ "$(uname -s)" == "Linux" ]] || { echo "Linux only"; exit 1; }
[[ $EUID -eq 0 ]]              || { echo "run as root"; exit 1; }

command -v mount.nfs4 >/dev/null || {
  echo "installing nfs client"
  if   command -v apt-get >/dev/null; then apt-get update && apt-get install -y nfs-common
  elif command -v dnf     >/dev/null; then dnf install -y nfs-utils
  elif command -v pacman  >/dev/null; then pacman -S --noconfirm nfs-utils
  else echo "install nfs client manually"; exit 1
  fi
}

mkdir -p "${MOUNT_POINT}"

cat >"/etc/systemd/system/${UNIT_NAME}" <<EOF
[Unit]
Description=slopcode AI model share (read-only from ${SERVER})
After=network-online.target
Wants=network-online.target

[Mount]
What=${SERVER}:${REMOTE_PATH}
Where=${MOUNT_POINT}
Type=nfs4
Options=ro,nofail,soft,timeo=50,retrans=2,_netdev

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${UNIT_NAME}"
systemctl status --no-pager "${UNIT_NAME}" | head -10
findmnt "${MOUNT_POINT}"
