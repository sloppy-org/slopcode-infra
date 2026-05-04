#!/usr/bin/env bash
# Install macOS launchd user agents for the slopcode llama.cpp deployment
# plus the whisper.cpp transcription server:
#   com.slopcode.llamacpp        -> 35B-A3B Q4 (MoE) on 0.0.0.0:8080 with
#                                    -np 4 -c 2097152 (512K per slot)
#   com.slopcode.whisper-server  -> ggml-large-v3-turbo on 0.0.0.0:8427
#                                    OpenAI-compat at /v1/audio/transcriptions
#
# Each agent sets KeepAlive=true and RunAtLoad=true so the servers come up on
# login and restart on crash. Legacy dual-instance + devstral-named labels
# (com.slopcode.llamacpp-{27b,35b-a3b}, com.devstral.llamacpp-*,
# com.qwenstack.llamacpp, com.slopcode.llamacpp-macbook) are booted out first.
#
# Env overrides:
#   LLAMACPP_SERVER_BIN  llama-server path (default: ~/.local/llama.cpp/
#                        llama-server, falling back to PATH).
#   WHISPER_SERVER_BIN   whisper-server path (default: ~/.local/whisper.cpp/
#                        build/bin/whisper-server).
#   WHISPER_MODEL_PATH   whisper model file (default:
#                        ~/.local/whisper.cpp/models/ggml-large-v3-turbo.bin).
#   SKIP_WHISPER         set to true to install only the llama agents.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "install_mac_launchagents.sh is macOS only"

MODELS_SCRIPT="${SCRIPT_DIR}/llamacpp_models.py"
AGENTS_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR_ABS="${RUN_DIR}"
mkdir -p "${AGENTS_DIR}" "${LOG_DIR_ABS}"

SERVER_BIN="${LLAMACPP_SERVER_BIN:-}"
if [[ -z "${SERVER_BIN}" ]]; then
  if ! SERVER_BIN="$(resolve_llamacpp_server_bin)"; then
    die "llama-server not found. Run scripts/setup_llamacpp.sh or set LLAMACPP_SERVER_BIN"
  fi
fi
[[ -x "${SERVER_BIN}" ]] || die "not executable: ${SERVER_BIN}"
SERVER_DIR="$(cd "$(dirname "${SERVER_BIN}")" && pwd)"
REASONING_BUDGET="${LLAMACPP_REASONING_BUDGET:-$(default_reasoning_budget)}"

resolve_model() {
  local alias="$1" path
  path="$(python3 "${MODELS_SCRIPT}" resolve "${alias}" 2>/dev/null || true)"
  [[ -n "${path}" && -f "${path}" ]] || die "model for alias ${alias} not on disk. Run: python3 ${MODELS_SCRIPT} prefetch ${alias}"
  echo "${path}"
}

resolve_mmproj_optional() {
  local alias="$1" path
  path="$(python3 "${MODELS_SCRIPT}" resolve-mmproj "${alias}" 2>/dev/null || true)"
  if [[ -n "${path}" && -f "${path}" ]]; then
    echo "${path}"
  fi
}

MODEL_PATH="$(resolve_model qwen3.6-35b-a3b-q4)"
MMPROJ_PATH="$(resolve_mmproj_optional qwen3.6-35b-a3b-q4)"
[[ -n "${MMPROJ_PATH}" ]] || die "mmproj for qwen3.6-35b-a3b-q4 not on disk. Run: python3 ${MODELS_SCRIPT} prefetch qwen3.6-35b-a3b-q4"

bootout_if_loaded() {
  local label="$1" plist="${AGENTS_DIR}/${1}.plist"
  if launchctl list | awk '{print $3}' | grep -qx "${label}"; then
    echo "unloading ${label}"
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || launchctl unload "${plist}" 2>/dev/null || true
  fi
  rm -f "${plist}"
}

