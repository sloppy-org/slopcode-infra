#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SWITCH="${REPO_ROOT}/scripts/serve_switch.sh"

FAILED=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

DROPIN="${TMPDIR}/wg-only.conf"
ENV_FILE="${TMPDIR}/follower.env"

seed_files() {
  cat > "${DROPIN}" <<'EOF'
[Service]
Environment=LLAMACPP_HOST=10.77.0.10
Environment=LLAMACPP_PORT=8080
Environment=LLAMACPP_CONTEXT=131072
Environment=LLAMACPP_CACHE_ROOT=/mnt/storage/slopcode/models
Environment=LLAMACPP_MODEL_ALIAS=qwen3.6-35b-a3b-mtp-q4
Environment=LLAMACPP_N_CPU_MOE=0
EOF
  cat > "${ENV_FILE}" <<'EOF'
SLOPGATE_LEADER_MANAGEMENT_ADDR=10.77.0.20:8085
SLOPGATE_LOCAL_LLAMACPP_ADDR=10.77.0.10:8080
SLOPGATE_EXTERNAL_LLAMACPP_ADDR=10.77.0.10:8080
SLOPGATE_AGENT_NAME=mailuefterl
SLOPGATE_MAX_CONTEXT=131072
SLOPGATE_MODEL_ALIAS=qwen
SLOPGATE_MACHINE_PROFILE=linux-mailuefterl
SLOPGATE_CANONICAL_MODEL=unsloth/qwen3.6:35b-a3b@128k
SLOPGATE_MODEL_ALIASES=35b,35b@128k,Q4
SLOPGATE_QUANT=UD-Q4_K_XL-MTP
SLOPGATE_DIGEST_EXTRA=kv=q8_0 np=1 b=2048 ub=1024
EOF
}

run_switch() {
  SERVE_SWITCH_DROPIN="${DROPIN}" \
  SERVE_SWITCH_ENV_FILE="${ENV_FILE}" \
  SERVE_SWITCH_DRY_RUN=true \
  SERVE_SWITCH_FORCE=true \
  bash "${SWITCH}" "$@"
}

has() { grep -Fxq "$1" "$2"; }

test_switch_to_27b() {
  echo "TEST: switch 27b stamps both the llama drop-in and the slopgate identity"
  seed_files
  run_switch 27b >/dev/null
  if has 'Environment=LLAMACPP_MODEL_ALIAS=qwen3.6-27b-mtp-q4' "${DROPIN}" \
    && has 'Environment=LLAMACPP_N_CPU_MOE=0' "${DROPIN}" \
    && has 'SLOPGATE_MODEL_ALIAS=qwen27b' "${ENV_FILE}" \
    && has 'SLOPGATE_MODEL_ALIASES=qwen3.6-27b,qwen3.6-27b@128k' "${ENV_FILE}" \
    && has 'SLOPGATE_CANONICAL_MODEL=unsloth/qwen3.6:27b@128k' "${ENV_FILE}" \
    && has 'SLOPGATE_QUANT=UD-Q4_K_XL-MTP' "${ENV_FILE}" \
    && has 'SLOPGATE_AGENT_NAME=mailuefterl' "${ENV_FILE}" \
    && has 'SLOPGATE_EXTERNAL_LLAMACPP_ADDR=10.77.0.10:8080' "${ENV_FILE}" \
    && has 'SLOPGATE_DIGEST_EXTRA=kv=q8_0 np=1 b=2048 ub=1024' "${ENV_FILE}"; then
    echo "PASS: 27b profile applied, host-specific keys preserved"
  else
    echo "FAIL: 27b switch produced unexpected files"
    cat "${DROPIN}" "${ENV_FILE}"
    return 1
  fi
}

test_round_trip_to_35b() {
  echo "TEST: switching back to 35b restores the qwen identity"
  run_switch 35b >/dev/null
  if has 'Environment=LLAMACPP_MODEL_ALIAS=qwen3.6-35b-a3b-mtp-q4' "${DROPIN}" \
    && has 'SLOPGATE_MODEL_ALIAS=qwen' "${ENV_FILE}" \
    && has 'SLOPGATE_MODEL_ALIASES=35b,35b@128k,Q4' "${ENV_FILE}" \
    && has 'SLOPGATE_CANONICAL_MODEL=unsloth/qwen3.6:35b-a3b@128k' "${ENV_FILE}"; then
    echo "PASS: round-trip back to 35b restores qwen"
  else
    echo "FAIL: round-trip did not restore the 35b identity"
    cat "${DROPIN}" "${ENV_FILE}"
    return 1
  fi
}

test_alias_not_clobbered() {
  echo "TEST: SLOPGATE_MODEL_ALIAS and _ALIASES stay distinct (no prefix bleed)"
  # exactly one line each, not a merged/duplicated key
  local n_alias n_aliases
  n_alias="$(grep -c '^SLOPGATE_MODEL_ALIAS=' "${ENV_FILE}")"
  n_aliases="$(grep -c '^SLOPGATE_MODEL_ALIASES=' "${ENV_FILE}")"
  if [[ "${n_alias}" -eq 1 && "${n_aliases}" -eq 1 ]]; then
    echo "PASS: both keys present exactly once"
  else
    echo "FAIL: alias key count off (alias=${n_alias} aliases=${n_aliases})"
    return 1
  fi
}

test_unknown_model_rejected() {
  echo "TEST: unknown model name is rejected"
  seed_files
  if run_switch bogus 2>/dev/null; then
    echo "FAIL: unknown model was accepted"
    return 1
  fi
  echo "PASS: unknown model rejected"
}

test_status_no_arg() {
  echo "TEST: no-arg invocation reports the active profile without editing"
  seed_files
  local out
  out="$(SERVE_SWITCH_DROPIN="${DROPIN}" SERVE_SWITCH_ENV_FILE="${ENV_FILE}" bash "${SWITCH}")"
  if [[ "${out}" == *"qwen3.6-35b-a3b-mtp-q4"* && "${out}" == *"UD-Q4_K_XL-MTP"* ]]; then
    echo "PASS: status prints the active model"
  else
    echo "FAIL: status output unexpected"
    echo "${out}"
    return 1
  fi
}

bash -n "${SWITCH}" || { echo "FAIL: serve_switch.sh has a syntax error"; exit 1; }

test_switch_to_27b          || FAILED=$((FAILED + 1))
test_round_trip_to_35b      || FAILED=$((FAILED + 1))
test_alias_not_clobbered    || FAILED=$((FAILED + 1))
test_unknown_model_rejected || FAILED=$((FAILED + 1))
test_status_no_arg          || FAILED=$((FAILED + 1))

if [[ "${FAILED}" -gt 0 ]]; then
  echo "${FAILED} test(s) failed"
  exit 1
fi
echo "all serve_switch tests passed"
