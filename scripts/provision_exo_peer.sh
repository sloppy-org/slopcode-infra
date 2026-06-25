#!/usr/bin/env bash
# Provision a SECOND exo node from this already-built primary, without
# installing Xcode or fixing Homebrew on the peer. mlx compiles only on the
# primary (the node that has the Metal toolchain); the peer receives the
# prebuilt wheel uv cached during that build. Requirements on both: Apple
# silicon, the same macOS major version, and Python 3.13 (cp313).
#
# Run on the primary:
#   scripts/provision_exo_peer.sh <peer-ssh-host>
#
# It copies the uv binary, the cached mlx + mlx_lm wheels, and the exo repo
# (minus .venv/.git), builds the peer venv with uv sync, and installs the
# wheels. Nodes on the same subnet then form a cluster on startup with no
# further config (no --bootstrap-peers needed on a LAN that passes multicast).
#
# Env:
#   EXO_DIR           exo clone on the primary (default ~/exo)
#   PEER_PYTHON       python 3.13 on the peer (default /opt/homebrew/bin/python3.13)
#   EXO_PEER_DRY_RUN  true to print the plan and exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "provision_exo_peer targets Apple silicon"

PEER="${1:-}"
[[ -n "${PEER}" ]] || die "usage: provision_exo_peer.sh <peer-ssh-host>"
EXO_DIR="${EXO_DIR:-${HOME}/exo}"
PEER_PY="${PEER_PYTHON:-/opt/homebrew/bin/python3.13}"
DRY="${EXO_PEER_DRY_RUN:-false}"

UV_BIN="$(command -v uv || true)"
[[ -n "${UV_BIN}" ]] || die "uv not found on this primary"
MLX_WHL="$(find "${HOME}/.cache/uv" -name 'mlx-0.32*cp313*macos*arm64.whl' 2>/dev/null | head -1)"
MLXLM_WHL="$(find "${HOME}/.cache/uv" -name 'mlx_lm-*py3-none-any.whl' 2>/dev/null | head -1)"

echo "provision exo peer ${PEER}"
echo "- uv:        ${UV_BIN}"
echo "- mlx wheel: ${MLX_WHL:-<not found>}"
echo "- exo dir:   ${EXO_DIR}"

if [[ "${DRY}" == "true" ]]; then
  echo "(dry-run) rsync uv + wheels + exo repo to ${PEER}, then uv venv/sync + uv pip install wheels"
  exit 0
fi

[[ -f "${MLX_WHL}" ]] || die "prebuilt mlx wheel not in uv cache; build exo here first (scripts/setup_exo.sh)"
[[ -f "${MLXLM_WHL}" ]] || die "mlx_lm wheel not in uv cache"
[[ -d "${EXO_DIR}" ]] || die "exo not found at ${EXO_DIR}"

ssh "${PEER}" 'mkdir -p ~/.local/bin ~/exo-wheels'
rsync -a "${UV_BIN}" "${PEER}:.local/bin/uv"
rsync -a "${MLX_WHL}" "${MLXLM_WHL}" "${PEER}:exo-wheels/"
rsync -aH --exclude='.venv' --exclude='.git' "${EXO_DIR}/" "${PEER}:exo/"

ssh "${PEER}" "bash -lc '
  cd ~/exo
  export PATH=\$HOME/.local/bin:\$PATH
  env -u VIRTUAL_ENV uv venv --python ${PEER_PY}
  env -u VIRTUAL_ENV uv sync
  env -u VIRTUAL_ENV uv pip install ~/exo-wheels/mlx-*.whl ~/exo-wheels/mlx_lm-*.whl
  ~/exo/.venv/bin/python -c \"import mlx.core, mlx_lm, exo; print(\\\"peer exo stack OK\\\")\"
'"

echo "peer ${PEER} provisioned. Start exo on both nodes; same-subnet discovery forms the cluster."
