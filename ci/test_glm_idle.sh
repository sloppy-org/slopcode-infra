#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IDLE="${REPO_ROOT}/scripts/glm_idle.sh"

bash -n "${IDLE}" || { echo "FAIL: glm_idle.sh syntax"; exit 1; }

FAILED=0
FIX=""
pass() { echo PASS; }
fail() { echo "FAIL: $*"; return 1; }

# Fake bin dir: ps/sysctl/curl/ssh/ping driven by env, prepended to PATH.
make_fakes() {
  FIX="$(mktemp -d)"
  cat >"${FIX}/ps" <<'SH'
#!/usr/bin/env bash
echo "%CPU COMMAND"
printf '%s\n' "${FAKE_PS:-0 idle}"
SH
  cat >"${FIX}/sysctl" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
  vm.swapusage) echo "total = 8192.00M  used = ${FAKE_SWAP:-0}.00M  free = 100.00M  (encrypted)" ;;
  kern.boottime) echo "{ sec = ${FAKE_BOOT:-1} , usec = 0 } fake" ;;
  hw.physicalcpu) echo "${FAKE_CORES:-28}" ;;
  *) echo "0" ;;
esac
SH
  cat >"${FIX}/curl" <<'SH'
#!/usr/bin/env bash
printf '%s' "${FAKE_METRICS:-}"
SH
  cat >"${FIX}/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${FAKE_R_CPU:-0}" "${FAKE_R_SWAP:-0}"
