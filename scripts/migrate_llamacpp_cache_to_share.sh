#!/usr/bin/env bash
# Move the per-user llama.cpp cache onto /Volumes/AI and replace the original
# path with a symlink so existing launchagents/services keep working unchanged.
# Idempotent: re-running after the swap is a no-op.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

SHARE_ROOT="${AI_SHARE_ROOT:-/Volumes/AI}"
SHARE_CACHE="${SHARE_ROOT}/llama.cpp"

case "$(uname -s)" in
  Darwin) USER_CACHE="${HOME}/Library/Caches/llama.cpp" ;;
  *)      USER_CACHE="${HOME}/.cache/llama.cpp" ;;
esac

[[ -d "${SHARE_ROOT}" ]] || die "${SHARE_ROOT} not mounted"

if [[ -L "${USER_CACHE}" ]]; then
  echo "${USER_CACHE} is already a symlink -> $(readlink "${USER_CACHE}")"
  exit 0
fi

mkdir -p "${SHARE_CACHE}"

if [[ -d "${USER_CACHE}" ]]; then
  echo "rsync ${USER_CACHE}/ -> ${SHARE_CACHE}/"
  rsync -aH --info=progress2 "${USER_CACHE}/" "${SHARE_CACHE}/"
  BACKUP="${USER_CACHE}.preshare.$(date +%Y%m%d-%H%M%S)"
  echo "renaming original to ${BACKUP}"
  mv "${USER_CACHE}" "${BACKUP}"
fi

ln -s "${SHARE_CACHE}" "${USER_CACHE}"
echo "symlink: ${USER_CACHE} -> ${SHARE_CACHE}"
echo "verify with: ls ${USER_CACHE}/"
