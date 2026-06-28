#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/_common.sh"

FAILED=0
is_mac() { [[ "$(uname -s)" == "Darwin" ]]; }

bash -n "${REPO_ROOT}/scripts/setup_exo.sh"          || { echo "FAIL: setup_exo.sh syntax"; exit 1; }
bash -n "${REPO_ROOT}/scripts/server_start_exo.sh"   || { echo "FAIL: server_start_exo.sh syntax"; exit 1; }
bash -n "${REPO_ROOT}/scripts/bench_mlx_llamacpp.sh" || { echo "FAIL: bench_mlx_llamacpp.sh syntax"; exit 1; }
bash -n "${REPO_ROOT}/scripts/provision_exo_peer.sh"  || { echo "FAIL: provision_exo_peer.sh syntax"; exit 1; }
bash -n "${REPO_ROOT}/scripts/install_mac_exo_launchagent.sh" || { echo "FAIL: install_mac_exo_launchagent.sh syntax"; exit 1; }
bash -n "${REPO_ROOT}/scripts/exo_glm_instance.sh"    || { echo "FAIL: exo_glm_instance.sh syntax"; exit 1; }
bash -n "${REPO_ROOT}/scripts/exo_repoint_mlx_lm.sh"  || { echo "FAIL: exo_repoint_mlx_lm.sh syntax"; exit 1; }

test_launchagent_dry() {
  echo "TEST: install_mac_exo_launchagent dry-run writes a GUI LaunchAgent plist"
  if ! is_mac; then echo "SKIP (macOS-only)"; return 0; fi
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "${tmp}/exo/.venv/bin"; printf '#!/bin/sh\n' > "${tmp}/exo/.venv/bin/exo"; chmod +x "${tmp}/exo/.venv/bin/exo"
  EXO_DIR="${tmp}/exo" AGENTS_DIR="${tmp}/agents" INSTALL_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/install_mac_exo_launchagent.sh" >/dev/null 2>&1 || true
  if grep -q 'com.slopcode.exo' "${tmp}/agents/com.slopcode.exo.plist" 2>/dev/null \
     && grep -q 'RunAtLoad' "${tmp}/agents/com.slopcode.exo.plist" 2>/dev/null; then
    echo "PASS"; rm -rf "${tmp}"
  else
    echo "FAIL"; rm -rf "${tmp}"; return 1
  fi
}

test_peer_dry() {
  echo "TEST: provision_exo_peer dry-run prints the transfer plan"
  if ! is_mac; then echo "SKIP (macOS-only)"; return 0; fi
  local out
  out="$(EXO_PEER_DRY_RUN=true bash "${REPO_ROOT}/scripts/provision_exo_peer.sh" peerhost 2>&1 || true)"
  if [[ "${out}" == *"provision exo peer peerhost"* && "${out}" == *"rsync"* ]]; then
    echo "PASS"
  else
    echo "FAIL"; echo "${out}"; return 1
  fi
}

test_bench_dry() {
  echo "TEST: bench_mlx_llamacpp dry-run names both engines"
  if ! is_mac; then echo "SKIP (macOS-only)"; return 0; fi
  local out
  out="$(BENCH_DRY_RUN=true bash "${REPO_ROOT}/scripts/bench_mlx_llamacpp.sh")"
  if [[ "${out}" == *"mlx_lm.generate"* && "${out}" == *"llama-bench"* ]]; then
    echo "PASS"
  else
    echo "FAIL"; echo "${out}"; return 1
  fi
}

test_start_dry() {
  echo "TEST: server_start_exo dry-run emits 'uv run exo' on :52415"
  if ! is_mac; then echo "SKIP (macOS-only)"; return 0; fi
  local out
  out="$(EXO_DIR=/tmp/exo-x EXO_DRY_RUN=true bash "${REPO_ROOT}/scripts/server_start_exo.sh")"
  if [[ "${out}" == *"uv run exo"* && "${out}" == *"52415"* ]]; then
    echo "PASS"
  else
    echo "FAIL"; echo "${out}"; return 1
  fi
}

test_setup_dry() {
  echo "TEST: setup_exo dry-run clones the exo fork and builds the dashboard"
  if ! is_mac; then echo "SKIP (macOS-only)"; return 0; fi
  local out
  out="$(EXO_DIR=/tmp/exo-x EXO_SETUP_DRY_RUN=true bash "${REPO_ROOT}/scripts/setup_exo.sh" 2>&1 || true)"
  if [[ "${out}" == *"git clone git@github.com:krystophny/exo"* && "${out}" == *"npm run build"* ]]; then
    echo "PASS"
  else
    echo "FAIL"; echo "${out}"; return 1
  fi
}

test_start_dry  || FAILED=$((FAILED + 1))
test_setup_dry  || FAILED=$((FAILED + 1))
test_bench_dry  || FAILED=$((FAILED + 1))
test_peer_dry   || FAILED=$((FAILED + 1))
test_launchagent_dry || FAILED=$((FAILED + 1))

if [[ "${FAILED}" -gt 0 ]]; then echo "${FAILED} test(s) failed"; exit 1; fi
echo "all exo profile tests passed"
