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

# A fake bin dir with ioreg/sysctl/curl driven by env, prepended to PATH.
make_fakes() {
  FIX="$(mktemp -d)"
  cat >"${FIX}/ioreg" <<'SH'
#!/usr/bin/env bash
echo "    \"HIDIdleTime\" = ${HID_NS:-0}"
SH
  cat >"${FIX}/sysctl" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
  vm.loadavg) echo "{ ${FAKE_LOAD:-0.10} 0.0 0.0 }" ;;
  hw.physicalcpu) echo "${FAKE_CORES:-10}" ;;
  hw.memsize) echo "0" ;;
  *) echo "0" ;;
esac
SH
  cat >"${FIX}/curl" <<'SH'
#!/usr/bin/env bash
printf '%s' "${FAKE_METRICS:-}"
SH
  chmod +x "${FIX}"/*
}

run_check() {
  local rundir="$1"
  PATH="${FIX}:${PATH}" RUN_DIR="${rundir}" GLM_IDLE_REMOTE=false \
    bash "${IDLE}" check >/dev/null 2>&1
  echo $?
}

test_busy_when_active_input() {
  echo "TEST: busy while a human is at the keyboard (low HID idle)"
  local rd rc; rd="$(mktemp -d)"
  rc="$(HID_NS=1000000000 FAKE_LOAD=0.1 FAKE_CORES=10 IDLE_SECONDS=1800 run_check "$rd")"
  if [[ "$rc" == 1 ]]; then pass; else fail "rc=$rc"; fi
}

test_busy_when_load_high() {
  echo "TEST: busy when a compute job keeps load above the per-core fraction"
  local rd rc; rd="$(mktemp -d)"
  rc="$(HID_NS=99000000000000 FAKE_LOAD=8.0 FAKE_CORES=10 IDLE_SECONDS=0 run_check "$rd")"
  if [[ "$rc" == 1 ]]; then pass; else fail "rc=$rc"; fi
}

test_busy_when_slopgate_serving() {
  echo "TEST: busy when slopgate reports an active agent slot"
  local rd rc; rd="$(mktemp -d)"
  rc="$(HID_NS=99000000000000 FAKE_LOAD=0.1 FAKE_CORES=10 IDLE_SECONDS=0 \
        FAKE_METRICS=$'slopgate_agent_slots_active 2\n' run_check "$rd")"
  if [[ "$rc" == 1 ]]; then pass; else fail "rc=$rc"; fi
}

test_idle_sustained() {
  echo "TEST: idle when input long-gone, load low, slopgate quiet, sustained"
  local rd rc; rd="$(mktemp -d)"
  rc="$(HID_NS=99000000000000 FAKE_LOAD=0.2 FAKE_CORES=10 IDLE_SECONDS=0 run_check "$rd")"
  if [[ "$rc" == 0 ]]; then pass; else fail "rc=$rc"; fi
}

test_settle_window_holds() {
  echo "TEST: with a settle window, instantaneous idle does not fire on the first tick"
  local rd rc; rd="$(mktemp -d)"
  rc="$(HID_NS=99000000000000 FAKE_LOAD=0.2 FAKE_CORES=10 IDLE_SECONDS=0 GLM_IDLE_SETTLE=3600 run_check "$rd")"
  if [[ "$rc" == 1 ]]; then pass; else fail "rc=$rc"; fi
}

test_since_file_resets_on_busy() {
  echo "TEST: the idle-since marker is cleared as soon as the cluster is busy"
  local rd; rd="$(mktemp -d)"
  HID_NS=99000000000000 FAKE_LOAD=0.2 FAKE_CORES=10 IDLE_SECONDS=1800 GLM_IDLE_SETTLE=3600 run_check "$rd" >/dev/null
  if [[ ! -f "${rd}/glm-idle-since" ]]; then fail "since-file not written while settling"; return; fi
  HID_NS=1000000000 FAKE_LOAD=0.2 FAKE_CORES=10 IDLE_SECONDS=1800 GLM_IDLE_SETTLE=3600 run_check "$rd" >/dev/null
  if [[ -f "${rd}/glm-idle-since" ]]; then fail "since-file survived a busy tick"; return; fi
  pass
}

test_stale_since_reset() {
  echo "TEST: a future/stale idle-since marker is reset, not treated as long-settled"
  local rd rc since; rd="$(mktemp -d)"
  echo "9999999999" >"${rd}/glm-idle-since"   # far future -> stale
  rc="$(HID_NS=99000000000000 FAKE_LOAD=0.2 FAKE_CORES=10 IDLE_SECONDS=0 GLM_IDLE_SETTLE=3600 run_check "$rd")"
  since="$(cat "${rd}/glm-idle-since")"
  if [[ "$rc" == 1 && "$since" != 9999999999 ]]; then pass; else fail "rc=$rc since=$since"; fi
}

make_fakes
test_busy_when_active_input     || FAILED=$((FAILED + 1))
test_busy_when_load_high        || FAILED=$((FAILED + 1))
test_busy_when_slopgate_serving || FAILED=$((FAILED + 1))
test_idle_sustained             || FAILED=$((FAILED + 1))
test_settle_window_holds        || FAILED=$((FAILED + 1))
test_since_file_resets_on_busy  || FAILED=$((FAILED + 1))
test_stale_since_reset          || FAILED=$((FAILED + 1))
rm -rf "${FIX}"

if [[ "${FAILED}" -gt 0 ]]; then echo "${FAILED} glm_idle test(s) failed"; exit 1; fi
echo "all glm_idle tests passed"
