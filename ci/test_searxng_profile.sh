#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

bash -n "${REPO_ROOT}/scripts/setup_searxng.sh"
bash -n "${REPO_ROOT}/scripts/server_start_searxng.sh"
bash -n "${REPO_ROOT}/scripts/install_linux_searxng_systemd.sh"
bash -n "${REPO_ROOT}/scripts/install_mac_searxng_launchagent.sh"

grep -q "keep_only:" "${REPO_ROOT}/scripts/setup_searxng.sh"
grep -q "SearxEngineCaptcha: 21600" "${REPO_ROOT}/scripts/setup_searxng.sh"
grep -q "autocomplete: '\${SEARXNG_AUTOCOMPLETE}'" "${REPO_ROOT}/scripts/setup_searxng.sh"
grep -q "SEARXNG_AUTOCOMPLETE=\"\${SEARXNG_AUTOCOMPLETE:-}\"" "${REPO_ROOT}/scripts/setup_searxng.sh"
grep -q "keep_only:" "${REPO_ROOT}/scripts/install_searxng_windows.bat"
grep -q "SearxEngineCaptcha: 21600" "${REPO_ROOT}/scripts/install_searxng_windows.bat"
