#!/usr/bin/env bash
# Build a USB-ready slopcode bundle for Linux, macOS, and Windows.
#
# Contents:
#   <target>/llama.cpp/      upstream llama.cpp binary release
#   <target>/opencode/       upstream opencode binary release
#   <target>/whisper.cpp/    whisper source (Linux/macOS) or Windows binaries
#   <target>/install.*       localhost-only user install
#   <target>/start.*         foreground localhost-only launchers
#   models/                  Qwen GGUF, mmproj, ggml-large-v3-turbo.bin
#
# No Pi, no Node, no npm cache. Do not add them here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

have curl || die "curl is required"
have unzip || die "unzip is required"
have tar || die "tar is required"
have python3 || die "python3 is required"

TARGETS=()
OUT=""
LLAMACPP_TAG="${LLAMACPP_TAG:-}"
OPENCODE_TAG="${OPENCODE_TAG:-}"
WHISPER_TAG="${WHISPER_TAG:-}"
SKIP_MODEL="${SKIP_MODEL:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --llamacpp-tag) LLAMACPP_TAG="$2"; shift 2 ;;
    --opencode-tag) OPENCODE_TAG="$2"; shift 2 ;;
    --whisper-tag) WHISPER_TAG="$2"; shift 2 ;;
    --skip-model) SKIP_MODEL=true; shift ;;
    all) TARGETS=(linux-cuda mac-m1 windows-arc); shift ;;
    linux-cuda|mac-m1|windows-arc) TARGETS+=("$1"); shift ;;
    -h|--help) sed -n '1,36p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${OUT}" ]] || die "--out is required"
[[ "${#TARGETS[@]}" -gt 0 ]] || die "target required: linux-cuda|mac-m1|windows-arc|all"
mkdir -p "${OUT}/models"

CURL_OPTS=(-fsSL --connect-timeout 30 --max-time 1800 --retry 3 --retry-delay 5)
if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
  CURL_OPTS+=(-H "Authorization: Bearer ${GITHUB_TOKEN:-${GH_TOKEN:-}}")
fi

github_asset() {
  local repo="$1" tag="$2" suffix="$3"
  local api="https://api.github.com/repos/${repo}/releases"
  local url
  if [[ -n "${tag}" ]]; then
    url="${api}/tags/${tag}"
  else
    url="${api}/latest"
  fi
  curl "${CURL_OPTS[@]}" "${url}" | python3 -c '
import json, sys
suffix = sys.argv[1]
data = json.load(sys.stdin)
for asset in data["assets"]:
    if asset["name"].endswith(suffix):
        print(data["tag_name"], asset["browser_download_url"])
        raise SystemExit(0)
raise SystemExit(1)
' "${suffix}"
}

llama_asset() {
  local flavor="$1"
  local api="https://api.github.com/repos/ggml-org/llama.cpp/releases"
  local url
  if [[ -n "${LLAMACPP_TAG}" ]]; then
    url="${api}/tags/${LLAMACPP_TAG}"
  else
    url="${api}?per_page=20"
  fi
  curl "${CURL_OPTS[@]}" "${url}" | python3 -c '
import json, re, sys
flavor = sys.argv[1]
data = json.load(sys.stdin)
releases = data if isinstance(data, list) else [data]
pat = re.compile(rf"llama-.*-bin-{re.escape(flavor)}\.(zip|tar\.gz)$")
for release in releases:
    for asset in release.get("assets", []):
        if pat.search(asset["name"]):
            print(release["tag_name"], asset["browser_download_url"])
            raise SystemExit(0)
raise SystemExit(1)
' "${flavor}"
}

fetch_archive() {
  local url="$1" dest="$2" marker="${3:-}"
  local tmp inner
  tmp="$(mktemp -d)"
  rm -rf "${dest}"
  mkdir -p "${dest}" "${tmp}/unpacked"
  curl "${CURL_OPTS[@]}" -o "${tmp}/pkg" "${url}"
  case "${url}" in
    *.tar.gz|*.tgz) tar -xzf "${tmp}/pkg" -C "${tmp}/unpacked" ;;
    *.tar.xz)       tar -xJf "${tmp}/pkg" -C "${tmp}/unpacked" ;;
    *.zip)          unzip -q -o "${tmp}/pkg" -d "${tmp}/unpacked" ;;
    *) die "unknown archive: ${url}" ;;
  esac
  if [[ -n "${marker}" ]]; then
    inner="$(find "${tmp}/unpacked" -type f -name "${marker}" -print -quit | xargs -r dirname)"
  else
    inner="$(find "${tmp}/unpacked" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  fi
  [[ -n "${inner}" && -d "${inner}" ]] || inner="${tmp}/unpacked"
  cp -RL "${inner}/." "${dest}/"
  rm -rf "${tmp}"
}

