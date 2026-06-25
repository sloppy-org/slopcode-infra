#!/usr/bin/env bash
# Provision a Mac as an exo node (github.com/exo-explore/exo) for distributed
# MLX inference across two Mac Studios. exo wraps a pinned mlx-lm fork over mlx;
# this installs the prereqs, clones exo, builds the dashboard the README marks
# required, and primes the uv environment. Run on each node.
#
# Over plain Ethernet (no Thunderbolt-5 cable) exo needs no network config: its
# MLX layer falls back to the Ring (TCP) backend and discovers peers via mDNS on
# the same subnet. RDMA is opt-in (TB5 + macOS 26.2 + a Recovery `rdma_ctl
# enable`) and is not set up here.
#
# Two prereqs are NOT scriptable and must be done once on the machine's console:
#   - Xcode / Metal toolchain. exo lists it; Command Line Tools alone may lack
#     `xcrun metal`. Prebuilt mlx wheels often run without it, so this script
#     warns rather than fails. Install full Xcode (GUI) if mlx then fails.
#   - System Settings > Privacy & Security > Local Network: allow the terminal
#     app, or mDNS peer discovery silently fails (exo issue #952).
#
# Env:
#   EXO_DIR            clone location (default ~/exo)
#   EXO_SETUP_DRY_RUN  true to print planned steps and exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "exo setup targets Apple silicon Macs"

EXO_DIR="${EXO_DIR:-${HOME}/exo}"
DRY="${EXO_SETUP_DRY_RUN:-false}"

run() { echo "+ $*"; [[ "${DRY}" == "true" ]] || "$@"; }

# 1. Metal toolchain: warn only (mlx wheels usually run without `xcrun metal`).
if ! xcrun -f metal >/dev/null 2>&1; then
  warn "no Metal compiler (xcrun metal). exo lists Xcode/Metal toolchain as a prereq;"
  warn "  if mlx fails to run on this host, install full Xcode from the App Store."
fi

# 2. Prereqs via Homebrew (native package manager; no curl|sh).
have brew || die "Homebrew not found or not on PATH. exo needs uv, node, and rust."
for pkg in uv node rustup; do
  if ! brew list "${pkg}" >/dev/null 2>&1; then run brew install "${pkg}"; fi
done
# Homebrew's rustup formula is keg-only and ships no rustup-init, so its bin is
# not symlinked onto PATH; add it before bootstrapping the nightly toolchain.
export PATH="$(brew --prefix rustup 2>/dev/null)/bin:${HOME}/.cargo/bin:${PATH}"
run rustup toolchain install nightly

# 3. Clone or update exo.
if [[ -d "${EXO_DIR}/.git" ]]; then
  run git -C "${EXO_DIR}" pull --ff-only
else
  run git clone https://github.com/exo-explore/exo "${EXO_DIR}"
fi

# 4. Dashboard build (README marks this required before running exo).
run bash -c "cd '${EXO_DIR}/dashboard' && npm install && npm run build"

# 5. Python env + MLX backend. mlx is an OPTIONAL extra (exo[mlx]); a plain
#    `uv sync` installs only exo core, so the backend must be requested. Pin
#    Python to 3.13, where exo's other deps have wheels.
#
#    KNOWN BLOCKER (2026-06): exo pins mlx==0.32.0, which has no PyPI wheel for
#    macOS arm64 (cp312 or cp313). uv falls back to the sdist, whose Metal
#    kernels fail to compile under Xcode 26.5 (hadamard / gather_axis /
#    reduce_utils, cmake Error 2). Until exo bumps its mlx pin to a wheel-having
#    release, the backend does not install on a current-Xcode host: exo core
#    installs, inference does not. See docs/exo-cluster.md.
run bash -c "cd '${EXO_DIR}' && uv venv --python 3.13 && uv sync --extra mlx"

echo
echo "exo node provisioned at ${EXO_DIR}."
echo "Launch with scripts/server_start_exo.sh (run it on BOTH nodes)."
echo "Grant Local Network permission on this host or mDNS discovery will fail."
