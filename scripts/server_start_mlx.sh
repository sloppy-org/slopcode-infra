#!/usr/bin/env bash
# Start one mlx_lm.server instance for the exclusive-big-model Mac.
#
# Single slot by design: one large model, one active request. The model is
# resolved from the MLX registry (scripts/mlx_models.py); the sampler defaults
# come from the same table. Binds 127.0.0.1:8090 so the slopgate balancer keeps
# :8080 and a static-slot agent fronts this server.
#
# Env overrides:
#   MLX_VENV          venv with mlx-lm (default ~/.venvs/mlx-lm)
#   MLX_MODEL_ALIAS   registry alias (default: blessed default)
#   MLX_MODEL_ARG     explicit --model value (else resolved from the alias)
#   MLX_HOST          bind host (default 127.0.0.1)
#   MLX_PORT          listen port (default 8090)
#   MLX_MAX_TOKENS    per-request output cap (default 32768)
#   MLX_PROMPT_CACHE_SIZE   prompt cache entries (default 2)
#   MLX_PROMPT_CACHE_BYTES  prompt cache byte cap (default 34359738368 = 32 GiB)
#   MLX_EXEC          true to exec mlx_lm.server in the foreground (launchd
#                     ExecStart); skips pid files, readiness polling, smoke test.
#   MLX_DRY_RUN       true to print the command and exit
#   MLX_SMOKE_TEST    false to skip the post-start /v1/chat/completions probe
#
# Note: this mlx-lm has no --max-kv-size; KV grows with context. Single-slot
# plus the 248 GiB wired limit keeps a 128K session inside budget, but a runaway
# unbounded session is the documented mlx_lm.server OOM/panic risk
# (ml-explore/mlx-lm#883). MLX_MAX_TOKENS caps per-request output; keep agent
# harness context bounded.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "server_start_mlx.sh is macOS only"

MLX_VENV="${MLX_VENV:-${HOME}/.venvs/mlx-lm}"
SERVER_BIN="${MLX_VENV}/bin/mlx_lm.server"
[[ -x "${SERVER_BIN}" ]] || die "mlx_lm.server not found at ${SERVER_BIN}. Run: scripts/setup_mlx.sh"

MODELS_SCRIPT="${SCRIPT_DIR}/mlx_models.py"
DEFAULT_ALIAS="$(python3 "${MODELS_SCRIPT}" default-alias)"
MODEL_ALIAS="${MLX_MODEL_ALIAS:-${DEFAULT_ALIAS}}"

MODEL_ARG="${MLX_MODEL_ARG:-}"
if [[ -z "${MODEL_ARG}" ]]; then
  if ! MODEL_ARG="$(python3 "${MODELS_SCRIPT}" resolve "${MODEL_ALIAS}")"; then
    die "model for alias ${MODEL_ALIAS} not on disk. Run: python3 ${MODELS_SCRIPT} prefetch ${MODEL_ALIAS}"
  fi
fi

HOST="${MLX_HOST:-127.0.0.1}"
PORT="${MLX_PORT:-8090}"
MAX_TOKENS="${MLX_MAX_TOKENS:-32768}"
PROMPT_CACHE_SIZE="${MLX_PROMPT_CACHE_SIZE:-2}"
PROMPT_CACHE_BYTES="${MLX_PROMPT_CACHE_BYTES:-34359738368}"

read -r -a SAMPLER_ARGS <<< "$(python3 "${MODELS_SCRIPT}" sampler "${MODEL_ALIAS}")"

CMD=(
  "${SERVER_BIN}"
  --model "${MODEL_ARG}"
  --host "${HOST}"
  --port "${PORT}"
  --trust-remote-code
  --max-tokens "${MAX_TOKENS}"
  --prompt-concurrency 1
  --decode-concurrency 1
  --prompt-cache-size "${PROMPT_CACHE_SIZE}"
  --prompt-cache-bytes "${PROMPT_CACHE_BYTES}"
  "${SAMPLER_ARGS[@]}"
)

echo "starting mlx_lm.server"
echo "- server:  ${SERVER_BIN}"
echo "- mlx-lm:  $("${MLX_VENV}/bin/python" -c 'import mlx_lm;print(mlx_lm.__version__)' 2>/dev/null || echo unknown)"
echo "- model:   ${MODEL_ARG} (alias ${MODEL_ALIAS})"
echo "- bind:    ${HOST}:${PORT}"
echo "- slots:   1 (prompt+decode concurrency 1)"
echo "- max out: ${MAX_TOKENS}"

if [[ "${MLX_DRY_RUN:-false}" == "true" ]]; then
  printf '%q ' "${CMD[@]}"
  echo
  exit 0
fi

PID_FILE="${RUN_DIR}/mlx.pid"
PORT_FILE="${RUN_DIR}/mlx.port"
LOG_FILE="${LOG_DIR}/mlx.log"

# Foreground mode for launchd ExecStart: replace the shell so launchd tracks
# the real process and owns the restart policy.
if [[ "${MLX_EXEC:-false}" == "true" ]]; then
  exec "${CMD[@]}"
fi

("${CMD[@]}" >"${LOG_FILE}" 2>&1) &
SERVER_PID=$!
disown "${SERVER_PID}" 2>/dev/null || true
echo "${SERVER_PID}" > "${PID_FILE}"
echo "${PORT}" > "${PORT_FILE}"
echo "- pid:     ${SERVER_PID}"
echo "- log:     ${LOG_FILE}"

START_TIMEOUT="${MLX_START_TIMEOUT:-1800}"
echo "waiting for mlx_lm.server readiness (model load is slow; timeout ${START_TIMEOUT}s)..."
deadline=$(( $(date +%s) + START_TIMEOUT ))
while : ; do
  if curl -fsS -m 5 "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
    echo "server ready on http://${HOST}:${PORT}/v1"
    break
  fi
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    [[ -f "${LOG_FILE}" ]] && tail -n 40 "${LOG_FILE}" >&2 || true
    die "mlx_lm.server exited before becoming ready"
  fi
  [[ $(date +%s) -ge ${deadline} ]] && die "timed out waiting for mlx_lm.server"
  sleep 3
done

if [[ "${MLX_SMOKE_TEST:-true}" == "true" ]]; then
  echo "running chat smoke test..."
  body="$(mktemp /tmp/mlx-smoke.XXXXXX)"
  status="$(curl -sS -o "${body}" -w '%{http_code}' -m 120 \
    "http://${HOST}:${PORT}/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"${MODEL_ARG}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly READY.\"}],\"max_tokens\":16}")" \
    || { rm -f "${body}"; die "smoke test request failed"; }
  resp="$(cat "${body}")"; rm -f "${body}"
  [[ "${status}" == 2* ]] || { echo "${resp}" >&2; die "smoke test failed with HTTP ${status}"; }
  [[ "${resp}" == *'"content"'* ]] || { echo "${resp}" >&2; die "smoke test returned no completion"; }
  echo "smoke test OK"
fi
