#!/usr/bin/env bash
# Start the whisper.cpp server with an OpenAI-compatible endpoint at
#   http://${HOST}:${PORT}/v1/audio/transcriptions
# This is the same surface the existing tools/transcribe-memo and slopbox
# expect, so any client that speaks the OpenAI Whisper API works against it.
#
# On Mac the build links Metal automatically; on Linux it uses CUDA or Vulkan
# when the toolkit is present, else CPU+BLAS. The server binds 0.0.0.0 by
# default so the LAN can reach it (e.g. push-to-talk from a second box).
#
# Env overrides:
#   WHISPER_HOME           install dir (default ~/.local/whisper.cpp)
#   WHISPER_SERVER_BIN     explicit whisper-server binary
#   WHISPER_MODEL          model basename (default ggml-large-v3-turbo.bin)
#   WHISPER_MODEL_PATH     explicit model file (overrides WHISPER_MODEL)
#   WHISPER_HOST           bind host (default 0.0.0.0)
#   WHISPER_PORT           listen port (default 8427)
#   WHISPER_LANGUAGE       spoken language (default auto)
#   WHISPER_THREADS        compute threads (default: detect_compute_threads, min 4)
#   WHISPER_INFERENCE_PATH OpenAI path (default /v1/audio/transcriptions)
#   WHISPER_DRY_RUN        true to print the command and exit
#   WHISPER_EXEC           true to exec whisper-server in the foreground
#                          (for launchd ExecStart); skips nohup/pid files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

default_whisper_home() {
  # Prefer the source-tree install (~/code/whisper.cpp) when it has a built
  # server, otherwise fall back to the legacy ~/.local/whisper.cpp path.
  if [[ -x "${HOME}/code/whisper.cpp/build/bin/whisper-server" ]]; then
    echo "${HOME}/code/whisper.cpp"
  elif [[ -x "${HOME}/.local/whisper.cpp/build/bin/whisper-server" ]]; then
    echo "${HOME}/.local/whisper.cpp"
  elif [[ -d "${HOME}/code" ]]; then
    echo "${HOME}/code/whisper.cpp"
  else
    echo "${HOME}/.local/whisper.cpp"
  fi
}
WHISPER_HOME="${WHISPER_HOME:-$(default_whisper_home)}"
WHISPER_SERVER="${WHISPER_SERVER_BIN:-${WHISPER_HOME}/build/bin/whisper-server}"
[[ -x "${WHISPER_SERVER}" ]] || die "whisper-server not built. Run: scripts/setup_whisper.sh"

WHISPER_MODEL="${WHISPER_MODEL:-ggml-large-v3-turbo.bin}"
MODEL_PATH="${WHISPER_MODEL_PATH:-${WHISPER_HOME}/models/${WHISPER_MODEL}}"
[[ -f "${MODEL_PATH}" ]] || die "whisper model missing: ${MODEL_PATH} (run: scripts/setup_whisper.sh)"

HOST="${WHISPER_HOST:-0.0.0.0}"
PORT="${WHISPER_PORT:-8427}"
LANG="${WHISPER_LANGUAGE:-auto}"
INFERENCE_PATH="${WHISPER_INFERENCE_PATH:-/v1/audio/transcriptions}"
THREADS_DEFAULT="$(default_compute_threads)"
[[ "${THREADS_DEFAULT}" -lt 4 ]] && THREADS_DEFAULT=4
THREADS="${WHISPER_THREADS:-${THREADS_DEFAULT}}"

PID_FILE="${RUN_DIR}/whisper-server.pid"
PORT_FILE="${RUN_DIR}/whisper-server.port"
LOG_FILE="${LOG_DIR}/whisper-server.log"

DRY_RUN="${WHISPER_DRY_RUN:-false}"

# Refuse to start if a non-whisper process holds the port; we don't want to
# step on llama-server or anything else.
existing_pids="$(port_listener_pids "${PORT}")"
if [[ -n "${existing_pids}" ]]; then
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    cmd="$(pid_command "${pid}")"
    if [[ "${cmd}" == *"whisper-server"* ]]; then
      echo "stopping existing whisper-server on port ${PORT} (pid ${pid})..."
      stop_pid "${pid}" "whisper-server"
    else
      die "port ${PORT} is occupied by a non-whisper process (pid ${pid}: ${cmd})"
    fi
  done <<< "${existing_pids}"
fi

# GPU is on by default (whisper.cpp's --no-gpu defaults to false). On Mac the
# binary was built with -DGGML_METAL=1 so the encoder runs on the Apple GPU;
# on Linux/CUDA hosts the same binary runs on the discrete GPU. -fa enables
# flash attention (default-on, made explicit so it survives upstream changes).
# --convert lets clients upload arbitrary container formats (m4a, mp3, mp4,
# webm, etc.) and the server reaches for ffmpeg to decode. Voice memos are
# AAC-in-m4a, so this is required for the slopbox path to work without an
# extra conversion step on the caller side.
CMD=(
  "${WHISPER_SERVER}"
  -m "${MODEL_PATH}"
  --host "${HOST}"
  --port "${PORT}"
  -l "${LANG}"
  -t "${THREADS}"
  -fa
  --inference-path "${INFERENCE_PATH}"
  --convert
  # whisper-server writes the ffmpeg-decoded WAV next to its cwd before calling
  # ffmpeg; under launchd cwd is / (read-only), so without an absolute --tmp-dir
  # every transcription fails with "No such file or directory".
  --tmp-dir /tmp
)

echo "starting whisper-server"
echo "- binary:  ${WHISPER_SERVER}"
echo "- model:   ${MODEL_PATH}"
echo "- bind:    ${HOST}:${PORT}"
echo "- path:    ${INFERENCE_PATH}"
echo "- lang:    ${LANG}"
echo "- threads: ${THREADS}"

if [[ "${DRY_RUN}" == "true" ]]; then
  printf '%q ' "${CMD[@]}"
  echo
  exit 0
fi

if [[ "${WHISPER_EXEC:-false}" == "true" ]]; then
  exec "${CMD[@]}"
fi

nohup "${CMD[@]}" >"${LOG_FILE}" 2>&1 &
SERVER_PID=$!
echo "${SERVER_PID}" > "${PID_FILE}"
echo "${PORT}"       > "${PORT_FILE}"
echo "- pid:     ${SERVER_PID}"
echo "- log:     ${LOG_FILE}"

probe_host="${HOST}"
[[ "${probe_host}" == "0.0.0.0" ]] && probe_host="127.0.0.1"
echo "waiting for ${probe_host}:${PORT} (timeout 60s)..."
deadline=$(( $(date +%s) + 60 ))
while : ; do
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    tail -n 40 "${LOG_FILE}" >&2 || true
    die "whisper-server exited before becoming ready"
  fi
  if curl -fsS -m 2 "http://${probe_host}:${PORT}/" >/dev/null 2>&1; then
    break
  fi
  [[ $(date +%s) -ge ${deadline} ]] && die "timed out waiting for whisper-server"
  sleep 1
done
echo "server is ready on http://${probe_host}:${PORT}${INFERENCE_PATH}"
