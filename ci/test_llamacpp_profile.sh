#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/_common.sh"

FAILED=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# Pick a free TCP port instead of hardcoding values that may be in use on
# the dev box (e.g. slopsearch already binds 18080). Falls back to a
# deterministic per-test offset above the ephemeral range if Python is
# unavailable for some reason.
free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
}

test_server_start_dry_run() {
  echo "TEST: llama.cpp launcher dry-run profile"
  local home_dir="${TMPDIR}/home"
  local model_path="${TMPDIR}/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
  local mmproj_path="${TMPDIR}/mmproj-BF16.gguf"
  mkdir -p "${home_dir}/.local/llama.cpp"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"
  : > "${model_path}"
  : > "${mmproj_path}"

  local output
  local reasoning_budget
  reasoning_budget="$(default_reasoning_budget)"
  local port
  port="$(free_port)"
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
    LLAMACPP_MODEL="${model_path}" \
    LLAMACPP_MMPROJ="${mmproj_path}" \
    LLAMACPP_PORT="${port}" \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  local platform moe_ok=1
  platform="$(uname -s)"
  # 35B-A3B is MoE: non-Mac emits --n-cpu-moe 35; Mac uses unified memory (no split).
  if [[ "${platform}" == "Darwin" ]]; then
    [[ "${output}" != *"--n-cpu-moe"* ]] || moe_ok=0
  else
    [[ "${output}" == *"--n-cpu-moe 35"* ]] || moe_ok=0
  fi

  # Thread caps: only pinned on non-Mac. On Mac the flags must be absent.
  local threads_ok=1
  if [[ "${platform}" == "Darwin" ]]; then
    [[ "${output}" != *"--threads "* ]] || threads_ok=0
    [[ "${output}" != *"--threads-http "* ]] || threads_ok=0
  else
    [[ "${output}" == *"--threads "* ]] || threads_ok=0
    [[ "${output}" == *"--threads-http 4"* ]] || threads_ok=0
  fi

  local mmproj_offload_ok=1
  if [[ "${platform}" == "Darwin" && "$(detect_total_ram_gb)" -lt 64 ]]; then
    [[ "${output}" == *"--no-mmproj-offload"* ]] || mmproj_offload_ok=0
  else
    [[ "${output}" == *"--mmproj-offload"* ]] || mmproj_offload_ok=0
  fi

  local context_expected="-c 131072"
  local np_expected="-np 1"

  if [[ "${output}" == *"${context_expected}"* && \
        "${output}" == *"--cache-type-k q8_0"* && \
        "${output}" == *"--cache-type-v q8_0"* && \
        "${output}" != *"--slot-save-path"* && \
        "${output}" != *"- slot-save-path:"* && \
        "${output}" == *"-fa on"* && \
        "${output}" == *"--alias qwen"* && \
        "${output}" == *"--jinja"* && \
        "${output}" == *"--reasoning-format deepseek"* && \
        "${output}" == *"--reasoning-budget ${reasoning_budget}"* && \
        "${output}" == *"--top-p 0.95"* && \
        "${output}" == *"--top-k 20"* && \
        "${output}" == *"--port ${port}"* && \
        "${output}" == *"${np_expected}"* && \
        "${output}" == *"-ub 1024"* && \
        "${output}" == *"Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"* && \
        "${moe_ok}" == "1" && \
        "${threads_ok}" == "1" && \
        "${mmproj_offload_ok}" == "1" ]]; then
    echo "PASS: launcher emits the blessed profile for $(uname -s) (${np_expected}, ${context_expected})"
  else
    echo "FAIL: launcher profile mismatch (moe_ok=${moe_ok} threads_ok=${threads_ok} mmproj_offload_ok=${mmproj_offload_ok})"
    echo "${output}"
    return 1
  fi
}