SH
  printf '#!/usr/bin/env bash\nexit 0\n' >"${FIX}/ping"
  chmod +x "${FIX}"/*
}

run_check() {
  local rundir="$1"
  PATH="${FIX}:${PATH}" RUN_DIR="${rundir}" GLM_SSH_BIN="${FIX}/ssh" bash "${IDLE}" check >/dev/null 2>&1
  echo $?
}

test_busy_when_nonglm_cpu_high() {
  echo "TEST: busy when a non-GLM job uses significant CPU"
  local rd rc; rd="$(mktemp -d)"
  rc="$(FAKE_PS=$'800.0 clang++ -O2 build.cpp\n3.0 -zsh' GLM_IDLE_REMOTE=false IDLE_SECONDS=0 run_check "$rd")"
  if [[ "$rc" == 1 ]]; then pass; else fail "rc=$rc"; fi
}

test_glm_cpu_does_not_count() {
  echo "TEST: GLM's own CPU (exo/mlx) does not make the host busy"
  local rd rc; rd="$(mktemp -d)"
  rc="$(FAKE_PS=$'1800.0 /Users/ert/code/exo/.venv/bin/exo --api-port 52415\n900.0 mlx ring worker\n4.0 -zsh' GLM_IDLE_REMOTE=false IDLE_SECONDS=0 run_check "$rd")"
  if [[ "$rc" == 0 ]]; then pass; else fail "rc=$rc"; fi
}

test_interactive_agents_are_idle() {
  echo "TEST: chatting with an agent (low-CPU claude/codex/tmux) stays idle"
  local rd rc; rd="$(mktemp -d)"
  rc="$(FAKE_PS=$'12.0 claude\n8.0 codex\n1.0 tmux\n0.5 sshd' GLM_IDLE_REMOTE=false IDLE_SECONDS=0 run_check "$rd")"
  if [[ "$rc" == 0 ]]; then pass; else fail "rc=$rc"; fi
}

test_busy_when_swap_high() {
  echo "TEST: busy when swap (memory pressure beyond GLM) is high"
  local rd rc; rd="$(mktemp -d)"
  rc="$(FAKE_PS=$'2.0 -zsh' FAKE_SWAP=9000 GLM_IDLE_REMOTE=false IDLE_SECONDS=0 run_check "$rd")"
  if [[ "$rc" == 1 ]]; then pass; else fail "rc=$rc"; fi
}

test_busy_when_slopgate_serving() {
  echo "TEST: busy when slopgate reports an active agent slot"
  local rd rc; rd="$(mktemp -d)"
  rc="$(FAKE_PS=$'2.0 -zsh' FAKE_METRICS=$'slopgate_agent_slots_active 2\n' GLM_IDLE_REMOTE=false IDLE_SECONDS=0 run_check "$rd")"
  if [[ "$rc" == 1 ]]; then pass; else fail "rc=$rc"; fi
}

test_idle_when_quiet_sustained() {
  echo "TEST: idle when both hosts quiet, slopgate quiet, held long enough"
  local rd rc; rd="$(mktemp -d)"
  rc="$(FAKE_PS=$'5.0 -zsh' GLM_IDLE_REMOTE=false IDLE_SECONDS=0 run_check "$rd")"
  if [[ "$rc" == 0 ]]; then pass; else fail "rc=$rc"; fi
}

test_settle_window_holds() {
  echo "TEST: quiet does not fire until held IDLE_SECONDS"
  local rd rc; rd="$(mktemp -d)"
  rc="$(FAKE_PS=$'5.0 -zsh' GLM_IDLE_REMOTE=false IDLE_SECONDS=3600 run_check "$rd")"
  if [[ "$rc" == 1 ]]; then pass; else fail "rc=$rc"; fi
}

test_since_file_resets_on_busy() {
  echo "TEST: the idle-since marker is cleared as soon as the cluster is busy"
  local rd; rd="$(mktemp -d)"
  FAKE_PS=$'5.0 -zsh' GLM_IDLE_REMOTE=false IDLE_SECONDS=3600 run_check "$rd" >/dev/null
  if [[ ! -f "${rd}/glm-idle-since" ]]; then fail "since-file not written while settling"; return; fi
  FAKE_PS=$'800.0 clang' GLM_IDLE_REMOTE=false IDLE_SECONDS=3600 run_check "$rd" >/dev/null
  if [[ -f "${rd}/glm-idle-since" ]]; then fail "since-file survived a busy tick"; return; fi
  pass
}

test_stale_since_reset() {
  echo "TEST: a future idle-since marker is reset, not treated as long-held"
  local rd rc since; rd="$(mktemp -d)"
  echo "9999999999" >"${rd}/glm-idle-since"
  rc="$(FAKE_PS=$'5.0 -zsh' GLM_IDLE_REMOTE=false IDLE_SECONDS=3600 run_check "$rd")"
  since="$(cat "${rd}/glm-idle-since")"
  if [[ "$rc" == 1 && "$since" != 9999999999 ]]; then pass; else fail "rc=$rc since=$since"; fi
}

test_preboot_since_reset() {
  echo "TEST: an idle-since marker predating this boot is reset (boottime parse)"
  local rd rc since; rd="$(mktemp -d)"
  echo "1000" >"${rd}/glm-idle-since"
  rc="$(FAKE_PS=$'5.0 -zsh' FAKE_BOOT=2000000000 GLM_IDLE_REMOTE=false IDLE_SECONDS=3600 run_check "$rd")"
  since="$(cat "${rd}/glm-idle-since")"
  if [[ "$rc" == 1 && "$since" != 1000 ]]; then pass; else fail "rc=$rc since=$since"; fi
}

test_remote_busy_makes_cluster_busy() {
  echo "TEST: faepmac2 busy (over TB) makes the cluster busy"
  local rd rc; rd="$(mktemp -d)"
  rc="$(FAKE_PS=$'2.0 -zsh' FAKE_R_CPU=900 FAKE_R_SWAP=0 GLM_IDLE_REMOTE=true IDLE_SECONDS=0 run_check "$rd")"
  if [[ "$rc" == 1 ]]; then pass; else fail "rc=$rc"; fi
}

test_remote_idle_ok() {
  echo "TEST: faepmac2 quiet (over TB) lets the cluster be idle"
  local rd rc; rd="$(mktemp -d)"
  rc="$(FAKE_PS=$'2.0 -zsh' FAKE_R_CPU=6 FAKE_R_SWAP=0 GLM_IDLE_REMOTE=true IDLE_SECONDS=0 run_check "$rd")"
  if [[ "$rc" == 0 ]]; then pass; else fail "rc=$rc"; fi
}

make_fakes
test_busy_when_nonglm_cpu_high    || FAILED=$((FAILED + 1))
test_glm_cpu_does_not_count       || FAILED=$((FAILED + 1))
test_interactive_agents_are_idle  || FAILED=$((FAILED + 1))
test_busy_when_swap_high          || FAILED=$((FAILED + 1))
test_busy_when_slopgate_serving   || FAILED=$((FAILED + 1))
test_idle_when_quiet_sustained    || FAILED=$((FAILED + 1))
test_settle_window_holds          || FAILED=$((FAILED + 1))
test_since_file_resets_on_busy    || FAILED=$((FAILED + 1))
test_stale_since_reset            || FAILED=$((FAILED + 1))
test_preboot_since_reset          || FAILED=$((FAILED + 1))
test_remote_busy_makes_cluster_busy || FAILED=$((FAILED + 1))
test_remote_idle_ok               || FAILED=$((FAILED + 1))
rm -rf "${FIX}"

if [[ "${FAILED}" -gt 0 ]]; then echo "${FAILED} glm_idle test(s) failed"; exit 1; fi
echo "all glm_idle tests passed"
