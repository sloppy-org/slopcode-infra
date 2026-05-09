#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

bash -n "${REPO_ROOT}/scripts/setup_searxng.sh"
bash -n "${REPO_ROOT}/scripts/server_start_searxng.sh"
bash -n "${REPO_ROOT}/scripts/install_linux_searxng_systemd.sh"
bash -n "${REPO_ROOT}/scripts/install_mac_searxng_launchagent.sh"

if command -v pwsh >/dev/null 2>&1; then
  SCRIPTS_DIR="${REPO_ROOT}/scripts" pwsh -NoProfile -Command '
      $tokens=$null
      $errs=$null
      [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $env:SCRIPTS_DIR "install_searxng_windows.ps1"), [ref]$tokens, [ref]$errs) > $null
      if ($errs.Count) {
        Write-Error ($errs | Out-String)
        exit 1
      }
    '
fi
