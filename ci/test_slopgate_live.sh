#!/usr/bin/env bash
# Live smoke test for the slopgate Go binary: stitches the mock OpenAI
# server (ci/mock_server.py) and a real slopgate balancer + agent
# together over loopback, then sends a chat completion through the
# balancer. Verifies the x-slopgate-peer attribution header and that
# slot accounting closes out cleanly afterward.
#
# Reuses ci/mock_server.py rather than spinning up llama-server so this
# test runs on any host without a GPU or GGUF on disk.
#
# Env:
#   SLOPGATE_BIN   path to the slopgate binary (default: built from
#                  $HOME/code/sloppy/slopgate/go)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SLOPGATE_SRC="${SLOPGATE_SRC:-${HOME}/code/sloppy/slopgate/go}"
SLOPGATE_BIN_DEFAULT=""

resolve_bin() {
  if [[ -n "${SLOPGATE_BIN:-}" && -x "${SLOPGATE_BIN}" ]]; then
    echo "${SLOPGATE_BIN}"
    return
  fi
  if [[ -d "${SLOPGATE_SRC}" ]]; then
    local out
    out="$(mktemp -d)/slopgate"
    ( cd "${SLOPGATE_SRC}" && go build -o "${out}" ./cmd/slopgate >/dev/null )
    echo "${out}"
    return
  fi
  echo "FAIL: cannot find or build slopgate" >&2
  exit 1
}

BIN="$(resolve_bin)"

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

MOCK_PORT="$(free_port)"
PROXY_PORT="$(free_port)"
MGMT_PORT="$(free_port)"

LOG_DIR="$(mktemp -d)"
MOCK_LOG="${LOG_DIR}/mock.log"
BAL_LOG="${LOG_DIR}/balancer.log"
AGT_LOG="${LOG_DIR}/agent.log"

cleanup() {
  for pid in ${MOCK_PID:-} ${BAL_PID:-} ${AGT_PID:-}; do
    kill "${pid}" 2>/dev/null || true
  done
}
trap cleanup EXIT

python3 "${SCRIPT_DIR}/mock_server.py" --port "${MOCK_PORT}" >"${MOCK_LOG}" 2>&1 &
MOCK_PID=$!

for _ in $(seq 1 20); do
  if curl -fsS "http://127.0.0.1:${MOCK_PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

"${BIN}" balancer \
  --management-addr "127.0.0.1:${MGMT_PORT}" \
  --reverseproxy-addr "127.0.0.1:${PROXY_PORT}" \
  >"${BAL_LOG}" 2>&1 &
BAL_PID=$!

for _ in $(seq 1 20); do
  if nc -z 127.0.0.1 "${MGMT_PORT}" 2>/dev/null && nc -z 127.0.0.1 "${PROXY_PORT}" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

"${BIN}" agent \
  --local-llamacpp-addr "127.0.0.1:${MOCK_PORT}" \
  --management-addr "127.0.0.1:${MGMT_PORT}" \
  --name leader \
  --model-alias mock-model \
  --max-context 4096 \
  --monitoring-interval 1 \
  --slots 2 \
  >"${AGT_LOG}" 2>&1 &
AGT_PID=$!

registered=0
for _ in $(seq 1 50); do
  body="$(curl -fsS "http://127.0.0.1:${MGMT_PORT}/api/v1/agents" 2>/dev/null || true)"
  if echo "${body}" | grep -q '"agent_name":"leader"'; then
    registered=1
    break
  fi
  sleep 0.2
done

if [[ "${registered}" -ne 1 ]]; then
  echo "FAIL: agent did not register"
  echo "--- balancer ---"; cat "${BAL_LOG}"
  echo "--- agent ---"; cat "${AGT_LOG}"
  exit 1
fi

response_file="$(mktemp)"
header_file="$(mktemp)"
curl -fsS -D "${header_file}" \
  -H 'content-type: application/json' \
  -H 'x-session-affinity: live-smoke' \
  "http://127.0.0.1:${PROXY_PORT}/v1/chat/completions" \
  -d '{"model":"mock-model","max_tokens":8,"messages":[{"role":"user","content":"hello"}]}' \
  > "${response_file}"

if ! grep -iq '^x-slopgate-peer: leader' "${header_file}"; then
  echo "FAIL: response missing x-slopgate-peer: leader"
  cat "${header_file}"
  exit 1
fi
echo "PASS: x-slopgate-peer header attributes the served peer"

if ! grep -q '"choices"' "${response_file}"; then
  echo "FAIL: response body missing choices"
  cat "${response_file}"
  exit 1
fi
echo "PASS: response body forwarded from mock upstream"

# Slot accounting should release after the completion.
final="$(curl -fsS "http://127.0.0.1:${MGMT_PORT}/api/v1/agents")"
if ! echo "${final}" | grep -q '"slots_taken":0'; then
  echo "FAIL: slots_taken did not return to 0"
  echo "${final}"
  exit 1
fi
echo "PASS: slot reservation released after completion"

if ! echo "${final}" | grep -q '"completed_requests":1'; then
  echo "FAIL: completed_requests not incremented"
  echo "${final}"
  exit 1
fi
echo "PASS: completed_requests=1 recorded"

echo "all slopgate live tests passed"
