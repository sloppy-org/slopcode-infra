#!/usr/bin/env bash
# Install OpenCode CLI.
#
# Online default: `curl https://opencode.ai/install | bash`.
# Offline: point OPENCODE_OFFLINE_ARCHIVE at a local opencode tarball/zip;
# the script unpacks it into ~/.opencode instead of hitting the network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"

if [[ -n "${OPENCODE_OFFLINE_ARCHIVE:-}" ]]; then
  archive="${OPENCODE_OFFLINE_ARCHIVE}"
  [[ -f "${archive}" ]] || die "offline archive not found: ${archive}"
  dest="${HOME}/.opencode"
  mkdir -p "${dest}/bin"
  echo "installing OpenCode from ${archive} into ${dest}"
  case "${archive}" in
    *.zip) unzip -q -o "${archive}" -d "${dest}" ;;
    *.tar.gz|*.tgz) tar -xzf "${archive}" -C "${dest}" ;;
    *.tar.xz) tar -xJf "${archive}" -C "${dest}" ;;
    *) die "unknown archive format: ${archive}" ;;
  esac
  # Some release tarballs ship opencode at the top-level, some nest it.
  if [[ ! -x "${dest}/bin/opencode" ]]; then
    found="$(find "${dest}" -type f -name 'opencode' -print -quit || true)"
    [[ -n "${found}" ]] || die "opencode binary not found in archive"
    cp "${found}" "${dest}/bin/opencode"
    chmod +x "${dest}/bin/opencode"
  fi
else
  case "${PLATFORM}" in
    mac|linux|wsl) curl -fsSL https://opencode.ai/install | bash ;;
    windows) die "use the Windows opencode release archive on this platform" ;;
    *) die "unsupported platform: ${PLATFORM}" ;;
  esac
fi

if have opencode; then
  echo "OK - opencode installed"
  opencode --version 2>/dev/null || true
else
  echo "opencode installed under ~/.opencode/bin; add it to PATH:"
  # shellcheck disable=SC2016
  echo '  export PATH="$HOME/.opencode/bin:$PATH"'
fi

echo ""
echo "next: scripts/opencode_set_llamacpp.sh"