# Boot out every previous label this project has shipped, including the dual-
# instance ones (com.slopcode.llamacpp-{27b,35b-a3b}). The new single-instance
# label is com.slopcode.llamacpp.
for legacy in com.qwenstack.llamacpp \
              com.devstral.llamacpp-local \
              com.devstral.llamacpp-macbook \
              com.devstral.llamacpp-35b-a3b \
              com.devstral.llamacpp-27b \
              com.slopcode.llamacpp-local \
              com.slopcode.llamacpp-macbook \
              com.slopcode.llamacpp-27b \
              com.slopcode.llamacpp-35b-a3b; do
  bootout_if_loaded "${legacy}"
done

wait_gone() {
  local label="$1" deadline=$(( $(date +%s) + 10 ))
  while launchctl list | awk '{print $3}' | grep -qx "${label}"; do
    [[ $(date +%s) -ge ${deadline} ]] && return 1
    sleep 1
  done
  return 0
}

# Bind to the loopback when slopgate is locally installed (the proxy fronts
# 0.0.0.0:8080 and llama-server moves to 127.0.0.1:8081); otherwise serve on
# 0.0.0.0:8080 for direct LAN consumers as before.
LLAMACPP_HOST_DEFAULT=0.0.0.0
LLAMACPP_PORT_DEFAULT=8080
if launchctl list 2>/dev/null | awk '{print $3}' | grep -qx 'com.slopcode.slopgate-balancer' \
  || [[ -f "${AGENTS_DIR}/com.slopcode.slopgate-balancer.plist" ]]; then
  LLAMACPP_HOST_DEFAULT=127.0.0.1
  LLAMACPP_PORT_DEFAULT=8081
fi
LLAMACPP_HOST_BIND="${LLAMACPP_HOST:-${LLAMACPP_HOST_DEFAULT}}"
LLAMACPP_PORT_BIND="${LLAMACPP_PORT:-${LLAMACPP_PORT_DEFAULT}}"

write_llamacpp_plist() {
  local label="com.slopcode.llamacpp"
  local plist="${AGENTS_DIR}/${label}.plist"
  local log="${LOG_DIR_ABS}/llamacpp.log"
  local mmproj_xml=""
  if [[ -n "${MMPROJ_PATH}" ]]; then
    mmproj_xml="    <string>--mmproj</string><string>${MMPROJ_PATH}</string>
"
  fi
  cat > "${plist}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProgramArguments</key>
  <array>
    <string>${SERVER_BIN}</string>
    <string>-m</string><string>${MODEL_PATH}</string>
${mmproj_xml}    <string>-c</string><string>2097152</string>
    <string>-b</string><string>2048</string>
    <string>-ub</string><string>1024</string>
    <string>-ngl</string><string>99</string>
    <string>-fa</string><string>on</string>
    <string>-np</string><string>4</string>
    <string>--cache-type-k</string><string>q8_0</string>
    <string>--cache-type-v</string><string>q8_0</string>
    <string>--alias</string><string>qwen</string>
    <string>--jinja</string>
    <string>--temp</string><string>0.6</string>
    <string>--top-p</string><string>0.95</string>
    <string>--top-k</string><string>20</string>
    <string>--min-p</string><string>0</string>
    <string>--presence-penalty</string><string>0.0</string>
    <string>--repeat-penalty</string><string>1.0</string>
    <string>--reasoning-format</string><string>deepseek</string>
    <string>--reasoning-budget</string><string>${REASONING_BUDGET}</string>
    <string>--no-context-shift</string>
    <string>--no-webui</string>
    <string>--host</string><string>${LLAMACPP_HOST_BIND}</string>
    <string>--port</string><string>${LLAMACPP_PORT_BIND}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DYLD_LIBRARY_PATH</key><string>${SERVER_DIR}</string>
  </dict>
  <key>StandardOutPath</key><string>${log}</string>
  <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
XML
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  wait_gone "${label}" || die "failed to unload existing ${label}"
  launchctl bootstrap "gui/$(id -u)" "${plist}"
  if [[ -n "${MMPROJ_PATH}" ]]; then
    echo "loaded ${label} (${LLAMACPP_HOST_BIND}:${LLAMACPP_PORT_BIND}, alias qwen, -np 4 -c 2097152, mmproj $(basename "${MMPROJ_PATH}"))"
  else
    echo "loaded ${label} (${LLAMACPP_HOST_BIND}:${LLAMACPP_PORT_BIND}, alias qwen, -np 4 -c 2097152)"
  fi
}