test_server_start_ignores_slot_save_path() {
  echo "TEST: launcher keeps llama.cpp slot save disabled"
  local home_dir="${TMPDIR}/home-slot-save"
  local model_path="${TMPDIR}/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
  local mmproj_path="${TMPDIR}/mmproj-slot-save.gguf"
  mkdir -p "${home_dir}/.local/llama.cpp"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"
  : > "${model_path}"
  : > "${mmproj_path}"

  local output port
  port="$(free_port)"
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
    LLAMACPP_MODEL="${model_path}" \
    LLAMACPP_MMPROJ="${mmproj_path}" \
    LLAMACPP_PORT="${port}" \
    LLAMACPP_SLOT_SAVE_PATH="${TMPDIR}/slots" \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  if [[ "${output}" != *"--slot-save-path"* && \
        "${output}" != *"- slot-save-path:"* && \
        ! -d "${TMPDIR}/slots" ]]; then
    echo "PASS: LLAMACPP_SLOT_SAVE_PATH does not enable slot save"
  else
    echo "FAIL: launcher emitted slot-save support"
    echo "${output}"
    return 1
  fi
}

test_server_start_mtp_flags() {
  echo "TEST: launcher emits MTP flags for *-mtp-* alias"
  local home_dir="${TMPDIR}/home-mtp"
  local model_path="${TMPDIR}/Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf"
  local mmproj_path="${TMPDIR}/mmproj-mtp.gguf"
  mkdir -p "${home_dir}/.local/llama.cpp"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"
  : > "${model_path}"
  : > "${mmproj_path}"

  local output port
  port="$(free_port)"
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
    LLAMACPP_MODEL="${model_path}" \
    LLAMACPP_MMPROJ="${mmproj_path}" \
    LLAMACPP_MODEL_ALIAS=qwen3.6-35b-a3b-mtp-q4 \
    LLAMACPP_PORT="${port}" \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  if [[ "${output}" == *"--spec-type draft-mtp"* && \
        "${output}" == *"--spec-draft-n-max 2"* && \
        "${output}" == *"--temp 0.6"* && \
        "${output}" == *"--presence-penalty 0.0"* ]]; then
    echo "PASS: MTP alias triggers draft-mtp + precise-coding sampler"
  else
    echo "FAIL: MTP flags missing"
    echo "${output}"
    return 1
  fi
}

test_server_start_thread_override() {
  echo "TEST: launcher honors LLAMACPP_THREADS override"
  local home_dir="${TMPDIR}/home-threads"
  local model_path="${TMPDIR}/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
  local mmproj_path="${TMPDIR}/mmproj-threads.gguf"
  mkdir -p "${home_dir}/.local/llama.cpp"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"
  : > "${model_path}"
  : > "${mmproj_path}"

  local output port
  port="$(free_port)"
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
    LLAMACPP_MODEL="${model_path}" \
    LLAMACPP_MMPROJ="${mmproj_path}" \
    LLAMACPP_PORT="${port}" \
    LLAMACPP_THREADS=7 \
    LLAMACPP_THREADS_HTTP=3 \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  if [[ "$(uname -s)" == "Darwin" ]]; then
    # Mac still honors explicit overrides — user opts in, launcher emits.
    if [[ "${output}" == *"--threads 7"* && "${output}" == *"--threads-http 3"* ]]; then
      echo "PASS: explicit thread overrides emitted on Mac when requested"
    else
      echo "FAIL: Mac did not honor explicit LLAMACPP_THREADS override"
      echo "${output}"
      return 1
    fi
  else
    if [[ "${output}" == *"--threads 7"* && "${output}" == *"--threads-http 3"* ]]; then
      echo "PASS: launcher honors LLAMACPP_THREADS / LLAMACPP_THREADS_HTTP"
    else
      echo "FAIL: thread overrides not in emitted command"
      echo "${output}"
      return 1
    fi
  fi
}

test_server_start_mmproj_offload_override() {
  echo "TEST: launcher honors LLAMACPP_MMPROJ_OFFLOAD override"
  local home_dir="${TMPDIR}/home-mmproj-offload"
  local model_path="${TMPDIR}/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
  local mmproj_path="${TMPDIR}/mmproj-offload.gguf"
  mkdir -p "${home_dir}/.local/llama.cpp"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"
  : > "${model_path}"
  : > "${mmproj_path}"

  local output port
  port="$(free_port)"
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
    LLAMACPP_MODEL="${model_path}" \
    LLAMACPP_MMPROJ="${mmproj_path}" \
    LLAMACPP_MMPROJ_OFFLOAD=false \
    LLAMACPP_PORT="${port}" \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  if [[ "${output}" == *"--no-mmproj-offload"* && "${output}" != *"--mmproj-offload "* ]]; then
    echo "PASS: LLAMACPP_MMPROJ_OFFLOAD=false disables projector GPU offload"
  else
    echo "FAIL: mmproj offload override did not propagate"
    echo "${output}"
    return 1
  fi
}

