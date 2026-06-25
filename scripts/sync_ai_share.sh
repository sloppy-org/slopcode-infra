#!/usr/bin/env bash
# Bidirectional rsync of /Volumes/AI between faepmac1 and faepmac2.
# No --delete: either box may add models, neither may remove via sync.
# Manual: run after dropping a new GGUF on either host.
set -euo pipefail

LOCAL_ROOT="${AI_SHARE_ROOT:-/Volumes/AI}"
PEER="${AI_SHARE_PEER:-}"

if [[ -z "${PEER}" ]]; then
  case "$(hostname -s)" in
    faepmac1) PEER="faepmac2" ;;
    faepmac2) PEER="faepmac1" ;;
    *) echo "error: set AI_SHARE_PEER (hostname $(hostname -s) is neither faepmac1 nor faepmac2)" >&2; exit 1 ;;
  esac
fi

[[ -d "${LOCAL_ROOT}" ]] || { echo "error: ${LOCAL_ROOT} not present locally" >&2; exit 1; }

ssh "${PEER}" "test -d ${LOCAL_ROOT}" || {
  echo "error: ${PEER}:${LOCAL_ROOT} not present" >&2; exit 1
}

# macOS ships openrsync (no --info=progress2 / --inplace). Keep flags to
# the openrsync intersection so the script works without Homebrew rsync.
# Exclude per-volume macOS metadata (.Spotlight-V100 etc.) — those are
# locally regenerated and their root-owned perms break utimensat.
RSYNC_OPTS=(-aH --partial --progress --stats
  --exclude='/.Spotlight-V100'
  --exclude='/.fseventsd'
  --exclude='/.Trashes'
  --exclude='/.DocumentRevisions-V100'
  --exclude='/.TemporaryItems'
  --exclude='/.DS_Store')

echo "==> push ${LOCAL_ROOT}/ -> ${PEER}:${LOCAL_ROOT}/"
rsync "${RSYNC_OPTS[@]}" "${LOCAL_ROOT}/" "${PEER}:${LOCAL_ROOT}/"

echo "==> pull ${PEER}:${LOCAL_ROOT}/ -> ${LOCAL_ROOT}/"
rsync "${RSYNC_OPTS[@]}" "${PEER}:${LOCAL_ROOT}/" "${LOCAL_ROOT}/"

echo "done"
