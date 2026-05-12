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
  while IFS= read -r -d '' f; do
    cp -n "${f}" "${OUT}/models/"
    local bn
    bn="$(basename "${f}")"
    sha256sum "${f}" | awk '{print $1}' > "${OUT}/models/${bn}.sha256"
  done < <(find "${src_dir}" -maxdepth 1 -type f -name '*.gguf' -print0)
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
  -m "${HERE}/../models/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf" \
  --mmproj "${HERE}/../models/mmproj-BF16.gguf" \
  -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 \
  -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads 4 --threads-http 4 \
  --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
  --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek \
  --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui \
  --host 127.0.0.1 --port 8080
EOF
  chmod +x "${t}/start.sh"

  cat >"${t}/README.md" <<'EOF'
slopcode for Linux (NVIDIA CUDA)
================================

WHAT THIS IS
------------
A local AI coding assistant. Everything runs on your computer: no cloud,
no account, no data leaves the machine. One background service binds
to localhost only:

  http://127.0.0.1:8080/v1   (llama.cpp, the LLM)

"Endpoint" just means a URL the opencode coding tool talks to.

The USB also ships whisper.cpp + meeting tools, but the automatic
installer does NOT install or start them. Follow the manual section
below (steps 6, 8, 10) if you want speech-to-text + meeting workflow.


OPTION 1 - AUTOMATIC INSTALL (recommended)
------------------------------------------
Open a terminal in this folder (linux-cuda/) and run:

    bash install.sh

That's it. Skip to "AFTER INSTALL".


OPTION 2 - MANUAL INSTALL
-------------------------
Prerequisite: cmake and ninja must be installed.

    sudo apt install cmake ninja-build     (Debian/Ubuntu)
    sudo dnf install cmake ninja-build     (Fedora)
    sudo pacman -S cmake ninja             (Arch)

1. Create the install directory:

       mkdir -p ~/.local/slopcode/models
       mkdir -p ~/.local/slopcode/llama.cpp
       mkdir -p ~/.local/slopcode/opencode
       mkdir -p ~/.local/slopcode/whisper.cpp
       mkdir -p ~/.local/slopcode/meeting
       mkdir -p ~/.local/bin
       mkdir -p ~/.config/systemd/user
       mkdir -p ~/.config/opencode

2. Copy the bundled folders from this USB:

       cp -R llama.cpp/.   ~/.local/slopcode/llama.cpp/
       cp -R opencode/.    ~/.local/slopcode/opencode/
       cp -R whisper.cpp/. ~/.local/slopcode/whisper.cpp/
       cp -R meeting/.     ~/.local/slopcode/meeting/