test_server_start_instance_overrides() {
  echo "TEST: launcher honors LLAMACPP_INSTANCE and LLAMACPP_SERVED_ALIAS"
  local home_dir="${TMPDIR}/home-inst"
  local model_path="${TMPDIR}/Qwen_Qwen3.6-27B-Q4_K_M.gguf"
  mkdir -p "${home_dir}/.local/llama.cpp"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"
  : > "${model_path}"

  local output port
  port="$(free_port)"
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
    LLAMACPP_MODEL="${model_path}" \
    LLAMACPP_MMPROJ=off \
    LLAMACPP_PORT="${port}" \
    LLAMACPP_INSTANCE=27b \
    LLAMACPP_SERVED_ALIAS=qwen-27b \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  local np_expected
  np_expected="-np 1"
  if [[ "${output}" == *"--alias qwen-27b"* && \
        "${output}" == *"--port ${port}"* && \
        "${output}" == *"- instance: 27b"* && \
        "${output}" == *"${np_expected}"* && \
        "${output}" == *"-ub 1024"* ]]; then
    echo "PASS: instance suffix and served alias take effect"
  else
    echo "FAIL: instance override did not propagate"
    echo "${output}"
    return 1
  fi
}

test_opencode_config() {
  echo "TEST: OpenCode llama.cpp config generation"
  local home_dir="${TMPDIR}/home-config"
  local config_path="${TMPDIR}/opencode.json"
  mkdir -p "${home_dir}"
  cat > "${config_path}" <<'JSON'
{
  "mcp": {
    "helpy": {"type": "local", "command": ["/bin/helpy", "mcp-stdio"], "enabled": true}
  }
}
JSON

  HOME="${home_dir}" \
  OPENCODE_CONFIG_PATH="${config_path}" \
  OPENCODE_SKIP_PRIVACY_ENV=true \
  bash "${REPO_ROOT}/scripts/opencode_set_llamacpp.sh" >/dev/null

  local common_ok=1
  local reasoning_budget
  reasoning_budget="$(default_reasoning_budget)"
  grep -q '"disable": true' "${config_path}" || common_ok=0
  grep -q '"permission": "allow"' "${config_path}" || common_ok=0
  grep -q '"output": 16384' "${config_path}" || common_ok=0
  grep -q '"reasoning": true' "${config_path}" || common_ok=0
  grep -q '"interleaved"' "${config_path}" || common_ok=0
  grep -q '"reasoning_content"' "${config_path}" || common_ok=0
  grep -q '"attachment": true' "${config_path}" || common_ok=0
  grep -q '"modalities"' "${config_path}" || common_ok=0
  grep -q '"input"' "${config_path}" || common_ok=0
  grep -q '"image"' "${config_path}" || common_ok=0
  grep -q '"output"' "${config_path}" || common_ok=0
  grep -q "\"thinking_budget\": ${reasoning_budget}" "${config_path}" || common_ok=0
  grep -q '"temperature": 0.6' "${config_path}" || common_ok=0
  grep -q '"top_p": 0.95' "${config_path}" || common_ok=0
  grep -q '"top_k": 20' "${config_path}" || common_ok=0
  grep -q '"min_p": 0.0' "${config_path}" || common_ok=0
  grep -q '"presence_penalty": 0.0' "${config_path}" || common_ok=0
  grep -q '"repeat_penalty": 1.0' "${config_path}" || common_ok=0
  grep -q '"websearch": false' "${config_path}" || common_ok=0
  grep -q '"openTelemetry": false' "${config_path}" || common_ok=0
  grep -q '"share": "disabled"' "${config_path}" || common_ok=0
  grep -q '"autoupdate": false' "${config_path}" || common_ok=0
  grep -q '"opencode"' "${config_path}" || common_ok=0
  grep -q '"llmgateway"' "${config_path}" || common_ok=0
  grep -q '"github-copilot"' "${config_path}" || common_ok=0
  grep -q '"disabled_providers"' "${config_path}" || common_ok=0
  grep -q '"exa"' "${config_path}" || common_ok=0
  grep -q '"mcp"' "${config_path}" || common_ok=0
  grep -q '"/bin/helpy"' "${config_path}" || common_ok=0

  local platform_ok=1
  local context_expected=131072
  grep -q '"model": "slopgate/qwen"' "${config_path}" || platform_ok=0
  grep -q '"small_model": "slopgate/qwen"' "${config_path}" || platform_ok=0
  grep -q "\"context\": ${context_expected}" "${config_path}" || platform_ok=0
  grep -q 'http://127.0.0.1:8080/v1' "${config_path}" || platform_ok=0
  grep -q '"slopgate"' "${config_path}" || platform_ok=0
  grep -q '"qwen122b"' "${config_path}" || platform_ok=0
  grep -q '"qwen"' "${config_path}" || platform_ok=0
  grep -q '"qwen27b"' "${config_path}" || platform_ok=0
  grep -q '"model": "slopgate/qwen"' "${config_path}" || platform_ok=0
  grep -q '"model": "slopgate/qwen"' "${config_path}" || platform_ok=0
  [[ -f "${home_dir}/.config/slopgate/opencode-session-id" ]] || platform_ok=0

  if [[ "${common_ok}" == "1" && "${platform_ok}" == "1" ]]; then
    echo "PASS: OpenCode config matches the blessed profile for $(uname -s)"
  else
    echo "FAIL: OpenCode config missing expected fields (common=${common_ok} platform=${platform_ok})"
    cat "${config_path}"
    return 1
  fi
}

