#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/_common.sh"

FAILED=0
is_mac() { [[ "$(uname -s)" == "Darwin" ]]; }

bash -n "${REPO_ROOT}/scripts/setup_exo.sh"        || { echo "FAIL: setup_exo.sh syntax"; exit 1; }
bash -n "${REPO_ROOT}/scripts/server_start_exo.sh" || { echo "FAIL: server_start_exo.sh syntax"; exit 1; }

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
  echo "TEST: setup_exo dry-run clones exo and builds the dashboard"
  if ! is_mac; then echo "SKIP (macOS-only)"; return 0; fi
  local out
  out="$(EXO_DIR=/tmp/exo-x EXO_SETUP_DRY_RUN=true bash "${REPO_ROOT}/scripts/setup_exo.sh" 2>&1 || true)"
  if [[ "${out}" == *"git clone https://github.com/exo-explore/exo"* && "${out}" == *"npm run build"* ]]; then
    echo "PASS"
  else
    echo "FAIL"; echo "${out}"; return 1
  fi
}

test_start_dry  || FAILED=$((FAILED + 1))
test_setup_dry  || FAILED=$((FAILED + 1))

if [[ "${FAILED}" -gt 0 ]]; then echo "${FAILED} test(s) failed"; exit 1; fi
echo "all exo profile tests passed"