write_llamacpp_plist

# whisper.cpp transcription server. Runs on Metal GPU (built with
# -DGGML_METAL=1). Used by voxtype dictation, slopbox voice-memo classifier,
# and the meeting-notes pipeline. OpenAI-compatible at /v1/audio/transcriptions
# so any whisper-1 client lib works against it.
write_whisper_plist() {
  local label="com.slopcode.whisper-server"
  local plist="${AGENTS_DIR}/${label}.plist"
  local log="${LOG_DIR_ABS}/whisper-server.log"
  local whisper_default_home="${HOME}/.local/whisper.cpp"
  if [[ -x "${HOME}/code/whisper.cpp/build/bin/whisper-server" ]]; then
    whisper_default_home="${HOME}/code/whisper.cpp"
  fi
  local whisper_bin="${WHISPER_SERVER_BIN:-${whisper_default_home}/build/bin/whisper-server}"
  local model_path="${WHISPER_MODEL_PATH:-${whisper_default_home}/models/ggml-large-v3-turbo.bin}"
  [[ -x "${whisper_bin}" ]] || die "whisper-server not built: ${whisper_bin}. Run: scripts/setup_whisper.sh"
  [[ -f "${model_path}" ]] || die "whisper model missing: ${model_path}. Run: scripts/setup_whisper.sh"
  local whisper_dir
  whisper_dir="$(cd "$(dirname "${whisper_bin}")" && pwd)"
  cat > "${plist}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProgramArguments</key>
  <array>
    <string>${whisper_bin}</string>
    <string>-m</string><string>${model_path}</string>
    <string>--host</string><string>0.0.0.0</string>
    <string>--port</string><string>8427</string>
    <string>-l</string><string>auto</string>
    <string>-fa</string>
    <string>--inference-path</string><string>/v1/audio/transcriptions</string>
    <string>--convert</string>
    <!-- whisper-server writes the ffmpeg-decoded WAV next to its cwd before
         calling ffmpeg; launchd starts agents with cwd=/ which is read-only,
         so without an explicit --tmp-dir every transcription fails with
         "No such file or directory". -->
    <string>--tmp-dir</string><string>/tmp</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DYLD_LIBRARY_PATH</key><string>${whisper_dir}</string>
    <!-- whisper-server shells out to ffmpeg (--convert) to decode m4a/mp3/etc.
         launchd starts agents with a minimal PATH that excludes Homebrew, so
         ffmpeg is unfindable without this. Mirror the user's interactive shell
         path. -->
    <key>PATH</key><string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>${log}</string>
  <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
XML
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  wait_gone "${label}" || die "failed to unload existing ${label}"
  launchctl bootstrap "gui/$(id -u)" "${plist}"
  echo "loaded ${label} (port 8427, model $(basename "${model_path}"))"
}
if [[ "${SKIP_WHISPER:-false}" != "true" ]]; then
  write_whisper_plist
fi

echo
echo "waiting for endpoints (up to 900s each)..."
wait_ready() {
  local port="$1" path="${2:-/v1/models}" deadline=$(( $(date +%s) + 900 ))
  while : ; do
    if curl -fsS -m 2 "http://127.0.0.1:${port}${path}" >/dev/null 2>&1; then
      echo "ready: http://127.0.0.1:${port}${path}"
      return 0
    fi
    # whisper-server has no /v1/models — accept any HTTP response on the
    # inference path (4xx without a body still proves the listener is up).
    if [[ "${path}" == "/v1/audio/transcriptions" ]]; then
      local code
      code="$(curl -sS -m 2 -X POST "http://127.0.0.1:${port}${path}" -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
      if [[ -n "${code}" && "${code}" != "000" ]]; then
        echo "ready: http://127.0.0.1:${port}${path} (HTTP ${code})"
        return 0
      fi
    fi
    [[ $(date +%s) -ge ${deadline} ]] && die "timed out on port ${port}"
    sleep 2
  done
}
wait_ready "${LLAMACPP_PORT_BIND}"
if [[ "${SKIP_WHISPER:-false}" != "true" ]]; then
  wait_ready 8427 /v1/audio/transcriptions
fi
echo "deployment live"
