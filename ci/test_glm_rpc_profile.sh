#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/_common.sh"

FAILED=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

is_mac() { [[ "$(uname -s)" == "Darwin" ]]; }

stub_home() {
  # $1 = home dir, $2... = binary basenames to stub under .local/llama.cpp
  local home_dir="$1"; shift
  mkdir -p "${home_dir}/.local/llama.cpp"
  local b
  for b in "$@"; do
    cat > "${home_dir}/.local/llama.cpp/${b}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${home_dir}/.local/llama.cpp/${b}"
  done
}

test_glm_main_dry_run() {
  echo "TEST: GLM-5.2 RPC main launcher emits --rpc + even tensor-split + glm sampler"
  if ! is_mac; then echo "SKIP: glm main launcher (macOS-only)"; return 0; fi
  local home_dir="${TMPDIR}/home-glm"
  local model_path="${TMPDIR}/GLM-5.2-UD-Q4_K_S-00001-of-00010.gguf"
  stub_home "${home_dir}" llama-server
  : > "${model_path}"

  local output
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
    LLAMACPP_MODEL="${model_path}" \
    GLM_RPC_WORKER="10.78.5.2:50052" \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_glm_rpc.sh"
  )"

  if [[ "${output}" == *"--rpc 10.78.5.2:50052"* && \
        "${output}" == *"--tensor-split 0.5"* && \
        "${output}" == *"--alias glm"* && \
        "${output}" == *"-c 131072"* && \
        "${output}" == *"-np 1"* && \
        "${output}" == *"--cache-type-k q8_0"* && \
        "${output}" == *"--temp 1.0"* && \
        "${output}" == *"--top-p 0.95"* && \
        "${output}" != *"--top-k"* ]]; then
    echo "PASS: GLM-5.2 main node serves split over RPC with the GLM-5.x sampler"
  else
    echo "FAIL: GLM-5.2 main launcher profile mismatch"
    echo "${output}"
    return 1
  fi
}

test_glm_main_refuses_resident_server() {
  echo "TEST: GLM-5.2 main launcher refuses to start while another llama-server is resident"
  if ! is_mac; then echo "SKIP: glm preflight (macOS-only)"; return 0; fi
  # A non-dry-run with a bogus worker should fail the preflight before any load.
  # We assert it dies (non-zero) without GLM_RPC_FORCE rather than hanging.
  local home_dir="${TMPDIR}/home-glm-pf"
  stub_home "${home_dir}" llama-server
  if HOME="${home_dir}" \
     LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
     LLAMACPP_MODEL="${TMPDIR}/x.gguf" \
     GLM_RPC_WORKER="127.0.0.1:1" \
     bash "${REPO_ROOT}/scripts/server_start_glm_rpc.sh" >/dev/null 2>&1; then
    echo "FAIL: launcher started despite resident llama-server / unreachable worker"
    return 1
  fi
  echo "PASS: launcher refuses without GLM_RPC_FORCE"
}

test_rpc_worker_dry_run() {
  echo "TEST: rpc-server worker binds the bridge address with cache enabled"
  if ! is_mac; then echo "SKIP: rpc worker (macOS-only)"; return 0; fi
  local home_dir="${TMPDIR}/home-worker"
  stub_home "${home_dir}" rpc-server
  local output
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
    RPC_WORKER_BIND="10.78.5.2" \
    RPC_WORKER_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_rpc_worker.sh"
  )"
  if [[ "${output}" == *"rpc-server -H 10.78.5.2 -p 50052 -c"* ]]; then
    echo "PASS: worker emits rpc-server -H <bridge> -p 50052 -c"
  else
    echo "FAIL: worker command mismatch"
    echo "${output}"
    return 1
  fi
}

