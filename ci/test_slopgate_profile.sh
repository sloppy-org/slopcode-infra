#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/_common.sh"

FAILED=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# Fake slopgate binary the install scripts can resolve and link to.
fake_bin="${TMPDIR}/slopgate-bin"
mkdir -p "${fake_bin}"
cat > "${fake_bin}/slopgate" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${fake_bin}/slopgate"

leader_env_file() {
  local env_file="$1"
  cat > "${env_file}" <<EOF
SLOPGATE_REVERSEPROXY_ADDR=0.0.0.0:8080
SLOPGATE_MANAGEMENT_ADDR=0.0.0.0:8085
SLOPGATE_LOCAL_AGENT_NAME=leader
SLOPGATE_LOCAL_LLAMACPP_ADDR=127.0.0.1:8081
SLOPGATE_LOCAL_MAX_CONTEXT=262144
SLOPGATE_LOCAL_MODEL_ALIAS=qwen
EOF
}

follower_env_file() {
  local env_file="$1"
  cat > "${env_file}" <<EOF
SLOPGATE_LEADER_MANAGEMENT_ADDR=10.77.0.1:8085
SLOPGATE_LOCAL_LLAMACPP_ADDR=127.0.0.1:8080
SLOPGATE_EXTERNAL_LLAMACPP_ADDR=10.77.0.10:8080
SLOPGATE_AGENT_NAME=follower-1
SLOPGATE_MAX_CONTEXT=262144
SLOPGATE_MODEL_ALIAS=qwen
EOF
}

test_leader_install_dry_run() {
  echo "TEST: install_slopgate_leader.sh dry-run writes balancer + agent units"
  local home_dir="${TMPDIR}/leader-home"
  local env_file="${home_dir}/.config/slopgate/leader.env"
  mkdir -p "$(dirname "${env_file}")"
  leader_env_file "${env_file}"

  case "$(uname -s)" in
    Darwin)
      local agents_dir="${TMPDIR}/leader-agents"
      mkdir -p "${agents_dir}"
      HOME="${home_dir}" \
      INSTALL_DRY_RUN=true \
      AGENTS_DIR="${agents_dir}" \
      SLOPGATE_BIN="${fake_bin}/slopgate" \
      bash "${REPO_ROOT}/scripts/install_slopgate_leader.sh" >/dev/null

      local b="${agents_dir}/com.slopcode.slopgate-balancer.plist"
      local a="${agents_dir}/com.slopcode.slopgate-agent.plist"
      if [[ -f "${b}" && -f "${a}" ]] \
        && grep -q '<string>balancer</string>' "${b}" \
        && grep -q '<string>0.0.0.0:8080</string>' "${b}" \
        && grep -q '<string>0.0.0.0:8085</string>' "${b}" \
        && ! grep -q '<string>--overbook-factor</string>' "${b}" \
        && ! grep -q '<string>--agent-stale-after</string>' "${b}" \
        && ! grep -q '<string>--agent-evict-after</string>' "${b}" \
        && ! grep -q '<string>--default-t-out</string>' "${b}" \
        && ! grep -q '<string>--session-lru-capacity</string>' "${b}" \
        && ! grep -q '<string>--session-ttl</string>' "${b}" \
        && ! grep -q '<string>--management-dashboard-enable</string>' "${b}" \
        && grep -q '<string>agent</string>' "${a}" \
        && grep -q '<string>127.0.0.1:8081</string>' "${a}" \
        && grep -q '<string>--max-context</string>' "${a}" \
        && grep -q '<string>262144</string>' "${a}" \
        && grep -q '<string>--model-alias</string>' "${a}" \
        && grep -q '<string>qwen</string>' "${a}" \
        && grep -q '<string>leader</string>' "${a}" \
        && ! grep -q '<string>--slots</string>' "${a}" \
        && ! grep -q '<string>--audio-llamacpp-addr</string>' "${a}"; then
        echo "PASS: balancer + agent plists carry the env-file values"
      else
        echo "FAIL: leader plists missing expected fields"
        ls -la "${agents_dir}"
        cat "${b}" "${a}" 2>/dev/null
        return 1
      fi
      ;;
    Linux)
      local unit_dir="${TMPDIR}/leader-units"
      mkdir -p "${unit_dir}"
      HOME="${home_dir}" \
      INSTALL_DRY_RUN=true \
      UNIT_DIR="${unit_dir}" \
      SLOPGATE_BIN="${fake_bin}/slopgate" \
      bash "${REPO_ROOT}/scripts/install_slopgate_leader.sh" >/dev/null

      local b="${unit_dir}/slopgate-balancer.service"
      local a="${unit_dir}/slopgate-agent.service"
      if [[ -f "${b}" && -f "${a}" ]] \
        && grep -q "^EnvironmentFile=${env_file}$" "${b}" \
        && grep -q 'ExecStart=.* balancer ' "${b}" \
        && grep -q -- '--reverseproxy-addr ${SLOPGATE_REVERSEPROXY_ADDR}' "${b}" \
        && ! grep -q -- '--overbook-factor' "${b}" \
        && ! grep -q -- '--agent-stale-after' "${b}" \
        && ! grep -q -- '--agent-evict-after' "${b}" \
        && ! grep -q -- '--default-t-out' "${b}" \
        && ! grep -q -- '--session-lru-capacity' "${b}" \
        && ! grep -q -- '--session-ttl' "${b}" \
        && ! grep -q -- '--management-dashboard-enable' "${b}" \
        && grep -q "^EnvironmentFile=${env_file}$" "${a}" \
        && grep -q 'ExecStart=.* agent ' "${a}" \
        && grep -q -- '--max-context ${SLOPGATE_LOCAL_MAX_CONTEXT}' "${a}" \
        && grep -q -- '--model-alias ${SLOPGATE_LOCAL_MODEL_ALIAS}' "${a}" \
        && grep -q -- '--name ${SLOPGATE_LOCAL_AGENT_NAME}' "${a}" \
        && ! grep -q -- '--slots' "${a}" \
        && ! grep -q -- '--audio-llamacpp-addr' "${a}"; then
        echo "PASS: balancer + agent units source ${env_file} and pass through env vars"
      else
        echo "FAIL: leader units missing expected fields"
        cat "${b}" "${a}" 2>/dev/null
        return 1
      fi
      ;;
    *)
      echo "SKIP: leader install (unsupported platform)"
      ;;
  esac
}