test_opencode_config_slopgate() {
  echo "TEST: SLOPGATE_LEADER points opencode at the slopgate balancer"
  local home_dir="${TMPDIR}/home-config-slopgate"
  local config_path="${TMPDIR}/opencode-slopgate.json"
  mkdir -p "${home_dir}"

  HOME="${home_dir}" \
  OPENCODE_CONFIG_PATH="${config_path}" \
  OPENCODE_SKIP_PRIVACY_ENV=true \
  SLOPGATE_LEADER=10.0.0.99 \
  bash "${REPO_ROOT}/scripts/opencode_set_llamacpp.sh" >/dev/null

  local ok=1
  grep -q '"baseURL": "http://10.0.0.99:8080/v1"' "${config_path}" || ok=0
  grep -q '"x-session-affinity"' "${config_path}" || ok=0
  grep -q '"model": "slopgate/qwen"' "${config_path}" || ok=0
  grep -q '"small_model": "slopgate/qwen"' "${config_path}" || ok=0
  grep -q '"qwen27b"' "${config_path}" || ok=0
  [[ -f "${home_dir}/.config/slopgate/opencode-session-id" ]] || ok=0

  local explicit_path="${TMPDIR}/opencode-slopgate-explicit.json"
  HOME="${home_dir}" \
  OPENCODE_CONFIG_PATH="${explicit_path}" \
  OPENCODE_SKIP_PRIVACY_ENV=true \
  SLOPGATE_LEADER=10.0.0.99:9090 \
  bash "${REPO_ROOT}/scripts/opencode_set_llamacpp.sh" >/dev/null

  grep -q '"baseURL": "http://10.0.0.99:9090/v1"' "${explicit_path}" || ok=0

  if [[ "${ok}" == "1" ]]; then
    echo "PASS: SLOPGATE_LEADER baseURL + x-session-affinity header set"
  else
    echo "FAIL: opencode SLOPGATE_LEADER branch did not produce expected config"
    cat "${config_path}"
    return 1
  fi
}

