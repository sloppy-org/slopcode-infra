#!/usr/bin/env bash
# Install Pi Coding Agent cleanly through npm and configure it for llama.cpp.
#
# Developer-only convenience. Pi is installed through the system npm only;
# do not bundle Node, Pi packages, or offline npm caches.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "error: $*" >&2; exit 1; }

have node || die "node is required. Install with Homebrew on macOS: brew install node"
have npm || die "npm is required. Install with Homebrew on macOS: brew install node"

node -e '
const [major, minor] = process.versions.node.split(".").map(Number);
if (major < 20 || (major === 20 && minor < 6)) process.exit(1);
' || die "Pi requires Node.js >= 20.6.0"

PACKAGE="${PI_PACKAGE:-@mariozechner/pi-coding-agent}"
VERSION="${PI_VERSION:-latest}"
SPEC="${PACKAGE}@${VERSION}"

echo "installing Pi Coding Agent: ${SPEC}"
PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1 npm install -g "${SPEC}"

bash "${SCRIPT_DIR}/pi_privacy.sh"
bash "${SCRIPT_DIR}/pi_set_llamacpp.sh"

echo "OK - Pi installed"
PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1 pi --version