test_follower_install_dry_run() {
  echo "TEST: install_slopgate_follower.sh dry-run writes the agent unit"
  local home_dir="${TMPDIR}/follower-home"
  local env_file="${home_dir}/.config/slopgate/follower.env"
  mkdir -p "$(dirname "${env_file}")"
  follower_env_file "${env_file}"

  case "$(uname -s)" in
    Darwin)
      local agents_dir="${TMPDIR}/follower-agents"
      mkdir -p "${agents_dir}"
      HOME="${home_dir}" \
      INSTALL_DRY_RUN=true \
      AGENTS_DIR="${agents_dir}" \
      SLOPGATE_BIN="${fake_bin}/slopgate" \
      bash "${REPO_ROOT}/scripts/install_slopgate_follower.sh" >/dev/null

      local a="${agents_dir}/com.slopcode.slopgate-agent.plist"
      if [[ -f "${a}" ]] \
        && grep -q '<string>agent</string>' "${a}" \
        && grep -q '<string>10.77.0.1:8085</string>' "${a}" \
        && grep -q '<string>10.77.0.10:8080</string>' "${a}" \
        && grep -q '<string>follower-1</string>' "${a}" \
        && grep -q '<string>--max-context</string>' "${a}" \
        && grep -q '<string>--model-alias</string>' "${a}" \
        && ! grep -q '<string>--slots</string>' "${a}" \
        && ! grep -q '<string>--audio-llamacpp-addr</string>' "${a}"; then
        echo "PASS: follower agent plist carries the env-file values"
      else
        echo "FAIL: follower plist missing expected fields"
        cat "${a}" 2>/dev/null
        return 1
      fi
      ;;
    Linux)
      local unit_dir="${TMPDIR}/follower-units"
      mkdir -p "${unit_dir}"
      HOME="${home_dir}" \
      INSTALL_DRY_RUN=true \
      UNIT_DIR="${unit_dir}" \
      SLOPGATE_BIN="${fake_bin}/slopgate" \
      bash "${REPO_ROOT}/scripts/install_slopgate_follower.sh" >/dev/null

      local a="${unit_dir}/slopgate-agent.service"
      local b="${unit_dir}/slopgate-balancer.service"
      if [[ -f "${a}" ]] && [[ ! -f "${b}" ]] \
        && grep -q "^EnvironmentFile=${env_file}$" "${a}" \
        && grep -q -- '--management-addr ${SLOPGATE_LEADER_MANAGEMENT_ADDR}' "${a}" \
        && grep -q -- '--external-llamacpp-addr ${SLOPGATE_EXTERNAL_LLAMACPP_ADDR}' "${a}" \
        && grep -q -- '--max-context ${SLOPGATE_MAX_CONTEXT}' "${a}" \
        && grep -q -- '--model-alias ${SLOPGATE_MODEL_ALIAS}' "${a}" \
        && grep -q -- '--name ${SLOPGATE_AGENT_NAME}' "${a}" \
        && ! grep -q -- '--slots' "${a}" \
        && ! grep -q -- '--audio-llamacpp-addr' "${a}"; then
        echo "PASS: follower agent unit sources ${env_file} (no balancer unit installed)"
      else
        echo "FAIL: follower unit missing expected fields"
        cat "${a}" 2>/dev/null
        return 1
      fi
      ;;
    *)
      echo "SKIP: follower install (unsupported platform)"
      ;;
  esac
}