fetch_whisper_source() {
  local dest="$1" tag="$2" url
  rm -rf "${dest}"
  mkdir -p "${dest}"
  if [[ -z "${tag}" ]]; then
    tag="$(curl "${CURL_OPTS[@]}" https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"])')"
  fi
  url="https://github.com/ggml-org/whisper.cpp/archive/refs/tags/${tag}.tar.gz"
  echo "whisper.cpp source ${tag}"
  fetch_archive "${url}" "${dest}"
}

copy_model_alias() {
  local alias="$1" required="$2" primary src_dir
  primary="$(python3 "${SCRIPT_DIR}/llamacpp_models.py" resolve "${alias}" 2>/dev/null || true)"
  if [[ -z "${primary}" || ! -f "${primary}" ]]; then
    [[ "${required}" == true ]] && die "model ${alias} missing; run: python3 scripts/llamacpp_models.py prefetch ${alias}"
    return 0
  fi
  src_dir="$(dirname "${primary}")"
  echo "copying ${alias}"
  find "${src_dir}" -maxdepth 1 -type f -name '*.gguf' -exec cp -n {} "${OUT}/models/" \;
}

copy_models() {
  [[ "${SKIP_MODEL}" == true ]] && return 0
  copy_model_alias qwen3.6-35b-a3b-q4 true
  local model="${OUT}/models/ggml-large-v3-turbo.bin"
  if [[ ! -f "${model}" ]]; then
    echo "downloading whisper large-v3-turbo"
    curl "${CURL_OPTS[@]}" -o "${model}.partial" \
      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
    mv "${model}.partial" "${model}"
  fi
}

write_common_unix_files() {
  local t="$1"
  install -m 755 "${SCRIPT_DIR}/opencode_privacy.sh" "${t}/opencode_privacy.sh"
  rm -rf "${t}/meeting"
  cp -R "${SCRIPT_DIR}/../meeting" "${t}/meeting"
  chmod +x "${t}/meeting/"*.sh
}