test_pi_config() {
  echo "TEST: Pi llama.cpp config generation"
  local home_dir="${TMPDIR}/home-pi"
  local config_dir="${TMPDIR}/pi-agent"
  mkdir -p "${home_dir}" "${config_dir}"

  HOME="${home_dir}" \
  PI_CODING_AGENT_DIR="${config_dir}" \
  PI_SKIP_PRIVACY_ENV=true \
  bash "${REPO_ROOT}/scripts/pi_set_llamacpp.sh" >/dev/null

  local settings="${config_dir}/settings.json"
  local models="${config_dir}/models.json"

  local common_ok=1
  grep -q '"defaultProvider": "llamacpp"' "${settings}" || common_ok=0
  grep -q '"defaultThinkingLevel": "high"' "${settings}" || common_ok=0
  grep -q '"enableInstallTelemetry": false' "${settings}" || common_ok=0
  grep -q '"api": "openai-completions"' "${models}" || common_ok=0
  grep -q '"apiKey": "llamacpp"' "${models}" || common_ok=0
  grep -q '"supportsDeveloperRole": false' "${models}" || common_ok=0
  grep -q '"supportsReasoningEffort": false' "${models}" || common_ok=0
  grep -q '"image"' "${models}" || common_ok=0
  grep -q '"maxTokens": 16384' "${models}" || common_ok=0

  local platform_ok=1
  local pi_context_expected=131072
  if [[ "$(uname -s)" == "Darwin" && "$(detect_total_ram_gb)" -lt 64 ]]; then
    pi_context_expected=131072
  fi
  grep -q '"defaultModel": "qwen"' "${settings}" || platform_ok=0
  grep -q '"baseUrl": "http://127.0.0.1:8080/v1"' "${models}" || platform_ok=0
  grep -q '"id": "qwen"' "${models}" || platform_ok=0
  grep -q "\"contextWindow\": ${pi_context_expected}" "${models}" || platform_ok=0
  if grep -q 'qwen-27b\|qwen-35b-a3b' "${settings}" "${models}"; then
    platform_ok=0
  fi

  if [[ "${common_ok}" == "1" && "${platform_ok}" == "1" ]]; then
    echo "PASS: Pi config points at local llama.cpp with telemetry disabled"
  else
    echo "FAIL: Pi config missing expected fields (common=${common_ok} platform=${platform_ok})"
    cat "${settings}"
    cat "${models}"
    return 1
  fi
}

test_models_default_alias() {
  echo "TEST: llamacpp_models.py default alias"
  local alias
  alias="$(python3 "${REPO_ROOT}/scripts/llamacpp_models.py" default-alias)"
  if [[ "${alias}" == "qwen3.6-35b-a3b-mtp-q4" ]]; then
    echo "PASS: default alias is qwen3.6-35b-a3b-mtp-q4"
  else
    echo "FAIL: default alias was '${alias}'"
    return 1
  fi
}

test_setup_backend_selection() {
  echo "TEST: setup_llamacpp.sh backend selection"
  local home_dir="${TMPDIR}/home-setup"
  local fake_bin="${TMPDIR}/fake-bin"
  mkdir -p "${home_dir}/.local/llama.cpp" "${fake_bin}"

  # Fake `curl` so the script never hits the network. Emits a minimal release
  # payload so only the dispatch branching is exercised.
  cat > "${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"tag_name":"bTEST","assets":[]}'
EOF
  chmod +x "${fake_bin}/curl"

  run_setup() {
    local var="$1"
    env -i \
      HOME="${home_dir}" \
      PATH="${fake_bin}:/usr/bin:/bin" \
      LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
      LLAMACPP_BACKEND="${var}" \
      bash "${REPO_ROOT}/scripts/setup_llamacpp.sh" 2>&1 || true
  }

  local out_prebuilt out_cuda out_bogus
  out_prebuilt="$(run_setup prebuilt)"
  if [[ "${out_prebuilt}" != *"backend: prebuilt"* ]]; then
    echo "FAIL: explicit LLAMACPP_BACKEND=prebuilt not honored"
    echo "${out_prebuilt}"
    return 1
  fi

  out_cuda="$(run_setup cuda-source)"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ "${out_cuda}" != *"only supported on Linux"* ]]; then
      echo "FAIL: cuda-source should refuse non-Linux platforms"
      echo "${out_cuda}"
      return 1
    fi
  else
    if [[ "${out_cuda}" != *"backend: cuda-source"* ]]; then
      echo "FAIL: explicit LLAMACPP_BACKEND=cuda-source not honored on Linux"
      echo "${out_cuda}"
      return 1
    fi
  fi

  out_bogus="$(run_setup nope)"
  if [[ "${out_bogus}" != *"unknown LLAMACPP_BACKEND"* ]]; then
    echo "FAIL: invalid backend value not rejected"
    echo "${out_bogus}"
    return 1
  fi

  echo "PASS: setup backend dispatch accepts prebuilt/cuda-source, rejects bogus"
}