test_install_refuses_without_env_file() {
  echo "TEST: install scripts refuse to run without an env file"
  local home_dir="${TMPDIR}/no-env"
  mkdir -p "${home_dir}"
  local out
  out="$(
    HOME="${home_dir}" \
    INSTALL_DRY_RUN=true \
    SLOPGATE_BIN="${fake_bin}/slopgate" \
    bash "${REPO_ROOT}/scripts/install_slopgate_leader.sh" 2>&1 || true
  )"
  if [[ "${out}" == *"missing"* && "${out}" == *"leader.env"* ]]; then
    echo "PASS: leader installer requires the env file"
  else
    echo "FAIL: leader installer did not refuse a missing env file"
    echo "${out}"
    return 1
  fi
}

test_env_examples_present() {
  echo "TEST: config/slopgate/{leader,follower}.env.example are tracked"
  local lex="${REPO_ROOT}/config/slopgate/leader.env.example"
  local fex="${REPO_ROOT}/config/slopgate/follower.env.example"
  if [[ -f "${lex}" && -f "${fex}" ]]; then
    echo "PASS: env example templates present"
  else
    echo "FAIL: missing env example templates"
    return 1
  fi
}

test_gitignore_blocks_env_files() {
  echo "TEST: .gitignore catches *.env but not *.env.example"
  cd "${REPO_ROOT}"
  local probe_real="${REPO_ROOT}/config/slopgate/_probe.env"
  local probe_example="${REPO_ROOT}/config/slopgate/_probe.env.example"
  : > "${probe_real}"
  : > "${probe_example}"
  local real_rc=0 example_rc=0
  git check-ignore -q "${probe_real}"    || real_rc=$?
  git check-ignore -q "${probe_example}" || example_rc=$?
  rm -f "${probe_real}" "${probe_example}"
  if [[ "${real_rc}" -eq 0 && "${example_rc}" -eq 1 ]]; then
    echo "PASS: *.env ignored, *.env.example tracked"
  else
    echo "FAIL: gitignore did not behave as expected (real_rc=${real_rc} example_rc=${example_rc})"
    return 1
  fi
}

test_leader_install_dry_run         || FAILED=$((FAILED + 1))
test_follower_install_dry_run       || FAILED=$((FAILED + 1))
test_install_refuses_without_env_file || FAILED=$((FAILED + 1))
test_env_examples_present           || FAILED=$((FAILED + 1))
test_gitignore_blocks_env_files     || FAILED=$((FAILED + 1))

if [[ "${FAILED}" -gt 0 ]]; then
  echo "${FAILED} test(s) failed"
  exit 1
fi
echo "all slopgate profile tests passed"
