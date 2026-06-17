#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/_common.sh"

if [[ "$(detect_platform)" != "mac" ]]; then
  echo "SKIP: MLX profile test is macOS only"
  exit 0
fi

FAILED=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "  MISSING: ${label} (expected '${needle}')"
    echo "${haystack}" | sed 's/^/    | /'
    FAILED=1
  fi
}

# --- registry ---
test_registry() {
  echo "TEST: mlx_models.py registry"
  local default agent_env sampler
  default="$(python3 "${REPO_ROOT}/scripts/mlx_models.py" default-alias)"
  [[ "${default}" == "minimax-m3-mixed" ]] || { echo "  bad default: ${default}"; FAILED=1; }
  agent_env="$(python3 "${REPO_ROOT}/scripts/mlx_models.py" agent-env minimax-m3-mixed)"
  assert_contains "${agent_env}" "SLOPGATE_MODEL_ALIAS=minimax" "agent-env alias"
  assert_contains "${agent_env}" "SLOPGATE_CANONICAL_MODEL=minimaxai/minimax-m3@128k" "agent-env canonical"
  assert_contains "${agent_env}" "SLOPGATE_QUANT=MLX-mixed-3_6bit" "agent-env quant"
  assert_contains "${agent_env}" "SLOPGATE_UPSTREAM_MODEL=pipenetwork/MiniMax-M3-MLX-mixed-3_6bit" "agent-env upstream"
  sampler="$(python3 "${REPO_ROOT}/scripts/mlx_models.py" sampler deepseek-v4-flash)"
  assert_contains "${sampler}" "--temp 0.6" "deepseek sampler temp"
}

# --- launcher dry-run ---
test_launcher_dry_run() {
  echo "TEST: server_start_mlx.sh dry-run"
  local venv="${TMPDIR}/venv"
  mkdir -p "${venv}/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${venv}/bin/mlx_lm.server"
  chmod +x "${venv}/bin/mlx_lm.server"
  local port output
  port="$(free_port)"
  output="$(
    MLX_VENV="${venv}" \
    MLX_MODEL_ALIAS="minimax-m3-mixed" \
    MLX_MODEL_ARG="test/MiniMax-M3" \
    MLX_PORT="${port}" \
    MLX_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_mlx.sh"
  )"
  assert_contains "${output}" "--model test/MiniMax-M3" "model arg"
  assert_contains "${output}" "--prompt-concurrency 1" "single prompt slot"
  assert_contains "${output}" "--decode-concurrency 1" "single decode slot"
  assert_contains "${output}" "--trust-remote-code" "trust remote code"
  assert_contains "${output}" "--temp 1.0" "minimax sampler"
  assert_contains "${output}" "--port ${port}" "port"
}

# --- installer dry-run ---
test_installer_dry_run() {
  echo "TEST: install_mac_mlx_launchagent.sh dry-run"
  local agents="${TMPDIR}/LaunchAgents"
  local slopgate="${TMPDIR}/slopgate"
  mkdir -p "${agents}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${slopgate}"
  chmod +x "${slopgate}"
  local output
  output="$(
    AGENTS_DIR="${agents}" \
    SLOPGATE_BIN="${slopgate}" \
    SLOPGATE_ENV_FILE="${TMPDIR}/nonexistent.env" \
    MLX_ALIAS="minimax-m3-mixed" \
    INSTALL_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/install_mac_mlx_launchagent.sh"
  )"
  assert_contains "${output}" "INSTALL_DRY_RUN=true" "dry-run guard"
  [[ -f "${agents}/com.slopcode.mlx.plist" ]] || { echo "  MISSING server plist"; FAILED=1; }
  [[ -f "${agents}/com.slopcode.slopgate-agent-mlx.plist" ]] || { echo "  MISSING agent plist"; FAILED=1; }
  local agent_plist server_plist
  agent_plist="$(cat "${agents}/com.slopcode.slopgate-agent-mlx.plist")"
  server_plist="$(cat "${agents}/com.slopcode.mlx.plist")"
  assert_contains "${agent_plist}" "<string>--slots</string><string>1</string>" "static single slot"
  assert_contains "${agent_plist}" "minimaxai/minimax-m3@128k" "agent canonical"
  assert_contains "${agent_plist}" "pipenetwork/MiniMax-M3-MLX-mixed-3_6bit" "upstream model"
  assert_contains "${server_plist}" "<key>MLX_EXEC</key><string>true</string>" "server foreground exec"
}

test_registry
test_launcher_dry_run
test_installer_dry_run

if [[ "${FAILED}" -eq 0 ]]; then
  echo "MLX profile: OK"
else
  echo "MLX profile: FAILED"
fi
exit "${FAILED}"