test_server_exec_mode() {
  echo "TEST: LLAMACPP_EXEC=true replaces the shell with llama-server"
  local home_dir="${TMPDIR}/home-exec"
  local model_path="${TMPDIR}/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
  local mmproj_path="${TMPDIR}/mmproj-exec.gguf"
  local stamp="${TMPDIR}/exec-args"
  mkdir -p "${home_dir}/.local/llama.cpp"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${stamp}"
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"
  : > "${model_path}"
  : > "${mmproj_path}"

  local port
  port="$(free_port)"
  HOME="${home_dir}" \
  LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
  LLAMACPP_MODEL="${model_path}" \
  LLAMACPP_MMPROJ="${mmproj_path}" \
  LLAMACPP_PORT="${port}" \
  LLAMACPP_SMOKE_TEST=false \
  LLAMACPP_EXEC=true \
  bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh" >/dev/null 2>&1

  if [[ ! -s "${stamp}" ]]; then
    echo "FAIL: exec-mode launcher did not invoke llama-server"
    return 1
  fi
  local moe_ok=1
  if [[ "$(uname -s)" == "Darwin" ]]; then
    # Mac: no MoE split (unified memory, Metal handles everything).
    grep -qx -- '--n-cpu-moe' "${stamp}" && moe_ok=0
  else
    grep -qx -- '--n-cpu-moe' "${stamp}" || moe_ok=0
    grep -qx -- '35' "${stamp}" || moe_ok=0
  fi
  local np_value ub_value
  np_value=1
  ub_value=1024
  if grep -qx -- '-np' "${stamp}" \
    && grep -qx -- "${np_value}" "${stamp}" \
    && ! grep -qx -- '--slot-save-path' "${stamp}" \
    && grep -qx -- '--port' "${stamp}" \
    && grep -qx -- "${port}" "${stamp}" \
    && grep -qx -- '--reasoning-budget' "${stamp}" \
    && grep -qx -- "$(default_reasoning_budget)" "${stamp}" \
    && grep -qx -- '-ub' "${stamp}" \
    && grep -qx -- "${ub_value}" "${stamp}" \
    && [[ "${moe_ok}" == "1" ]]; then
    echo "PASS: exec-mode argv has -np ${np_value}, -ub ${ub_value}, MoE flags correct"
  else
    echo "FAIL: exec-mode argv did not include expected flags"
    cat "${stamp}"
    return 1
  fi
}

test_server_legacy_cpu_moe_fallback() {
  echo "TEST: LLAMACPP_CPU_MOE=true still works as the 'all experts on CPU' escape hatch"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "SKIP: legacy CPU_MOE fallback (Linux/Windows only)"
    return 0
  fi
  local home_dir="${TMPDIR}/home-legacymoe"
  local model_path="${TMPDIR}/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
  local mmproj_path="${TMPDIR}/mmproj-legacymoe.gguf"
  mkdir -p "${home_dir}/.local/llama.cpp"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"
  : > "${model_path}"
  : > "${mmproj_path}"

  local output port
  port="$(free_port)"
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
    LLAMACPP_MODEL="${model_path}" \
    LLAMACPP_MMPROJ="${mmproj_path}" \
    LLAMACPP_PORT="${port}" \
    LLAMACPP_CPU_MOE=true \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  if [[ "${output}" == *"--n-cpu-moe 99"* && "${output}" != *"--n-cpu-moe 35"* ]]; then
    echo "PASS: LLAMACPP_CPU_MOE=true pins --n-cpu-moe 99 (all experts on CPU)"
  else
    echo "FAIL: legacy CPU_MOE fallback did not emit --n-cpu-moe 99"
    echo "${output}"
    return 1
  fi
}

