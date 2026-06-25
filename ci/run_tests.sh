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
run_test "Serve Switch"      "${SCRIPT_DIR}/test_serve_switch.sh"
run_test "GLM RPC Profile"   "${SCRIPT_DIR}/test_glm_rpc_profile.sh"
run_test "exo Profile"       "${SCRIPT_DIR}/test_exo_profile.sh"
run_test "MLX Profile"       "${SCRIPT_DIR}/test_mlx_profile.sh"
run_test "SearXNG Profile"   "${SCRIPT_DIR}/test_searxng_profile.sh"
run_test "Mock Server Health" "${SCRIPT_DIR}/test_server_health.sh"
run_test "Meeting Chunking" "${SCRIPT_DIR}/test_meeting_chunking.sh"

echo "---- Helper Scripts ----"
if bash -n "${SCRIPT_DIR}/../scripts/tts_swap.sh" \
   && TTS_SWAP_DRY_RUN=true bash "${SCRIPT_DIR}/../scripts/tts_swap.sh" free >/dev/null \
   && TTS_SWAP_DRY_RUN=true bash "${SCRIPT_DIR}/../scripts/tts_swap.sh" restore >/dev/null; then
  echo
else
  echo "FAILED: Helper Scripts"
  FAILED=1
fi

echo "---- USB Scripts ----"
if bash -n "${SCRIPT_DIR}/../scripts/build_bundle.sh" \
   && bash -n "${SCRIPT_DIR}/../scripts/usb_format.sh" \
   && "${SCRIPT_DIR}/../scripts/build_bundle.sh" --help >/dev/null; then
  echo
else
  echo "FAILED: USB Scripts"
  FAILED=1
fi

echo "---- Meeting Scripts ----"
if bash -n "${SCRIPT_DIR}/../meeting/record-meeting.sh" \
   && bash -n "${SCRIPT_DIR}/../meeting/meeting-transcribe.sh" \
   && bash -n "${SCRIPT_DIR}/../meeting/meeting-notes.sh" \
   && bash -n "${SCRIPT_DIR}/../meeting/meeting-process.sh" \
   && "${SCRIPT_DIR}/../meeting/meeting-transcribe.sh" --help >/dev/null \
   && "${SCRIPT_DIR}/../meeting/meeting-notes.sh" --help >/dev/null; then
  echo
else
  echo "FAILED: Meeting Scripts"
  FAILED=1
fi

if command -v pwsh >/dev/null 2>&1; then
  echo "---- Meeting PowerShell ----"
  if MEETING_DIR="${SCRIPT_DIR}/../meeting" pwsh -NoProfile -Command '
      $failed=0
      foreach ($f in Get-ChildItem $env:MEETING_DIR -Filter *.ps1) {
        $tokens=$null
        $errs=$null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs) > $null
        if ($errs.Count) {
          $failed=1
          Write-Error "$($f.Name): $($errs | Out-String)"
        }
      }
      exit $failed
    '; then
    echo
  else
    echo "FAILED: Meeting PowerShell"
    FAILED=1
  fi
fi

echo "========================================"
if [[ "${FAILED}" -eq 0 ]]; then
  echo "All tests passed"
else
  echo "Some tests failed"
fi
echo "========================================"
exit "${FAILED}"
