#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo "       slopcode-infra Test Suite"
echo "========================================"

FAILED=0
run_test() {
  local name="$1" script="$2"
  echo "---- ${name} ----"
  if bash "${script}"; then
    echo
  else
    echo "FAILED: ${name}"
    FAILED=1
  fi
}

run_test "llama.cpp Profile" "${SCRIPT_DIR}/test_llamacpp_profile.sh"
run_test "slopgate Profile"  "${SCRIPT_DIR}/test_slopgate_profile.sh"
run_test "Mock Server Health" "${SCRIPT_DIR}/test_server_health.sh"

echo "---- USB Scripts ----"
if bash -n "${SCRIPT_DIR}/../scripts/build_bundle.sh" \
   && bash -n "${SCRIPT_DIR}/../scripts/usb_format.sh" \
   && "${SCRIPT_DIR}/../scripts/build_bundle.sh" --help >/dev/null; then
  echo
else
  echo "FAILED: USB Scripts"
  FAILED=1
fi

echo "========================================"
if [[ "${FAILED}" -eq 0 ]]; then
  echo "All tests passed"
else
  echo "Some tests failed"
fi
echo "========================================"
exit "${FAILED}"
