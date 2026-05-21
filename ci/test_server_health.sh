#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Pick a free port instead of hardcoding one — the dev box already runs
# unrelated services (e.g. slopsearch on 18080) and the mock server has
# nothing fixed about its port.
if [[ -z "${MOCK_PORT:-}" ]]; then
  MOCK_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
fi
MOCK_PID=""

cleanup() {
  if [[ -n "${MOCK_PID}" ]]; then
    kill "${MOCK_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

start_mock_server() {
  python3 "${SCRIPT_DIR}/mock_server.py" --port "${MOCK_PORT}" &
  MOCK_PID=$!
  # Poll the port until it actually listens (up to 10 s). The fixed
  # sleep 1 used to fail under heavy disk/network load when python
  # took longer than a second to start serving.
  local deadline=$(( $(date +%s) + 10 ))
  while ! curl -sf -o /dev/null --max-time 1 "http://127.0.0.1:${MOCK_PORT}/health"; do
    if ! kill -0 "${MOCK_PID}" 2>/dev/null; then
      echo "FAIL: mock server failed to start"
      exit 1
    fi
    [[ $(date +%s) -ge ${deadline} ]] && { echo "FAIL: mock server did not become ready"; exit 1; }
    sleep 0.2
  done
}

test_health_endpoint() {
  echo "TEST: /health endpoint"
  local response
  response="$(curl -s "http://127.0.0.1:${MOCK_PORT}/health")"
  if echo "${response}" | grep -q '"status"'; then
    echo "PASS: /health returns status"
  else
    echo "FAIL: /health missing status field"
    echo "Response: ${response}"
    return 1
  fi
}

test_models_endpoint() {
  echo "TEST: /v1/models endpoint"
  local response
  response="$(curl -s "http://127.0.0.1:${MOCK_PORT}/v1/models")"
  if echo "${response}" | grep -q '"data"'; then
    echo "PASS: /v1/models returns data"
  else
    echo "FAIL: /v1/models missing data field"
    echo "Response: ${response}"
    return 1
  fi
}

test_chat_completions() {
  echo "TEST: /v1/chat/completions endpoint"
  local response
  response="$(curl -s "http://127.0.0.1:${MOCK_PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"mock","messages":[{"role":"user","content":"Hello"}]}')"
  if echo "${response}" | grep -q '"choices"'; then
    echo "PASS: /v1/chat/completions returns choices"
  else
    echo "FAIL: /v1/chat/completions missing choices field"
    echo "Response: ${response}"
    return 1
  fi
}

echo "=== Mock Server Health Tests ==="
start_mock_server

FAILED=0
test_health_endpoint || FAILED=1
test_models_endpoint || FAILED=1
test_chat_completions || FAILED=1

echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  echo "All tests passed"
  exit 0
else
  echo "Some tests failed"
  exit 1
fi