3. Copy the models from the bundle root (one level up):

       cp ../models/*.gguf                    ~/.local/slopcode/models/
       cp ../models/ggml-large-v3-turbo.bin   ~/.local/slopcode/models/

4. Make opencode and the meeting tools available on PATH:

       ln -sf ~/.local/slopcode/opencode/opencode ~/.local/bin/opencode
       chmod +x ~/.local/slopcode/meeting/*.sh
       ln -sf ~/.local/slopcode/meeting/record-meeting.sh     ~/.local/bin/record-meeting
       ln -sf ~/.local/slopcode/meeting/meeting-transcribe.sh ~/.local/bin/meeting-transcribe
       ln -sf ~/.local/slopcode/meeting/meeting-notes.sh      ~/.local/bin/meeting-notes
       ln -sf ~/.local/slopcode/meeting/meeting-process.sh    ~/.local/bin/meeting-process

   Make sure ~/.local/bin is on your PATH. If not, add this to ~/.profile:

       export PATH="$HOME/.local/bin:$PATH"

5. Pin the privacy environment variables (blocks all phone-home calls).
   Run the bundled helper:

       bash opencode_privacy.sh

   This appends the following to ~/.profile and writes
   ~/.config/environment.d/opencode.conf:

       OPENCODE_DISABLE_AUTOUPDATE=1
       OPENCODE_DISABLE_SHARE=1
       OPENCODE_DISABLE_MODELS_FETCH=1
       OPENCODE_DISABLE_LSP_DOWNLOAD=1
       OPENCODE_DISABLE_DEFAULT_PLUGINS=1
       OPENCODE_DISABLE_EMBEDDED_WEB_UI=1

6. Build whisper.cpp from source (needs cmake + ninja, ~5 minutes):

       cmake -S ~/.local/slopcode/whisper.cpp \
             -B ~/.local/slopcode/whisper.cpp/build \
             -G Ninja \
             -DCMAKE_BUILD_TYPE=Release \
             -DBUILD_SHARED_LIBS=OFF \
             -DWHISPER_BUILD_SERVER=1 \
             -DGGML_CUDA=1
       cmake --build ~/.local/slopcode/whisper.cpp/build -j$(nproc)

   If you do not have an NVIDIA GPU, replace -DGGML_CUDA=1 with
   -DGGML_VULKAN=1 (Intel/AMD GPU) or -DGGML_BLAS=1 (CPU only).

7. Create the llama.cpp launcher
   ~/.local/slopcode/run-llamacpp.sh with this exact content:

       #!/usr/bin/env bash
       export LD_LIBRARY_PATH="$HOME/.local/slopcode/llama.cpp${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
       exec "$HOME/.local/slopcode/llama.cpp/llama-server" \
         -m "$HOME/.local/slopcode/models/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf" \
         --mmproj "$HOME/.local/slopcode/models/mmproj-BF16.gguf" \
         -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 \
         -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 \
         -np 1 --threads 4 --threads-http 4 \
         --alias qwen --jinja \
         --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
         --presence-penalty 0 --repeat-penalty 1 \
         --reasoning-format deepseek --reasoning-budget 4096 \
         --no-context-shift --reasoning on --no-webui \
         --host 127.0.0.1 --port 8080

   Then:

       chmod +x ~/.local/slopcode/run-llamacpp.sh

8. Create the whisper launcher
   ~/.local/slopcode/run-whisper.sh with this exact content:

       #!/usr/bin/env bash
       exec "$HOME/.local/slopcode/whisper.cpp/build/bin/whisper-server" \
         -m "$HOME/.local/slopcode/models/ggml-large-v3-turbo.bin" \
         --host 127.0.0.1 --port 8427 -l auto -t 4 -fa \
         --inference-path /v1/audio/transcriptions \
         --convert --tmp-dir /tmp

       chmod +x ~/.local/slopcode/run-whisper.sh

9. Create the opencode config ~/.config/opencode/opencode.json with
   this exact content (one line, paste as-is):

       {"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B Q4","limit":{"context":262144,"output":16384},"reasoning":true,"interleaved":{"field":"reasoning_content"},"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}

10. Create the two systemd user units. First
    ~/.config/systemd/user/slopcode-llamacpp.service:

        [Unit]
        Description=slopcode llama.cpp localhost
        [Service]
        ExecStart=%h/.local/slopcode/run-llamacpp.sh
        Restart=on-failure
        [Install]
        WantedBy=default.target

    Then ~/.config/systemd/user/whisper-server.service:

        [Unit]
        Description=slopcode whisper.cpp localhost
        [Service]
        ExecStart=%h/.local/slopcode/run-whisper.sh
        Restart=on-failure
        [Install]
        WantedBy=default.target

11. Reload systemd and enable both services to start now and on boot:

        systemctl --user daemon-reload
        systemctl --user enable --now slopcode-llamacpp.service whisper-server.service
        loginctl enable-linger $USER

    The last line makes the services keep running when you log out.


AFTER INSTALL
-------------
One service is now running in the background:

  http://127.0.0.1:8080/v1   (llama.cpp)

Open a new terminal (so PATH updates load) and run:

    opencode

This drops you into the AI coding assistant, talking to your local
model. No cloud, no account.


TROUBLESHOOTING
---------------
Check status:

    systemctl --user status slopcode-llamacpp.service

View logs:

    journalctl --user -u slopcode-llamacpp.service -f

Stop / restart:

    systemctl --user restart slopcode-llamacpp.service

If you see weird output (repeated slashes in the thinking stream, broken
characters), the GPU build may be flaky on your card. Switch to a
slower-but-stable CPU fallback by editing run-llamacpp.sh and changing
"-ngl 99" to "-ngl 0", then restart the service.
EOF

  cat >"${t}/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
DEST="${HOME}/.local/slopcode"
mkdir -p "${DEST}/models" "${DEST}/llama.cpp" "${DEST}/opencode" "${HOME}/.local/bin" "${HOME}/.config/systemd/user"
cp -R "${HERE}/llama.cpp/." "${DEST}/llama.cpp/"
cp -R "${HERE}/opencode/." "${DEST}/opencode/"
cp -n "${ROOT}/models/"*.gguf "${DEST}/models/"
ln -sf "${DEST}/opencode/opencode" "${HOME}/.local/bin/opencode"
bash "${HERE}/opencode_privacy.sh"

cat >"${DEST}/run-llamacpp.sh" <<RUN
#!/usr/bin/env bash
export LD_LIBRARY_PATH="${DEST}/llama.cpp\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
exec "${DEST}/llama.cpp/llama-server" -m "${DEST}/models/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf" --mmproj "${DEST}/models/mmproj-BF16.gguf" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads 4 --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui --host 127.0.0.1 --port 8080
RUN
chmod +x "${DEST}/run-llamacpp.sh"

cat >"${HOME}/.config/systemd/user/slopcode-llamacpp.service" <<UNIT
[Unit]
Description=slopcode llama.cpp localhost
[Service]
ExecStart=${DEST}/run-llamacpp.sh
Restart=on-failure
[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now slopcode-llamacpp.service
mkdir -p "${HOME}/.config/opencode"
cat >"${HOME}/.config/opencode/opencode.json" <<JSON
{"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B Q4","limit":{"context":262144,"output":16384},"reasoning":true,"interleaved":{"field":"reasoning_content"},"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}
JSON
echo "installed: opencode + llama.cpp on 127.0.0.1:8080 (whisper/meeting tools shipped on USB but not auto-installed)"
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

  cat >"${t}/README.md" <<'EOF'
slopcode for macOS (Apple Silicon)
==================================

WHAT THIS IS
------------
A local AI coding assistant. Everything runs on your Mac: no cloud,
no account, no data leaves the machine. One background service binds
to localhost only:

  http://127.0.0.1:8080/v1   (llama.cpp, the LLM)

"Endpoint" just means a URL the opencode coding tool talks to.

The USB also ships whisper.cpp + meeting tools, but the automatic
installer does NOT install or start them. Follow the manual section
below if you want speech-to-text + meeting workflow.


OPTION 1 - AUTOMATIC INSTALL (recommended)
------------------------------------------
Open Terminal (Spotlight, type "Terminal"), navigate to this folder,
and run:

    bash install.sh

That's it. Skip to "AFTER INSTALL".


OPTION 2 - MANUAL INSTALL
-------------------------
Prerequisite: install cmake and ninja via Homebrew. If you don't have
Homebrew yet, visit https://brew.sh first.

    brew install cmake ninja

1. Create the install directories:

       mkdir -p ~/Library/Application\ Support/slopcode/models
       mkdir -p ~/Library/Application\ Support/slopcode/llama.cpp
       mkdir -p ~/Library/Application\ Support/slopcode/opencode
       mkdir -p ~/Library/Application\ Support/slopcode/whisper.cpp
       mkdir -p ~/Library/Application\ Support/slopcode/meeting
       mkdir -p ~/Library/Logs/slopcode
       mkdir -p ~/Library/LaunchAgents
       mkdir -p ~/.local/bin
       mkdir -p ~/.config/opencode

2. Copy the bundled folders from this USB:

       DEST="$HOME/Library/Application Support/slopcode"
       cp -R llama.cpp/.   "$DEST/llama.cpp/"
       cp -R opencode/.    "$DEST/opencode/"
       cp -R whisper.cpp/. "$DEST/whisper.cpp/"
       cp -R meeting/.     "$DEST/meeting/"

3. Copy the models from the bundle root (one level up):

       cp ../models/*.gguf                  "$DEST/models/"
       cp ../models/ggml-large-v3-turbo.bin "$DEST/models/"

4. Make opencode and the meeting tools available on PATH:

       ln -sf "$DEST/opencode/opencode" ~/.local/bin/opencode
       chmod +x "$DEST/meeting/"*.sh
       ln -sf "$DEST/meeting/record-meeting.sh"     ~/.local/bin/record-meeting
       ln -sf "$DEST/meeting/meeting-transcribe.sh" ~/.local/bin/meeting-transcribe
       ln -sf "$DEST/meeting/meeting-notes.sh"      ~/.local/bin/meeting-notes
       ln -sf "$DEST/meeting/meeting-process.sh"    ~/.local/bin/meeting-process

   Make sure ~/.local/bin is on your PATH. If not, add this to
   ~/.zprofile (zsh is the default on modern macOS):

       export PATH="$HOME/.local/bin:$PATH"

5. Pin the privacy environment variables (blocks all phone-home calls):

       bash opencode_privacy.sh

   This appends six OPENCODE_DISABLE_* lines to ~/.profile:

       OPENCODE_DISABLE_AUTOUPDATE=1
       OPENCODE_DISABLE_SHARE=1
       OPENCODE_DISABLE_MODELS_FETCH=1
       OPENCODE_DISABLE_LSP_DOWNLOAD=1
       OPENCODE_DISABLE_DEFAULT_PLUGINS=1
       OPENCODE_DISABLE_EMBEDDED_WEB_UI=1

6. Build whisper.cpp from source with Metal acceleration (~5 minutes):

       cmake -S "$DEST/whisper.cpp" -B "$DEST/whisper.cpp/build" \
             -G Ninja -DCMAKE_BUILD_TYPE=Release \
             -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_SERVER=1 \
             -DGGML_METAL=1
       cmake --build "$DEST/whisper.cpp/build" -j$(sysctl -n hw.physicalcpu)

7. Create the opencode config ~/.config/opencode/opencode.json with
   this exact content (one line, paste as-is):

       {"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B Q4","limit":{"context":131072,"output":16384},"reasoning":true,"interleaved":{"field":"reasoning_content"},"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}

8. Create the llama.cpp launchd plist
   ~/Library/LaunchAgents/com.slopcode.llamacpp.plist with this
   exact content (replace HOME_PATH with the output of `echo $HOME`):

       <?xml version="1.0" encoding="UTF-8"?>
       <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
       <plist version="1.0"><dict>
       <key>Label</key><string>com.slopcode.llamacpp</string>
       <key>ProgramArguments</key><array>
       <string>HOME_PATH/Library/Application Support/slopcode/llama.cpp/llama-server</string>
       <string>-m</string><string>HOME_PATH/Library/Application Support/slopcode/models/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf</string>
       <string>--mmproj</string><string>HOME_PATH/Library/Application Support/slopcode/models/mmproj-BF16.gguf</string>
       <string>-c</string><string>131072</string>
       <string>--cache-type-k</string><string>q8_0</string>
       <string>--cache-type-v</string><string>q8_0</string>
       <string>-b</string><string>2048</string><string>-ub</string><string>1024</string>
       <string>-ngl</string><string>99</string><string>-fa</string><string>on</string>
       <string>-np</string><string>1</string>
       <string>--alias</string><string>qwen</string><string>--jinja</string>
       <string>--reasoning</string><string>on</string>
       <string>--reasoning-budget</string><string>4096</string>
       <string>--no-context-shift</string><string>--no-webui</string>
       <string>--host</string><string>127.0.0.1</string>
       <string>--port</string><string>8080</string>
       </array>
       <key>EnvironmentVariables</key><dict>
       <key>DYLD_LIBRARY_PATH</key><string>HOME_PATH/Library/Application Support/slopcode/llama.cpp</string>
       </dict>
       <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
       <key>StandardOutPath</key><string>HOME_PATH/Library/Logs/slopcode/llamacpp.log</string>
       <key>StandardErrorPath</key><string>HOME_PATH/Library/Logs/slopcode/llamacpp.log</string>
       </dict></plist>

9. Create the whisper launchd plist
   ~/Library/LaunchAgents/com.slopcode.whisper-server.plist with
   this exact content (replace HOME_PATH the same way):

       <?xml version="1.0" encoding="UTF-8"?>
       <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
       <plist version="1.0"><dict>
       <key>Label</key><string>com.slopcode.whisper-server</string>
       <key>ProgramArguments</key><array>
       <string>HOME_PATH/Library/Application Support/slopcode/whisper.cpp/build/bin/whisper-server</string>
       <string>-m</string><string>HOME_PATH/Library/Application Support/slopcode/models/ggml-large-v3-turbo.bin</string>
       <string>--host</string><string>127.0.0.1</string>
       <string>--port</string><string>8427</string>
       <string>-l</string><string>auto</string><string>-t</string><string>4</string>
       <string>-fa</string>
       <string>--inference-path</string><string>/v1/audio/transcriptions</string>
       <string>--convert</string>
       <string>--tmp-dir</string><string>/tmp</string>
       </array>
       <key>EnvironmentVariables</key><dict>
       <key>DYLD_LIBRARY_PATH</key><string>HOME_PATH/Library/Application Support/slopcode/whisper.cpp/build/bin</string>
       </dict>
       <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
       <key>StandardOutPath</key><string>HOME_PATH/Library/Logs/slopcode/whisper-server.log</string>
       <key>StandardErrorPath</key><string>HOME_PATH/Library/Logs/slopcode/whisper-server.log</string>
       </dict></plist>

10. Load both services so they start now and on every login:

        launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.slopcode.llamacpp.plist
        launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.slopcode.whisper-server.plist


AFTER INSTALL
-------------
One service is now running in the background:

  http://127.0.0.1:8080/v1   (llama.cpp)

Open a new Terminal window (so PATH updates load) and run:

    opencode

This drops you into the AI coding assistant, talking to your local
model. No cloud, no account.


TROUBLESHOOTING
---------------
Check that the service is loaded:

    launchctl list | grep slopcode

View live logs:

    tail -f ~/Library/Logs/slopcode/llamacpp.log

Stop the service:

    launchctl bootout gui/$(id -u)/com.slopcode.llamacpp

Restart: bootout, then bootstrap again with the same plist.

If you see weird output (repeated slashes in the thinking stream,
broken characters), Metal may be misbehaving on your hardware. Edit
the llama.cpp plist and change "-ngl" from 99 to 0 (pure CPU
fallback, slower but stable), then reload the service.
EOF

  cat >"${t}/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
DEST="${HOME}/Library/Application Support/slopcode"
LOGS="${HOME}/Library/Logs/slopcode"
AGENTS="${HOME}/Library/LaunchAgents"
mkdir -p "${DEST}/models" "${DEST}/llama.cpp" "${DEST}/opencode" "${LOGS}" "${AGENTS}" "${HOME}/.local/bin"
cp -R "${HERE}/llama.cpp/." "${DEST}/llama.cpp/"
cp -R "${HERE}/opencode/." "${DEST}/opencode/"
cp -n "${ROOT}/models/"*.gguf "${DEST}/models/"
ln -sf "${DEST}/opencode/opencode" "${HOME}/.local/bin/opencode"
bash "${HERE}/opencode_privacy.sh"

LLAMA_PLIST="${AGENTS}/com.slopcode.llamacpp.plist"
cat >"${LLAMA_PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.slopcode.llamacpp</string>
<key>ProgramArguments</key><array>
<string>${DEST}/llama.cpp/llama-server</string><string>-m</string><string>${DEST}/models/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf</string><string>--mmproj</string><string>${DEST}/models/mmproj-BF16.gguf</string><string>-c</string><string>131072</string><string>--cache-type-k</string><string>q8_0</string><string>--cache-type-v</string><string>q8_0</string><string>-b</string><string>2048</string><string>-ub</string><string>1024</string><string>-ngl</string><string>99</string><string>-fa</string><string>on</string><string>-np</string><string>1</string><string>--alias</string><string>qwen</string><string>--jinja</string><string>--reasoning</string><string>on</string><string>--reasoning-budget</string><string>4096</string><string>--no-context-shift</string><string>--no-webui</string><string>--host</string><string>127.0.0.1</string><string>--port</string><string>8080</string>
</array>
<key>EnvironmentVariables</key><dict><key>DYLD_LIBRARY_PATH</key><string>${DEST}/llama.cpp</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>${LOGS}/llamacpp.log</string><key>StandardErrorPath</key><string>${LOGS}/llamacpp.log</string>
</dict></plist>
XML
launchctl bootout "gui/$(id -u)/com.slopcode.llamacpp" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${LLAMA_PLIST}"
mkdir -p "${HOME}/.config/opencode"
cat >"${HOME}/.config/opencode/opencode.json" <<JSON
{"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B Q4","limit":{"context":131072,"output":16384},"reasoning":true,"interleaved":{"field":"reasoning_content"},"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}
JSON
echo "installed: opencode + llama.cpp on 127.0.0.1:8080 (whisper/meeting tools shipped on USB but not auto-installed)"
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

  # PowerShell helper: verify model checksums before install.
  cat >"${t}/verify-models.ps1" <<'PS1'
param([string]$ModelsDir)
$ok = $true
Get-ChildItem "$ModelsDir\*.sha256" | ForEach-Object {
    $gguf = $_.FullName -replace '\.sha256$', ''
    if (-not (Test-Path $gguf)) {
        Write-Error "missing model file: $gguf"
        $ok = $false
        return
    }
    $expected = (Get-Content $_.FullName -Raw).Trim().ToUpper()
    $actual   = (Get-FileHash -Algorithm SHA256 $gguf).Hash
    if ($expected -ne $actual) {
        Write-Error "SHA256 mismatch: $($_.Name -replace '\.sha256$', '')"
        Write-Error "  expected: $expected"
        Write-Error "  actual:   $actual"
        $ok = $false
    } else {
        Write-Host "OK  $($_.Name -replace '\.sha256$', '')"
    }
}
if (-not $ok) { exit 1 }
PS1

  cat >"${t}/README.md" <<'EOF'
slopcode for Windows (Intel Arc, Vulkan)
========================================

WHAT THIS IS
------------
A local AI coding assistant. Everything runs on your computer: no
cloud, no account, no data leaves the machine. One background
service binds to localhost only:

  http://127.0.0.1:8080/v1   (llama.cpp, the LLM)

"Endpoint" just means a URL the opencode coding tool talks to.

The USB also ships whisper.cpp + meeting tools, but the automatic
installer does NOT install or start them. Follow the manual section
below if you want speech-to-text + meeting workflow.


PREREQUISITES (Arc 140V / Lunar Lake / 64 GB RAM)
-------------------------------------------------
Do these TWO things ONCE on the laptop, BEFORE running install.bat.
Skipping them is the most likely reason the bundle will OOM or BSOD
even though the flags are correct.

(A) UPDATE THE INTEL GRAPHICS DRIVER to 32.0.101.8629 WHQL or newer.

    Older Intel drivers (notably 101.8331 and earlier) have memory
    accounting bugs on Lunar Lake UMA that produce
    "ErrorOutOfDeviceMemory" even with sufficient RAM
    (ggml-org/llama.cpp#18946).

    To check current version:
      Settings -> System -> About -> Device specifications
        OR
      open "Intel Graphics Software" / "Intel Arc Control" and read
      the driver version on the home screen.

    To update: Windows Update -> "Check for updates" -> "View optional
    updates" -> Graphics. If Windows Update doesn't offer it, get the
    direct installer from
    https://www.intel.com/content/www/us/en/download/785597/intel-arc-graphics-windows.html
    (search "Intel Arc Graphics Driver"). Pick the latest WHQL.

    Reboot after install.

(B) RAISE SHARED GPU MEMORY OVERRIDE to 32 GB.

    By default the Arc 140V Vulkan driver exposes only ~16 GB of GPU
    memory to applications, even on a 64 GB system. The bundle uses
    c=262144 plus -ub 1024 plus 5 MoE expert layers on the iGPU, which
    can peak around 17-20 GB. Without raising this override the bundle
    will hit "ErrorOutOfDeviceMemory" partway through warmup.

    1. Open "Intel Graphics Software" (Start menu, type that).
       Older driver: "Intel Arc Control" instead.
    2. Performance tab (or "GPU" tab on older versions).
    3. Find "Shared GPU Memory Override" (sometimes "GPU Memory
       Override" or "Arc VRAM Override").
    4. Set the value to 32 GB.
    5. Apply, then reboot.

    Half of system RAM is the usual safe maximum (32 GB of 64 GB).
    Going higher leaves Windows and your other apps short of RAM.

(C) OPTIONAL safety net: raise Windows TDR timeout. See TROUBLESHOOTING
    -> "Raise Windows TDR timeout" further down.


OPTION 1 - AUTOMATIC INSTALL (recommended)
------------------------------------------
After the two prerequisites above are done and rebooted, double-click
install.bat in this folder. A black Command Prompt window opens,
copies the files, sets six environment variables, verifies model
checksums, creates a Startup shortcut, and launches the llama.cpp
background service.

If Windows SmartScreen blocks it, click "More info" and "Run anyway".

That's it. Skip to "AFTER INSTALL".


OPTION 2 - MANUAL INSTALL
-------------------------
1. Create the install directory and subfolders. Open File Explorer,
   go to C:\Users\YourName\ (the address bar shortcut is
   %USERPROFILE%), and create:

       %USERPROFILE%\slopcode\
       %USERPROFILE%\slopcode\models\
       %USERPROFILE%\slopcode\llama.cpp\
       %USERPROFILE%\slopcode\opencode\
       %USERPROFILE%\slopcode\whisper.cpp\
       %USERPROFILE%\slopcode\meeting\
       %USERPROFILE%\slopcode\bin\

   Or from Command Prompt:

       > mkdir "%USERPROFILE%\slopcode\models"
       > mkdir "%USERPROFILE%\slopcode\llama.cpp"
       > mkdir "%USERPROFILE%\slopcode\opencode"
       > mkdir "%USERPROFILE%\slopcode\whisper.cpp"
       > mkdir "%USERPROFILE%\slopcode\meeting"
       > mkdir "%USERPROFILE%\slopcode\bin"

2. Copy the bundled folders from this USB into the matching
   destinations. From this folder (windows-arc\) drag with File
   Explorer, or from Command Prompt:

       > xcopy /E /I /Y llama.cpp   "%USERPROFILE%\slopcode\llama.cpp"
       > xcopy /E /I /Y opencode    "%USERPROFILE%\slopcode\opencode"
       > xcopy /E /I /Y whisper.cpp "%USERPROFILE%\slopcode\whisper.cpp"
       > xcopy /E /I /Y meeting     "%USERPROFILE%\slopcode\meeting"

   And copy the models from the USB bundle root (the parent folder):

       > copy ..\models\*.gguf                  "%USERPROFILE%\slopcode\models\"
       > copy ..\models\ggml-large-v3-turbo.bin "%USERPROFILE%\slopcode\models\"

3. Verify the model files copied without corruption. Open PowerShell
   (Start menu, type "PowerShell") and run:

       > Get-ChildItem "$env:USERPROFILE\slopcode\models\*.sha256" |
       >   ForEach-Object {
       >     $f = $_.FullName -replace '\.sha256$',''
       >     $e = (Get-Content $_.FullName -Raw).Trim().ToUpper()
       >     $a = (Get-FileHash -Algorithm SHA256 $f).Hash
       >     if ($e -eq $a) { "OK  $f" } else { "BAD $f" }
       >   }

   Every line should start with "OK". A "BAD" line means the file
   on the USB is damaged - recopy from the bundle root or rebuild
   the USB.

4. Set the six privacy environment variables. These block all
   phone-home calls (auto-update, telemetry, model lookup, etc).

   Press the Start key, type "Edit the system environment variables",
   open it. In the System Properties window click "Environment
   Variables...". In the upper box (User variables for YourName)
   click "New..." once per variable and add:

       Name                              Value
       --------------------------------  -----
       OPENCODE_DISABLE_AUTOUPDATE       1
       OPENCODE_DISABLE_SHARE            1
       OPENCODE_DISABLE_MODELS_FETCH     1
       OPENCODE_DISABLE_LSP_DOWNLOAD     1
       OPENCODE_DISABLE_DEFAULT_PLUGINS  1
       OPENCODE_DISABLE_EMBEDDED_WEB_UI  1

   Click OK on each dialog to save.

5. Add slopcode to your user PATH in the same window. In the upper
   box, double-click "Path", click "New", and add:

       %USERPROFILE%\slopcode\opencode

   Click "New" again and add:

       %USERPROFILE%\slopcode\bin

   Click OK on every dialog.

6. Create the GPU launcher %USERPROFILE%\slopcode\run-llamacpp.bat.
   Open Notepad, paste this exact content, save as run-llamacpp.bat
   in %USERPROFILE%\slopcode\. In the "Save as type" dropdown pick
   "All Files" so Notepad does not append .txt.

       @echo off
       REM Disable Vulkan cooperative-matrix path on Intel Arc; ggml-org/llama.cpp#20554
       REM (KHR_coopmat + recent Intel Arc drivers cause GPU TDR / Windows BSOD).
       set "GGML_VK_DISABLE_COOPMAT=1"
       set "GGML_VK_DISABLE_COOPMAT2=1"
       set "PATH=%USERPROFILE%\slopcode\llama.cpp;%PATH%"
       "%USERPROFILE%\slopcode\llama.cpp\llama-server.exe" -m "%USERPROFILE%\slopcode\models\Qwen3.6-35B-A3B-UD-Q4_K_M.gguf" --mmproj "%USERPROFILE%\slopcode\models\mmproj-BF16.gguf" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads 6 --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui --host 127.0.0.1 --port 8080

   On Arc 140V (Lunar Lake, 4P + 4LP = 8 physical cores) --threads 6 is
   the right value (physical - 2). On other Arc hosts substitute
   physical-cores - 2 (min 2).

7. Create the CPU fallback launcher
   %USERPROFILE%\slopcode\run-llamacpp-cpu.bat with this exact
   content. Same Notepad steps as above:

       @echo off
       set "PATH=%USERPROFILE%\slopcode\llama.cpp;%PATH%"
       "%USERPROFILE%\slopcode\llama.cpp\llama-server.exe" -m "%USERPROFILE%\slopcode\models\Qwen3.6-35B-A3B-UD-Q4_K_M.gguf" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -ngl 0 -np 1 --threads 6 --threads-http 2 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui --host 127.0.0.1 --port 8080

8. Create the whisper launcher %USERPROFILE%\slopcode\run-whisper.bat
   with this exact content:

       @echo off
       set "PATH=%USERPROFILE%\slopcode\whisper.cpp;%PATH%"
       "%USERPROFILE%\slopcode\whisper.cpp\whisper-server.exe" -m "%USERPROFILE%\slopcode\models\ggml-large-v3-turbo.bin" --host 127.0.0.1 --port 8427 -l auto -t 4 -fa --inference-path /v1/audio/transcriptions --convert --tmp-dir "%TEMP%"

9. Create the opencode config. In Command Prompt:

       > mkdir "%USERPROFILE%\.config\opencode"

   Then open Notepad and paste this exact content (one long line):

       {"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B Q4 (Arc)","limit":{"context":262144,"output":16384},"reasoning":true,"interleaved":{"field":"reasoning_content"},"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}

   Save as opencode.json in %USERPROFILE%\.config\opencode\
   (set "Save as type" to "All Files").

10. Auto-start at login. Two options - pick one.

    Option A (recommended for non-technical users): create shortcut
    files inside the Startup folder.

    In File Explorer go to
    %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\
    (paste that into the address bar). Right-click an empty area,
    "New" -> "Shortcut", and create one shortcut:

      target: %USERPROFILE%\slopcode\run-llamacpp.bat

    Option B (one-liner .bat file): in the same Startup folder
    create slopcode-llamacpp.bat containing exactly:

        start "slopcode-llamacpp" /MIN "%USERPROFILE%\slopcode\run-llamacpp.bat"

11. Start the service now without waiting for the next login.
    Double-click %USERPROFILE%\slopcode\run-llamacpp.bat. A black
    window opens. Minimise it - it has to stay running for opencode
    to work.


AFTER INSTALL
-------------
One service is now running in the background:

  http://127.0.0.1:8080/v1   (llama.cpp)

Open a NEW Command Prompt (the old one does not have the updated
PATH) and run:

    > opencode

This drops you into the AI coding assistant, talking to your local
model. No cloud, no account.


TROUBLESHOOTING
---------------
The background service runs as a visible Command Prompt window.
Close it via Task Manager (Ctrl-Shift-Esc) or by closing the
black window.

run-llamacpp.bat       Vulkan GPU build, --n-cpu-moe 35 (35 of 40
                       MoE expert layers on CPU, 5 on the Arc iGPU).
                       Sets GGML_VK_DISABLE_COOPMAT=1 / COOPMAT2=1
                       to dodge the Intel Arc TDR / BSOD bug
                       documented at ggml-org/llama.cpp#20554.
                       -c 262144, -ub 1024, q8_0 KV.
run-llamacpp-cpu.bat   Pure CPU fallback (-ngl 0). Always correct
                       output but only ~10 tokens per second.

WHEN TO SWITCH TO CPU FALLBACK
If the Vulkan path produces garbage (repeated slashes "/////" in
opencode's thinking stream, or broken characters in the answer), or
if Windows BSODs with "your device ran into a problem and needs to
restart" (VIDEO_TDR_FAILURE):

1. Open Task Manager, find the "slopcode-llamacpp" window (or
   llama-server.exe) and end it.
2. Double-click %USERPROFILE%\slopcode\run-llamacpp-cpu.bat instead.
3. Update the startup shortcut to point at run-llamacpp-cpu.bat
   (Option A: edit the shortcut target; Option B: edit the .bat).

RAISE WINDOWS TDR TIMEOUT (optional safety net)
Default Windows TDR fires at 2 seconds, which is tight for big MoE
dispatches on Intel Arc. To give the GPU more room before Windows
resets the driver, add these DWORD values under
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\GraphicsDrivers
(open regedit, navigate, right-click empty area, New > DWORD 32-bit):

    TdrDelay     = 60     (seconds; default 2)
    TdrDdiDelay  = 60     (seconds; default 5)

Then reboot. This does not fix hangs, it just lets longer dispatches
finish before Windows kills the driver.


SECONDARY FALLBACK - garbage output that isn't slash-storm and isn't TDR
If opencode shows NaN-like text, broken Unicode, or repetition that
doesn't go away after the coopmat env vars and a fresh reboot, try
disabling Vulkan F16 accumulation. On Intel iGPUs the default F16
matmul accumulator can overflow on large batches and produce NaNs
(ggml-org/llama.cpp#18969). Edit
%USERPROFILE%\slopcode\run-llamacpp.bat and add this line right after
the two GGML_VK_DISABLE_COOPMAT lines:

    set "GGML_VK_DISABLE_F16=1"

Costs roughly 15 percent decode throughput. Restart the service
(Task Manager -> end llama-server.exe -> double-click run-llamacpp.bat
again).
EOF

  cat >"${t}/install.bat" <<'EOF'
@echo off
setlocal EnableDelayedExpansion
set "HERE=%~dp0"
for %%I in ("%HERE%\..") do set "ROOT=%%~fI"
set "DEST=%USERPROFILE%\slopcode"
echo Verifying model checksums...
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%\verify-models.ps1" -ModelsDir "%ROOT%\models"
if errorlevel 1 (
  echo ERROR: model checksum mismatch - USB may be corrupted.
  echo Re-run build_bundle.sh to rebuild a fresh bundle with new checksums.
  pause
  exit /b 1
)
mkdir "%DEST%\models" "%DEST%\llama.cpp" "%DEST%\opencode" 2>nul
xcopy /E /I /Y "%HERE%\llama.cpp" "%DEST%\llama.cpp" >nul
xcopy /E /I /Y "%HERE%\opencode" "%DEST%\opencode" >nul
copy /Y "%ROOT%\models\*.gguf" "%DEST%\models\" >nul
setx OPENCODE_DISABLE_AUTOUPDATE 1 >nul
setx OPENCODE_DISABLE_SHARE 1 >nul
setx OPENCODE_DISABLE_MODELS_FETCH 1 >nul
setx OPENCODE_DISABLE_LSP_DOWNLOAD 1 >nul
setx OPENCODE_DISABLE_DEFAULT_PLUGINS 1 >nul
setx OPENCODE_DISABLE_EMBEDDED_WEB_UI 1 >nul
set "MODEL=%DEST%\models\Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
set "MMPROJ=%DEST%\models\mmproj-BF16.gguf"
REM Detect physical cores; --threads = physical - 2 (min 2). Lunar Lake Arc 140V
REM has 4P + 4LP = 8 physical cores, so this lands on --threads 6.
set THREADS=
powershell -NoProfile -Command "try { [Math]::Max(2, (Get-CimInstance Win32_Processor | Measure-Object -Sum NumberOfCores).Sum - 2) } catch { [Math]::Max(2, [int]($env:NUMBER_OF_PROCESSORS) / 2 - 1) }" > "%TEMP%\slopcode_threads.txt" 2>nul
if exist "%TEMP%\slopcode_threads.txt" (
  set /p THREADS=<"%TEMP%\slopcode_threads.txt"
  del "%TEMP%\slopcode_threads.txt"
)
if "!THREADS!"=="" set /a THREADS=%NUMBER_OF_PROCESSORS%/2 - 1
if !THREADS! LSS 2 set THREADS=2
>"%DEST%\run-llamacpp.bat" echo @echo off
>>"%DEST%\run-llamacpp.bat" echo REM Disable Vulkan cooperative-matrix path on Intel Arc; ggml-org/llama.cpp#20554
>>"%DEST%\run-llamacpp.bat" echo REM (KHR_coopmat + recent Intel drivers cause GPU TDR / Windows BSOD).
>>"%DEST%\run-llamacpp.bat" echo set "GGML_VK_DISABLE_COOPMAT=1"
>>"%DEST%\run-llamacpp.bat" echo set "GGML_VK_DISABLE_COOPMAT2=1"
>>"%DEST%\run-llamacpp.bat" echo set "PATH=%DEST%\llama.cpp;%%PATH%%"
>>"%DEST%\run-llamacpp.bat" echo "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" --mmproj "%MMPROJ%" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads !THREADS! --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui --host 127.0.0.1 --port 8080
>"%DEST%\run-llamacpp-cpu.bat" echo @echo off
>>"%DEST%\run-llamacpp-cpu.bat" echo set "PATH=%DEST%\llama.cpp;%%PATH%%"
>>"%DEST%\run-llamacpp-cpu.bat" echo "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -ngl 0 -np 1 --threads !THREADS! --threads-http 2 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui --host 127.0.0.1 --port 8080
mkdir "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup" 2>nul
>"%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\slopcode-llamacpp.bat" echo start "slopcode-llamacpp" /MIN "%DEST%\run-llamacpp.bat"
mkdir "%USERPROFILE%\.config\opencode" 2>nul
>"%USERPROFILE%\.config\opencode\opencode.json" echo {"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B Q4 (Arc)","limit":{"context":262144,"output":16384},"reasoning":true,"interleaved":{"field":"reasoning_content"},"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}
powershell -NoProfile -Command "$p=[Environment]::GetEnvironmentVariable('Path','User'); $add='%DEST%\opencode'; if (($p -split ';') -notcontains $add) { [Environment]::SetEnvironmentVariable('Path', ($add+';'+$p), 'User') }"
start "slopcode-llamacpp" /MIN "%DEST%\run-llamacpp.bat"
echo Installed localhost-only llama.cpp 8080 and opencode (--threads !THREADS!).
echo (whisper/meeting tools are shipped on the USB but not auto-installed.)
echo If you see repeated slashes in opencode thinking, run: %DEST%\run-llamacpp-cpu.bat
echo and update the Startup shortcut to point at run-llamacpp-cpu.bat instead.
echo Open a new terminal before running opencode.
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

cat >"${OUT}/README.md" <<'EOF'
slopcode USB bundle
===================

A local AI coding assistant. Everything runs on your computer, on
localhost only. No cloud, no account, no data leaves the machine.

Find your platform's folder and open its README.md for full
instructions (automatic and manual install):

  Windows (Intel Arc):     windows-arc/README.md
  macOS (Apple Silicon):   mac-m1/README.md
  Linux (NVIDIA CUDA):     linux-cuda/README.md
EOF

echo "bundle ready at ${OUT}"