test_server_start_loopback_slopgate() {
  echo "TEST: launcher binds loopback when LLAMACPP_BIND_LOOPBACK=true or slopgate unit present"
  local home_dir="${TMPDIR}/home-loopback"
  local model_path="${TMPDIR}/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
  local mmproj_path="${TMPDIR}/mmproj-loopback.gguf"
  mkdir -p "${home_dir}/.local/llama.cpp"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"
  : > "${model_path}"
  : > "${mmproj_path}"

  local explicit_out
  explicit_out="$(
    HOME="${home_dir}" \
    LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
    LLAMACPP_MODEL="${model_path}" \
    LLAMACPP_MMPROJ="${mmproj_path}" \
    LLAMACPP_BIND_LOOPBACK=true \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  if [[ "${explicit_out}" == *"--host 127.0.0.1"* && "${explicit_out}" == *"--port 8080"* ]]; then
    echo "PASS: LLAMACPP_BIND_LOOPBACK=true forces --host 127.0.0.1 on the default port"
  else
    echo "FAIL: LLAMACPP_BIND_LOOPBACK=true did not force loopback bind"
    echo "${explicit_out}"
    return 1
  fi

  local detect_home="${TMPDIR}/home-detect"
  mkdir -p "${detect_home}/.local/llama.cpp"
  cat > "${detect_home}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${detect_home}/.local/llama.cpp/llama-server"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    mkdir -p "${detect_home}/Library/LaunchAgents"
    : > "${detect_home}/Library/LaunchAgents/com.slopcode.slopgate-balancer.plist"
  else
    mkdir -p "${detect_home}/.config/systemd/user"
    : > "${detect_home}/.config/systemd/user/slopgate-balancer.service"
  fi

  local detect_out
  detect_out="$(
    HOME="${detect_home}" \
    LLAMACPP_HOME="${detect_home}/.local/llama.cpp" \
    LLAMACPP_MODEL="${model_path}" \
    LLAMACPP_MMPROJ="${mmproj_path}" \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  if [[ "${detect_out}" == *"--host 127.0.0.1"* && "${detect_out}" == *"--port 8081"* ]]; then
    echo "PASS: presence of slopgate unit flips bind to 127.0.0.1:8081"
  else
    echo "FAIL: slopgate unit detection did not flip bind"
    echo "${detect_out}"
    return 1
  fi
}

test_install_linux_systemd_dry_run() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "SKIP: install_linux_systemd dry-run (Linux-only)"
    return 0
  fi
  echo "TEST: install_linux_systemd.sh dry-run writes the expected unit"
  local home_dir="${TMPDIR}/home-install"
  local unit_dir="${TMPDIR}/units"
  mkdir -p "${home_dir}" "${unit_dir}"
  local unit_file="${unit_dir}/slopcode-llamacpp.service"

  HOME="${home_dir}" \
  INSTALL_DRY_RUN=true \
  UNIT_DIR="${unit_dir}" \
  bash "${REPO_ROOT}/scripts/install_linux_systemd.sh" >/dev/null

  if [[ ! -f "${unit_file}" ]]; then
    echo "FAIL: unit file was not written"
    return 1
  fi
  if grep -q '^ExecStart=.*server_start_llamacpp\.sh$' "${unit_file}" \
    && grep -q '^Environment=LLAMACPP_EXEC=true$' "${unit_file}" \
    && grep -q '^Environment=LLAMACPP_SMOKE_TEST=false$' "${unit_file}" \
    && grep -q '^Restart=on-failure$' "${unit_file}" \
    && grep -q '^\[Install\]$' "${unit_file}" \
    && grep -q '^WantedBy=default.target$' "${unit_file}"; then
    echo "PASS: unit invokes the launcher in exec mode with restart policy"
  else
    echo "FAIL: unit file missing expected directives"
    cat "${unit_file}"
    return 1
  fi
}

test_server_start_dry_run || FAILED=$((FAILED + 1))
test_server_start_instance_overrides || FAILED=$((FAILED + 1))
test_server_start_thread_override || FAILED=$((FAILED + 1))
test_server_start_mtp_flags || FAILED=$((FAILED + 1))
test_server_start_mmproj_offload_override || FAILED=$((FAILED + 1))
test_server_start_ignores_slot_save_path || FAILED=$((FAILED + 1))
test_server_start_loopback_slopgate || FAILED=$((FAILED + 1))
test_server_exec_mode || FAILED=$((FAILED + 1))
test_server_legacy_cpu_moe_fallback || FAILED=$((FAILED + 1))
test_opencode_config || FAILED=$((FAILED + 1))
test_opencode_config_slopgate || FAILED=$((FAILED + 1))
test_pi_config || FAILED=$((FAILED + 1))
test_models_default_alias || FAILED=$((FAILED + 1))
test_setup_backend_selection || FAILED=$((FAILED + 1))
test_install_linux_systemd_dry_run || FAILED=$((FAILED + 1))

if [[ "${FAILED}" -gt 0 ]]; then
  echo "${FAILED} test(s) failed"
  exit 1
fi
echo "all llama.cpp profile tests passed"
