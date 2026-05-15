#!/usr/bin/env bash
# Set up the read-only NFS share at /Volumes/AI on a macOS host.
# Idempotent: safe to re-run. Requires sudo and FDA on the sshd binary
# if you intend to run this remotely (see docs/ai-share.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXPORTS_TEMPLATE="${REPO_ROOT}/config/ai-share/exports.template"
VOLUME_NAME="${AI_SHARE_VOLUME_NAME:-AI}"
MOUNT_POINT="/Volumes/${VOLUME_NAME}"
CONTAINER="${AI_SHARE_CONTAINER:-disk3}"

die() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
[[ -r "${EXPORTS_TEMPLATE}" ]]   || die "missing template: ${EXPORTS_TEMPLATE}"

if [[ ! -d "${MOUNT_POINT}" ]]; then
  echo "creating APFS volume ${VOLUME_NAME} in container ${CONTAINER}"
  sudo diskutil apfs addVolume "${CONTAINER}" APFS "${VOLUME_NAME}"
else
  echo "volume ${MOUNT_POINT} already present"
fi

sudo chown "$(id -un):admin" "${MOUNT_POINT}"
sudo chmod 2775 "${MOUNT_POINT}"

echo "writing /etc/exports"
sudo install -m 0644 -o root -g wheel "${EXPORTS_TEMPLATE}" /etc/exports

echo "validating exports"
sudo nfsd checkexports

echo "enabling nfsd"
sudo nfsd enable
sudo nfsd start
sleep 2
sudo nfsd status
showmount -e localhost
