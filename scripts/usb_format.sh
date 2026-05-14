#!/usr/bin/env bash
# Format a USB stick as exFAT and create an empty slopcode bundle skeleton.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

DEV="${1:-}"
LABEL="${2:-SLOPCODE}"
[[ -n "${DEV}" ]] || die "usage: $0 /dev/sdX [LABEL]"
[[ -b "${DEV}" ]] || die "not a block device: ${DEV}"

case "${DEV}" in
  /dev/sda|/dev/sda[0-9]*|/dev/nvme0*|/dev/mmcblk0*) die "refusing system-looking disk: ${DEV}" ;;
esac

have mkfs.exfat || die "mkfs.exfat missing; install exfatprogs"
have sudo || die "sudo required"
have lsblk || die "lsblk required"

lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINT "${DEV}" || true
echo "This will erase ${DEV} and format it as exFAT (${LABEL})."
printf 'type "YES ERASE %s" to confirm: ' "${DEV}"
read -r reply
[[ "${reply}" == "YES ERASE ${DEV}" ]] || die "aborted"

while read -r mp; do
  [[ -n "${mp}" ]] && sudo umount "${mp}" 2>/dev/null || true
done < <(lsblk -no MOUNTPOINT "${DEV}")

sudo wipefs -a "${DEV}"
sudo mkfs.exfat -n "${LABEL}" "${DEV}"

mnt="$(mktemp -d)"
sudo mount -o "uid=$(id -u),gid=$(id -g),umask=022" "${DEV}" "${mnt}"
mkdir -p "${mnt}/models" "${mnt}/linux-cuda" "${mnt}/mac-m1" "${mnt}/windows-arc"
cat >"${mnt}/README.txt" <<'EOF'
Empty slopcode USB skeleton. Populate it with:
  scripts/build_bundle.sh all --out <this-directory>
EOF
sudo umount "${mnt}"
rmdir "${mnt}"

echo "formatted ${DEV} as exFAT (${LABEL})"