write_linux() {
  local t="${OUT}/linux-cuda"
  mkdir -p "${t}/llama.cpp" "${t}/opencode" "${t}/whisper.cpp"
  local tag url oc_tag oc_url
  read -r tag url <<<"$(llama_asset ubuntu-vulkan-x64)"
  echo "linux-cuda llama.cpp ${tag}"
  fetch_archive "${url}" "${t}/llama.cpp" llama-server
  read -r oc_tag oc_url <<<"$(github_asset sst/opencode "${OPENCODE_TAG}" opencode-linux-x64.tar.gz)"
  echo "linux-cuda opencode ${oc_tag}"
  fetch_archive "${oc_url}" "${t}/opencode" opencode
  fetch_whisper_source "${t}/whisper.cpp" "${WHISPER_TAG}"
  write_common_unix_files "${t}"

  cat >"${t}/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="${HERE}/llama.cpp${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
exec "${HERE}/llama.cpp/llama-server" \
  -m "${HERE}/../models/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf" \
  --mmproj "${HERE}/../models/mmproj-Qwen_Qwen3.6-35B-A3B-bf16.gguf" \
  -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 \
  -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads 4 --threads-http 4 \
  --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
  --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek \
  --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui \
  --host 127.0.0.1 --port 8080
EOF
  chmod +x "${t}/start.sh"

  cat >"${t}/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
DEST="${HOME}/.local/slopcode"
mkdir -p "${DEST}/models" "${DEST}/llama.cpp" "${DEST}/opencode" "${DEST}/whisper.cpp" "${DEST}/meeting" "${HOME}/.local/bin" "${HOME}/.config/systemd/user"
cp -R "${HERE}/llama.cpp/." "${DEST}/llama.cpp/"
cp -R "${HERE}/opencode/." "${DEST}/opencode/"
cp -R "${HERE}/whisper.cpp/." "${DEST}/whisper.cpp/"
cp -R "${HERE}/meeting/." "${DEST}/meeting/"
cp -n "${ROOT}/models/"*.gguf "${ROOT}/models/ggml-large-v3-turbo.bin" "${DEST}/models/"
ln -sf "${DEST}/opencode/opencode" "${HOME}/.local/bin/opencode"
chmod +x "${DEST}/meeting/"*.sh
ln -sf "${DEST}/meeting/record-meeting.sh" "${HOME}/.local/bin/record-meeting"
ln -sf "${DEST}/meeting/meeting-transcribe.sh" "${HOME}/.local/bin/meeting-transcribe"
ln -sf "${DEST}/meeting/meeting-notes.sh" "${HOME}/.local/bin/meeting-notes"
ln -sf "${DEST}/meeting/meeting-process.sh" "${HOME}/.local/bin/meeting-process"
bash "${HERE}/opencode_privacy.sh"

if [[ ! -x "${DEST}/whisper.cpp/build/bin/whisper-server" ]]; then
  command -v cmake >/dev/null || { echo "cmake missing"; exit 1; }
  command -v ninja >/dev/null || { echo "ninja missing"; exit 1; }
  args=(-S "${DEST}/whisper.cpp" -B "${DEST}/whisper.cpp/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_SERVER=1)
  if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
    args+=(-DGGML_CUDA=1)
  elif command -v vulkaninfo >/dev/null && vulkaninfo --summary >/dev/null 2>&1; then
    args+=(-DGGML_VULKAN=1)
  else
    args+=(-DGGML_BLAS=1)
  fi
  cmake "${args[@]}"
  cmake --build "${DEST}/whisper.cpp/build" -j"$(nproc 2>/dev/null || echo 4)"
fi

cat >"${DEST}/run-llamacpp.sh" <<RUN
#!/usr/bin/env bash
export LD_LIBRARY_PATH="${DEST}/llama.cpp\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
exec "${DEST}/llama.cpp/llama-server" -m "${DEST}/models/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf" --mmproj "${DEST}/models/mmproj-Qwen_Qwen3.6-35B-A3B-bf16.gguf" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads 4 --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui --host 127.0.0.1 --port 8080
RUN
cat >"${DEST}/run-whisper.sh" <<RUN
#!/usr/bin/env bash
exec "${DEST}/whisper.cpp/build/bin/whisper-server" -m "${DEST}/models/ggml-large-v3-turbo.bin" --host 127.0.0.1 --port 8427 -l auto -t 4 -fa --inference-path /v1/audio/transcriptions --convert --tmp-dir /tmp
RUN
chmod +x "${DEST}/run-llamacpp.sh" "${DEST}/run-whisper.sh"

cat >"${HOME}/.config/systemd/user/slopcode-llamacpp.service" <<UNIT
[Unit]
Description=slopcode llama.cpp localhost
[Service]
ExecStart=${DEST}/run-llamacpp.sh
Restart=on-failure
[Install]
WantedBy=default.target
UNIT
cat >"${HOME}/.config/systemd/user/whisper-server.service" <<UNIT
[Unit]
Description=slopcode whisper.cpp localhost
[Service]
ExecStart=${DEST}/run-whisper.sh
Restart=on-failure
[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now slopcode-llamacpp.service whisper-server.service
mkdir -p "${HOME}/.config/opencode"
cat >"${HOME}/.config/opencode/opencode.json" <<JSON
{"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B Q4","limit":{"context":262144,"output":16384},"reasoning":true,"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}
JSON
echo "installed: opencode, meeting tools, llama.cpp on 127.0.0.1:8080, whisper on 127.0.0.1:8427"
EOF
  chmod +x "${t}/install.sh"
}

write_mac() {
  local t="${OUT}/mac-m1"
  mkdir -p "${t}/llama.cpp" "${t}/opencode" "${t}/whisper.cpp"
  local tag url oc_tag oc_url
  read -r tag url <<<"$(llama_asset macos-arm64)"
  echo "mac-m1 llama.cpp ${tag}"
  fetch_archive "${url}" "${t}/llama.cpp" llama-server
  read -r oc_tag oc_url <<<"$(github_asset sst/opencode "${OPENCODE_TAG}" opencode-darwin-arm64.zip)"
  echo "mac-m1 opencode ${oc_tag}"
  fetch_archive "${oc_url}" "${t}/opencode" opencode
  fetch_whisper_source "${t}/whisper.cpp" "${WHISPER_TAG}"
  write_common_unix_files "${t}"

  cat >"${t}/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
DEST="${HOME}/Library/Application Support/slopcode"
LOGS="${HOME}/Library/Logs/slopcode"
AGENTS="${HOME}/Library/LaunchAgents"
mkdir -p "${DEST}/models" "${DEST}/llama.cpp" "${DEST}/opencode" "${DEST}/whisper.cpp" "${DEST}/meeting" "${LOGS}" "${AGENTS}" "${HOME}/.local/bin"
cp -R "${HERE}/llama.cpp/." "${DEST}/llama.cpp/"
cp -R "${HERE}/opencode/." "${DEST}/opencode/"
cp -R "${HERE}/whisper.cpp/." "${DEST}/whisper.cpp/"
cp -R "${HERE}/meeting/." "${DEST}/meeting/"
cp -n "${ROOT}/models/"*.gguf "${ROOT}/models/ggml-large-v3-turbo.bin" "${DEST}/models/"
ln -sf "${DEST}/opencode/opencode" "${HOME}/.local/bin/opencode"
chmod +x "${DEST}/meeting/"*.sh
ln -sf "${DEST}/meeting/record-meeting.sh" "${HOME}/.local/bin/record-meeting"
ln -sf "${DEST}/meeting/meeting-transcribe.sh" "${HOME}/.local/bin/meeting-transcribe"
ln -sf "${DEST}/meeting/meeting-notes.sh" "${HOME}/.local/bin/meeting-notes"
ln -sf "${DEST}/meeting/meeting-process.sh" "${HOME}/.local/bin/meeting-process"
bash "${HERE}/opencode_privacy.sh"

if [[ ! -x "${DEST}/whisper.cpp/build/bin/whisper-server" ]]; then
  command -v cmake >/dev/null || { echo "cmake missing: brew install cmake"; exit 1; }
  command -v ninja >/dev/null || { echo "ninja missing: brew install ninja"; exit 1; }
  cmake -S "${DEST}/whisper.cpp" -B "${DEST}/whisper.cpp/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_SERVER=1 -DGGML_METAL=1
  cmake --build "${DEST}/whisper.cpp/build" -j"$(sysctl -n hw.physicalcpu 2>/dev/null || echo 4)"
fi

LLAMA_PLIST="${AGENTS}/com.slopcode.llamacpp.plist"
WHISPER_PLIST="${AGENTS}/com.slopcode.whisper-server.plist"
cat >"${LLAMA_PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.slopcode.llamacpp</string>
<key>ProgramArguments</key><array>
<string>${DEST}/llama.cpp/llama-server</string><string>-m</string><string>${DEST}/models/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf</string><string>--mmproj</string><string>${DEST}/models/mmproj-Qwen_Qwen3.6-35B-A3B-bf16.gguf</string><string>-c</string><string>131072</string><string>--cache-type-k</string><string>q8_0</string><string>--cache-type-v</string><string>q8_0</string><string>-b</string><string>2048</string><string>-ub</string><string>1024</string><string>-ngl</string><string>99</string><string>-fa</string><string>on</string><string>-np</string><string>1</string><string>--alias</string><string>qwen</string><string>--jinja</string><string>--reasoning</string><string>on</string><string>--reasoning-budget</string><string>4096</string><string>--no-context-shift</string><string>--no-webui</string><string>--host</string><string>127.0.0.1</string><string>--port</string><string>8080</string>
</array>
<key>EnvironmentVariables</key><dict><key>DYLD_LIBRARY_PATH</key><string>${DEST}/llama.cpp</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>${LOGS}/llamacpp.log</string><key>StandardErrorPath</key><string>${LOGS}/llamacpp.log</string>
</dict></plist>
XML
cat >"${WHISPER_PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.slopcode.whisper-server</string>
<key>ProgramArguments</key><array>
<string>${DEST}/whisper.cpp/build/bin/whisper-server</string><string>-m</string><string>${DEST}/models/ggml-large-v3-turbo.bin</string><string>--host</string><string>127.0.0.1</string><string>--port</string><string>8427</string><string>-l</string><string>auto</string><string>-t</string><string>4</string><string>-fa</string><string>--inference-path</string><string>/v1/audio/transcriptions</string><string>--convert</string><string>--tmp-dir</string><string>/tmp</string>
</array>
<key>EnvironmentVariables</key><dict><key>DYLD_LIBRARY_PATH</key><string>${DEST}/whisper.cpp/build/bin</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>${LOGS}/whisper-server.log</string><key>StandardErrorPath</key><string>${LOGS}/whisper-server.log</string>
</dict></plist>
XML
launchctl bootout "gui/$(id -u)/com.slopcode.llamacpp" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.slopcode.whisper-server" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${LLAMA_PLIST}"
launchctl bootstrap "gui/$(id -u)" "${WHISPER_PLIST}"
mkdir -p "${HOME}/.config/opencode"
cat >"${HOME}/.config/opencode/opencode.json" <<JSON
{"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B Q4","limit":{"context":131072,"output":16384},"reasoning":true,"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}
JSON
echo "installed: opencode, meeting tools, llama.cpp on 127.0.0.1:8080, whisper on 127.0.0.1:8427"
EOF
  chmod +x "${t}/install.sh"
}

write_windows() {
  local t="${OUT}/windows-arc"
  mkdir -p "${t}/llama.cpp" "${t}/opencode" "${t}/whisper.cpp"
  local tag url oc_tag oc_url wh_tag wh_url
  read -r tag url <<<"$(llama_asset win-vulkan-x64)"
  echo "windows-arc llama.cpp ${tag}"
  fetch_archive "${url}" "${t}/llama.cpp" llama-server.exe
  read -r oc_tag oc_url <<<"$(github_asset sst/opencode "${OPENCODE_TAG}" opencode-windows-x64.zip)"
  echo "windows-arc opencode ${oc_tag}"
  fetch_archive "${oc_url}" "${t}/opencode" opencode.exe
  read -r wh_tag wh_url <<<"$(github_asset ggml-org/whisper.cpp "${WHISPER_TAG}" whisper-bin-x64.zip)"
  echo "windows whisper.cpp ${wh_tag}"
  fetch_archive "${wh_url}" "${t}/whisper.cpp" whisper-server.exe
  rm -rf "${t}/meeting"
  cp -R "${SCRIPT_DIR}/../meeting" "${t}/meeting"

  cat >"${t}/install.bat" <<'EOF'
@echo off
setlocal EnableDelayedExpansion
set "HERE=%~dp0"
for %%I in ("%HERE%\..") do set "ROOT=%%~fI"
set "DEST=%USERPROFILE%\slopcode"
mkdir "%DEST%\models" "%DEST%\llama.cpp" "%DEST%\opencode" "%DEST%\whisper.cpp" "%DEST%\meeting" "%DEST%\bin" 2>nul
xcopy /E /I /Y "%HERE%\llama.cpp" "%DEST%\llama.cpp" >nul
xcopy /E /I /Y "%HERE%\opencode" "%DEST%\opencode" >nul
xcopy /E /I /Y "%HERE%\whisper.cpp" "%DEST%\whisper.cpp" >nul
xcopy /E /I /Y "%HERE%\meeting" "%DEST%\meeting" >nul
copy /Y "%ROOT%\models\*.gguf" "%DEST%\models\" >nul
copy /Y "%ROOT%\models\ggml-large-v3-turbo.bin" "%DEST%\models\" >nul
setx OPENCODE_DISABLE_AUTOUPDATE 1 >nul
setx OPENCODE_DISABLE_SHARE 1 >nul
setx OPENCODE_DISABLE_MODELS_FETCH 1 >nul
setx OPENCODE_DISABLE_LSP_DOWNLOAD 1 >nul
setx OPENCODE_DISABLE_DEFAULT_PLUGINS 1 >nul
setx OPENCODE_DISABLE_EMBEDDED_WEB_UI 1 >nul
set "MODEL=%DEST%\models\Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
set "MMPROJ=%DEST%\models\mmproj-Qwen_Qwen3.6-35B-A3B-bf16.gguf"
set "WMODEL=%DEST%\models\ggml-large-v3-turbo.bin"
>"%DEST%\run-llamacpp.bat" echo @echo off
>>"%DEST%\run-llamacpp.bat" echo set "PATH=%DEST%\llama.cpp;%%PATH%%"
>>"%DEST%\run-llamacpp.bat" echo "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" --mmproj "%MMPROJ%" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads 4 --threads-http 4 --alias qwen --jinja --reasoning on --reasoning-budget 4096 --no-context-shift --no-webui --host 127.0.0.1 --port 8080
>"%DEST%\run-whisper.bat" echo @echo off
>>"%DEST%\run-whisper.bat" echo set "PATH=%DEST%\whisper.cpp;%%PATH%%"
>>"%DEST%\run-whisper.bat" echo "%DEST%\whisper.cpp\whisper-server.exe" -m "%WMODEL%" --host 127.0.0.1 --port 8427 -l auto -t 4 -fa --inference-path /v1/audio/transcriptions --convert --tmp-dir "%TEMP%"
mkdir "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup" 2>nul
>"%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\slopcode-llamacpp.bat" echo start "slopcode-llamacpp" /MIN "%DEST%\run-llamacpp.bat"
>"%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\slopcode-whisper.bat" echo start "slopcode-whisper" /MIN "%DEST%\run-whisper.bat"
>"%DEST%\bin\record-meeting.cmd" echo @echo off
>>"%DEST%\bin\record-meeting.cmd" echo start "" "%DEST%\meeting\record-meeting.html"
>"%DEST%\bin\meeting-transcribe.cmd" echo @echo off
>>"%DEST%\bin\meeting-transcribe.cmd" echo powershell -NoProfile -ExecutionPolicy Bypass -File "%DEST%\meeting\meeting-transcribe.ps1" %%*
>"%DEST%\bin\meeting-notes.cmd" echo @echo off
>>"%DEST%\bin\meeting-notes.cmd" echo powershell -NoProfile -ExecutionPolicy Bypass -File "%DEST%\meeting\meeting-notes.ps1" %%*
>"%DEST%\bin\meeting-process.cmd" echo @echo off
>>"%DEST%\bin\meeting-process.cmd" echo powershell -NoProfile -ExecutionPolicy Bypass -File "%DEST%\meeting\meeting-process.ps1" %%*
powershell -NoProfile -Command "$p=[Environment]::GetEnvironmentVariable('Path','User'); $adds=@('%DEST%\opencode','%DEST%\bin'); [array]::Reverse($adds); foreach($add in $adds){ if (($p -split ';') -notcontains $add) { $p=$add+';'+$p } }; [Environment]::SetEnvironmentVariable('Path', $p, 'User')"
start "slopcode-llamacpp" /MIN "%DEST%\run-llamacpp.bat"
start "slopcode-whisper" /MIN "%DEST%\run-whisper.bat"
echo Installed localhost-only llama.cpp 8080, whisper 8427, opencode, and meeting tools.
echo Open a new terminal before running opencode or meeting-process.
EOF
}

copy_models
for target in "${TARGETS[@]}"; do
  case "${target}" in
    linux-cuda) write_linux ;;
    mac-m1) write_mac ;;
    windows-arc) write_windows ;;
  esac
done

cat >"${OUT}/README.txt" <<'EOF'
slopcode USB bundle

Install:
  Linux:   linux-cuda/install.sh
  macOS:   mac-m1/install.sh
  Windows: windows-arc/install.bat

Runtime endpoints are localhost-only:
  llama.cpp:  http://127.0.0.1:8080/v1
  whisper:    http://127.0.0.1:8427/v1/audio/transcriptions

Meeting commands installed to PATH:
  record-meeting      browser microphone WAV recorder
  meeting-transcribe  local whisper.cpp transcription
  meeting-notes       local opencode note generation
  meeting-process     transcribe, then write notes

No Pi, no bundled Node, no npm cache.
EOF

echo "bundle ready at ${OUT}"