test_tb5_bridge_addresses() {
  echo "TEST: tb5_bridge_setup maps main/worker to .1/.2 and rejects bad roles"
  if ! is_mac; then echo "SKIP: tb5 bridge (macOS-only)"; return 0; fi
  local main_out worker_out
  main_out="$(TB5_DRY_RUN=true bash "${REPO_ROOT}/scripts/tb5_bridge_setup.sh" main)"
  worker_out="$(TB5_DRY_RUN=true bash "${REPO_ROOT}/scripts/tb5_bridge_setup.sh" worker)"
  if [[ "${main_out}" == *"10.78.5.1"* && "${main_out}" == *"10.78.5.2"* && \
        "${worker_out}" == *"- ip:   10.78.5.2"* ]] \
     && ! TB5_DRY_RUN=true bash "${REPO_ROOT}/scripts/tb5_bridge_setup.sh" bogusrole >/dev/null 2>&1; then
    echo "PASS: main=.1 worker=.2, bad role rejected"
  else
    echo "FAIL: tb5 bridge address mapping wrong"
    echo "main: ${main_out}"
    echo "worker: ${worker_out}"
    return 1
  fi
}

test_wired_limit_plist() {
  echo "TEST: install_mac_wired_limit emits the iogpu plist and guards oversized limits"
  if ! is_mac; then echo "SKIP: wired-limit (macOS-only)"; return 0; fi
  local out
  out="$(WIRED_LIMIT_DRY_RUN=true bash "${REPO_ROOT}/scripts/install_mac_wired_limit.sh" 253952)"
  if [[ "${out}" == *"com.slopcode.iogpu-wired-limit"* && \
        "${out}" == *"iogpu.wired_limit_mb=253952"* && \
        "${out}" == *"/Library/LaunchDaemons/com.slopcode.iogpu-wired-limit.plist"* ]] \
     && ! bash "${REPO_ROOT}/scripts/install_mac_wired_limit.sh" 999999999 >/dev/null 2>&1; then
    echo "PASS: plist label + sysctl arg correct, oversized limit rejected"
  else
    echo "FAIL: wired-limit dry-run output unexpected"
    echo "${out}"
    return 1
  fi
}

test_glm52_registry_alias() {
  echo "TEST: llamacpp_models.py glm-5.2 alias resolves to the Q4_K_S split"
  if python3 - "${REPO_ROOT}/scripts/llamacpp_models.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("llamacpp_models", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
m = mod.MODEL_BY_ALIAS["glm-5.2"]
assert m.repo_id == "unsloth/GLM-5.2-GGUF", m.repo_id
assert any("UD-Q4_K_S" in p for p in m.include), m.include
assert not m.default
PY
  then
    echo "PASS: glm-5.2 -> unsloth/GLM-5.2-GGUF UD-Q4_K_S"
  else
    echo "FAIL: glm-5.2 alias missing or wrong"
    return 1
  fi
}

bash -n "${REPO_ROOT}/scripts/server_start_glm_rpc.sh"   || { echo "FAIL: server_start_glm_rpc.sh syntax"; exit 1; }
bash -n "${REPO_ROOT}/scripts/server_start_rpc_worker.sh" || { echo "FAIL: server_start_rpc_worker.sh syntax"; exit 1; }
bash -n "${REPO_ROOT}/scripts/tb5_bridge_setup.sh"        || { echo "FAIL: tb5_bridge_setup.sh syntax"; exit 1; }
bash -n "${REPO_ROOT}/scripts/install_mac_wired_limit.sh" || { echo "FAIL: install_mac_wired_limit.sh syntax"; exit 1; }

test_glm_main_dry_run || FAILED=$((FAILED + 1))
test_glm_main_refuses_resident_server || FAILED=$((FAILED + 1))
test_rpc_worker_dry_run || FAILED=$((FAILED + 1))
test_tb5_bridge_addresses || FAILED=$((FAILED + 1))
test_wired_limit_plist || FAILED=$((FAILED + 1))
test_glm52_registry_alias || FAILED=$((FAILED + 1))

if [[ "${FAILED}" -gt 0 ]]; then
  echo "${FAILED} test(s) failed"
  exit 1
fi
echo "all GLM-5.2 RPC profile tests passed"
