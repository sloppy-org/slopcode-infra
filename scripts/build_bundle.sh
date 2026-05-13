#!/usr/bin/env bash
# Build a USB-ready slopcode bundle for Linux, macOS, and Windows.
#
# Contents:
#   <target>/llama.cpp/      upstream llama.cpp binary release
#   <target>/opencode/       upstream opencode binary release
#   <target>/whisper.cpp/    whisper source (Linux/macOS) or Windows binaries
#   <target>/install.*       localhost-only user install
#   <target>/start.*         foreground localhost-only launchers
#   local-luna/              concise manual LM Studio / llama.cpp tutorial
#   vscode/                  latest llama.vscode VSIX + settings helpers
#   lm-studio/               latest LM Studio desktop installers
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
have rsync || die "rsync is required"

TARGETS=()
OUT=""
LLAMACPP_TAG="${LLAMACPP_TAG:-}"
OPENCODE_TAG="${OPENCODE_TAG:-}"
WHISPER_TAG="${WHISPER_TAG:-}"
SKIP_MODEL="${SKIP_MODEL:-false}"
SKIP_LMSTUDIO="${SKIP_LMSTUDIO:-false}"
LOCAL_LUNA_SOURCE="${LOCAL_LUNA_SOURCE:-${HOME}/code/computor-dev/local-luna}"
BUNDLE_CACHE_DIR="${BUNDLE_CACHE_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --llamacpp-tag) LLAMACPP_TAG="$2"; shift 2 ;;
    --opencode-tag) OPENCODE_TAG="$2"; shift 2 ;;
    --whisper-tag) WHISPER_TAG="$2"; shift 2 ;;
    --skip-model) SKIP_MODEL=true; shift ;;
    --skip-lmstudio) SKIP_LMSTUDIO=true; shift ;;
    --local-luna-source) LOCAL_LUNA_SOURCE="$2"; shift 2 ;;
    all) TARGETS=(linux-cuda mac-m1 windows-arc); shift ;;
    linux-cuda|mac-m1|windows-arc) TARGETS+=("$1"); shift ;;
    -h|--help) sed -n '1,36p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${OUT}" ]] || die "--out is required"
[[ "${#TARGETS[@]}" -gt 0 ]] || die "target required: linux-cuda|mac-m1|windows-arc|all"
mkdir -p "${OUT}/models"
if [[ -z "${BUNDLE_CACHE_DIR}" ]]; then
  BUNDLE_CACHE_DIR="${OUT}/.slopcode-build-cache"
fi
mkdir -p "${BUNDLE_CACHE_DIR}/downloads"

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

sync_dir() {
  local src="$1" dest="$2"
  mkdir -p "${dest}"
  rsync -aL --delete "${src%/}/" "${dest%/}/"
}

prune_dir_entries() {
  local dir="$1"; shift
  [[ -d "${dir}" ]] || return 0
  local entry base keep allowed
  for entry in "${dir}"/* "${dir}"/.[!.]* "${dir}"/..?*; do
    [[ -e "${entry}" ]] || continue
    base="$(basename "${entry}")"
    keep=false
    for allowed in "$@"; do
      if [[ "${base}" == "${allowed}" ]]; then
        keep=true
        break
      fi
    done
    [[ "${keep}" == true ]] || rm -rf "${entry}"
  done
}

cache_path_for_url() {
  python3 - "$1" "${BUNDLE_CACHE_DIR}/downloads" <<'PY'
import hashlib
import os
import sys
from urllib.parse import urlparse

url, cache_dir = sys.argv[1:]
path = urlparse(url).path
base = os.path.basename(path) or "download"
digest = hashlib.sha256(url.encode()).hexdigest()[:16]
print(os.path.join(cache_dir, f"{digest}-{base}"))
PY
}

download_cached() {
  local url="$1" label="$2" cache
  cache="$(cache_path_for_url "${url}")"
  if [[ -f "${cache}" ]]; then
    echo "using cached ${label}" >&2
    printf '%s\n' "${cache}"
    return 0
  fi
  echo "downloading ${label}" >&2
  if [[ -f "${cache}.partial" ]]; then
    curl "${CURL_OPTS[@]}" -L -C - -o "${cache}.partial" "${url}"
  else
    curl "${CURL_OPTS[@]}" -L -o "${cache}.partial" "${url}"
  fi
  mv "${cache}.partial" "${cache}"
  printf '%s\n' "${cache}"
}

fetch_archive() {
  local url="$1" dest="$2" marker="${3:-}"
  local tmp inner archive
  tmp="$(mktemp -d)"
  mkdir -p "${dest}" "${tmp}/unpacked"
  archive="$(download_cached "${url}" "$(basename "${dest}") archive")"
  case "${archive}" in
    *.tar.gz|*.tgz) tar -xzf "${archive}" -C "${tmp}/unpacked" ;;
    *.tar.xz)       tar -xJf "${archive}" -C "${tmp}/unpacked" ;;
    *.zip)          unzip -q -o "${archive}" -d "${tmp}/unpacked" ;;
    *) die "unknown archive: ${archive}" ;;
  esac
  if [[ -n "${marker}" ]]; then
    inner="$(find "${tmp}/unpacked" -type f -name "${marker}" -print -quit | xargs -r dirname)"
  else
    inner="$(find "${tmp}/unpacked" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  fi
  [[ -n "${inner}" && -d "${inner}" ]] || inner="${tmp}/unpacked"
  sync_dir "${inner}" "${dest}"
  rm -rf "${tmp}"
}

fetch_whisper_source() {
  local dest="$1" tag="$2" url
  mkdir -p "${dest}"
  if [[ -z "${tag}" ]]; then
    tag="$(curl "${CURL_OPTS[@]}" https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"])')"
  fi
  url="https://github.com/ggml-org/whisper.cpp/archive/refs/tags/${tag}.tar.gz"
  echo "whisper.cpp source ${tag}"
  fetch_archive "${url}" "${dest}"
}

copy_model_alias() {
  # Copy only the files this alias resolves to: the primary GGUF + its mmproj.
  # Do NOT glob *.gguf in the cache dir — sibling files (e.g. older quants of
  # the same repo we still serve from a running llama-server) must not leak
  # onto the USB.
  local alias="$1" required="$2" primary mmproj
  primary="$(python3 "${SCRIPT_DIR}/llamacpp_models.py" resolve "${alias}" 2>/dev/null || true)"
  if [[ -z "${primary}" || ! -f "${primary}" ]]; then
    [[ "${required}" == true ]] && die "model ${alias} missing; run: python3 scripts/llamacpp_models.py prefetch ${alias}"
    return 0
  fi
  echo "copying ${alias} ($(basename "${primary}"))"
  if [[ ! -f "${OUT}/models/$(basename "${primary}")" ]]; then
    rsync -a --ignore-existing "${primary}" "${OUT}/models/"
  fi
  local pbn
  pbn="$(basename "${primary}")"
  sha256sum "${primary}" | awk '{print $1}' > "${OUT}/models/${pbn}.sha256"
  mmproj="$(python3 "${SCRIPT_DIR}/llamacpp_models.py" resolve-mmproj "${alias}" 2>/dev/null || true)"
  if [[ -n "${mmproj}" && -f "${mmproj}" ]]; then
    local mbn
    mbn="$(basename "${mmproj}")"
    echo "  + mmproj ${mbn}"
    if [[ ! -f "${OUT}/models/${mbn}" ]]; then
      rsync -a --ignore-existing "${mmproj}" "${OUT}/models/"
    fi
    sha256sum "${mmproj}" | awk '{print $1}' > "${OUT}/models/${mbn}.sha256"
  fi
}

copy_models() {
  [[ "${SKIP_MODEL}" == true ]] && return 0
  prune_dir_entries "${OUT}/models" \
    Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \
    Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf.sha256 \
    mmproj-BF16.gguf \
    mmproj-BF16.gguf.sha256 \
    ggml-large-v3-turbo.bin \
    ggml-large-v3-turbo.bin.partial
  copy_model_alias qwen3.6-35b-a3b-q4 true
  local model="${OUT}/models/ggml-large-v3-turbo.bin"
  if [[ ! -f "${model}" ]]; then
    download_file \
      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin \
      "${model}" "whisper large-v3-turbo"
  fi
}

download_file() {
  local url="$1" dest="$2" label="$3"
  mkdir -p "$(dirname "${dest}")"
  if [[ -f "${dest}" ]]; then
    local status
    echo "checking ${label}"
    rm -f "${dest}.partial"
    status="$(curl "${CURL_OPTS[@]}" -L -z "${dest}" -w '%{http_code}' -o "${dest}.partial" "${url}")"
    if [[ "${status}" == "304" || ! -s "${dest}.partial" ]]; then
      rm -f "${dest}.partial"
      echo "up to date: ${label}"
      return 0
    fi
    mv "${dest}.partial" "${dest}"
    return 0
  fi
  echo "downloading ${label}"
  if [[ -f "${dest}.partial" ]]; then
    curl "${CURL_OPTS[@]}" -L -C - -o "${dest}.partial" "${url}"
  else
    curl "${CURL_OPTS[@]}" -L -o "${dest}.partial" "${url}"
  fi
  mv "${dest}.partial" "${dest}"
}

download_lmstudio_installers() {
  [[ "${SKIP_LMSTUDIO}" == true ]] && return 0
  local d="${OUT}/lm-studio"
  mkdir -p "${d}"
  prune_dir_entries "${d}" \
    LM-Studio-mac-arm64-latest.dmg \
    LM-Studio-windows-x64-latest.exe \
    LM-Studio-windows-arm64-latest.exe \
    LM-Studio-linux-x64-latest.AppImage \
    LM-Studio-linux-x64-latest.deb \
    LM-Studio-linux-arm64-latest.AppImage \
    SHA256SUMS
  download_file "https://lmstudio.ai/download/latest/darwin/arm64" \
    "${d}/LM-Studio-mac-arm64-latest.dmg" "LM Studio macOS arm64"
  download_file "https://lmstudio.ai/download/latest/win32/x64" \
    "${d}/LM-Studio-windows-x64-latest.exe" "LM Studio Windows x64"
  download_file "https://lmstudio.ai/download/latest/win32/arm64" \
    "${d}/LM-Studio-windows-arm64-latest.exe" "LM Studio Windows arm64"
  download_file "https://lmstudio.ai/download/latest/linux/x64?format=AppImage" \
    "${d}/LM-Studio-linux-x64-latest.AppImage" "LM Studio Linux x64 AppImage"
  download_file "https://lmstudio.ai/download/latest/linux/x64?format=deb" \
    "${d}/LM-Studio-linux-x64-latest.deb" "LM Studio Linux x64 deb"
  download_file "https://lmstudio.ai/download/latest/linux/arm64?format=AppImage" \
    "${d}/LM-Studio-linux-arm64-latest.AppImage" "LM Studio Linux arm64 AppImage"
  rm -f "${d}/SHA256SUMS"
  sha256sum "${d}"/* > "${d}/SHA256SUMS"
}

download_llama_vscode() {
  local d="${OUT}/vscode"
  local dest="${d}/llama-vscode-latest.vsix"
  mkdir -p "${d}"
  echo "checking latest llama.vscode VSIX"
  rm -f "${dest}.partial"
  if [[ -f "${dest}" ]]; then
    local status
    status="$(curl "${CURL_OPTS[@]}" --compressed -L -z "${dest}" -w '%{http_code}' \
      -o "${dest}.partial" \
      "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ggml-org/vsextensions/llama-vscode/latest/vspackage")"
    if [[ "${status}" == "304" || ! -s "${dest}.partial" ]]; then
      rm -f "${dest}.partial"
      echo "up to date: llama.vscode VSIX"
      return 0
    fi
  else
    curl "${CURL_OPTS[@]}" --compressed -L \
      -o "${dest}.partial" \
      "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ggml-org/vsextensions/llama-vscode/latest/vspackage"
  fi
  mv "${dest}.partial" "${dest}"
}

write_vscode_helpers() {
  local d="${OUT}/vscode"
  mkdir -p "${d}"
  prune_dir_entries "${d}" \
    llama-vscode-latest.vsix \
    settings.llamacpp.json \
    configure-llama-vscode.sh \
    configure-llama-vscode.ps1 \
    configure-llama-vscode.bat \
    README.md
  cat >"${d}/settings.llamacpp.json" <<'EOF'
{
  "llama-vscode.endpoint": "http://127.0.0.1:8080",
  "llama-vscode.endpoint_chat": "http://127.0.0.1:8080",
  "llama-vscode.endpoint_tools": "http://127.0.0.1:8080",
  "llama-vscode.ai_api_version": "v1",
  "llama-vscode.ai_model": "qwen"
}
EOF
  cat >"${d}/configure-llama-vscode.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
code --install-extension "${HERE}/llama-vscode-latest.vsix"
case "$(uname -s)" in
  Darwin) SETTINGS="${HOME}/Library/Application Support/Code/User/settings.json" ;;
  *) SETTINGS="${XDG_CONFIG_HOME:-${HOME}/.config}/Code/User/settings.json" ;;
esac
mkdir -p "$(dirname "${SETTINGS}")"
python3 - "${SETTINGS}" "${HERE}/settings.llamacpp.json" <<'PY'
import json
import os
import sys

settings_path, patch_path = sys.argv[1:]
try:
    with open(settings_path, encoding="utf-8") as f:
        settings = json.load(f)
except Exception:
    settings = {}
with open(patch_path, encoding="utf-8") as f:
    settings.update(json.load(f))
with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PY
echo "configured llama.vscode for http://127.0.0.1:8080"
EOF
  chmod +x "${d}/configure-llama-vscode.sh"
  cat >"${d}/configure-llama-vscode.ps1" <<'EOF'
$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
code --install-extension (Join-Path $Here "llama-vscode-latest.vsix")
$Settings = Join-Path $env:APPDATA "Code\User\settings.json"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Settings) | Out-Null
function ConvertTo-Hashtable($Object) {
  $Hash = @{}
  if ($null -eq $Object) { return $Hash }
  foreach ($Prop in $Object.PSObject.Properties) {
    $Hash[$Prop.Name] = $Prop.Value
  }
  return $Hash
}
if (Test-Path $Settings) {
  $Current = ConvertTo-Hashtable (Get-Content $Settings -Raw | ConvertFrom-Json)
} else {
  $Current = @{}
}
$Patch = ConvertTo-Hashtable (Get-Content (Join-Path $Here "settings.llamacpp.json") -Raw | ConvertFrom-Json)
foreach ($Key in $Patch.Keys) { $Current[$Key] = $Patch[$Key] }
$Current | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $Settings
Write-Host "configured llama.vscode for http://127.0.0.1:8080"
EOF
  cat >"${d}/configure-llama-vscode.bat" <<'EOF'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0configure-llama-vscode.ps1"
exit /b %ERRORLEVEL%
EOF
  cat >"${d}/README.md" <<'EOF'
# VS Code llama.vscode

Install the bundled extension:

```sh
code --install-extension llama-vscode-latest.vsix
```

Then apply the localhost settings:

```sh
bash configure-llama-vscode.sh
```

Windows PowerShell:

```powershell
.\configure-llama-vscode.ps1
```

Windows Command Prompt:

```bat
configure-llama-vscode.bat
```

The settings point chat, tools, and completion requests at the bundled
llama.cpp server on `http://127.0.0.1:8080`; the extension appends `/v1`
for OpenAI-compatible chat calls.
EOF
}

copy_local_luna() {
  local d="${OUT}/local-luna"
  rm -rf "${d}"
  if [[ ! -d "${LOCAL_LUNA_SOURCE}" ]]; then
    warn "local-luna source not found: ${LOCAL_LUNA_SOURCE}"
    mkdir -p "${d}"
    cat >"${d}/README.md" <<'EOF'
# Local Luna

The local-luna tutorial was not available on this build host. Use the bundled
llama.cpp installer scripts, or rebuild with `--local-luna-source PATH`.
EOF
    return 0
  fi
  mkdir -p "${d}"
  rsync -a --delete --exclude .git "${LOCAL_LUNA_SOURCE%/}/" "${d}/"
}

write_simple_platform_readme() {
  local target="$1" title="$2" installer="$3" prewarm="$4"
  cat >"${target}/README.md" <<EOF
# ${title}

## Automatic llama.cpp install

Run the installer in this folder:

\`\`\`sh
${installer}
\`\`\`

It copies the bundled llama.cpp, OpenCode, and model files into your user
profile, binds llama.cpp to \`127.0.0.1:8080\`, and writes the OpenCode local
provider config.

## Manual or LM Studio path

Open \`../local-luna/README.md\`. That tutorial is the maintained step-by-step
path for people who prefer LM Studio or want to configure each piece by hand.

## VS Code

Open \`../vscode/README.md\` to install the bundled llama.vscode extension and
point it at the local llama.cpp server.

## Startup prewarm

The llama.cpp startup script launches one non-editing OpenCode request after
the server is ready. To disable it, comment out the prewarm line in the startup
script. To run it manually:

\`\`\`sh
${prewarm}
\`\`\`

## LM Studio fallback

Current LM Studio installers are in \`../lm-studio/\`. They are included for
manual fallback only; these scripts do not auto-wire LM Studio.
EOF
}

write_common_unix_files() {
  local t="$1"
  install -m 755 "${SCRIPT_DIR}/opencode_privacy.sh" "${t}/opencode_privacy.sh"
  install -m 755 "${SCRIPT_DIR}/llamacpp_prewarm_opencode.sh" "${t}/prewarm-opencode.sh"
  sync_dir "${SCRIPT_DIR}/../meeting" "${t}/meeting"
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
export PATH="${HERE}/opencode:${PATH}"
export LD_LIBRARY_PATH="${HERE}/llama.cpp${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
# Comment the next line to disable startup OpenCode prewarm.
"${HERE}/prewarm-opencode.sh" --no-start >/tmp/slopcode-opencode-prewarm.log 2>&1 &
exec "${HERE}/llama.cpp/llama-server" \
  -m "${HERE}/../models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" \
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
         -m "$HOME/.local/slopcode/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" \
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
cp "${HERE}/prewarm-opencode.sh" "${DEST}/prewarm-opencode.sh"
cp -n "${ROOT}/models/"*.gguf "${DEST}/models/"
ln -sf "${DEST}/opencode/opencode" "${HOME}/.local/bin/opencode"
bash "${HERE}/opencode_privacy.sh"

cat >"${DEST}/run-llamacpp.sh" <<RUN
#!/usr/bin/env bash
export PATH="${DEST}/opencode:${HOME}/.local/bin:\${PATH}"
export LD_LIBRARY_PATH="${DEST}/llama.cpp\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
# Comment the next line to disable startup OpenCode prewarm.
"${DEST}/prewarm-opencode.sh" --no-start >/tmp/slopcode-opencode-prewarm.log 2>&1 &
exec "${DEST}/llama.cpp/llama-server" -m "${DEST}/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" --mmproj "${DEST}/models/mmproj-BF16.gguf" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads 4 --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui --host 127.0.0.1 --port 8080
RUN
chmod +x "${DEST}/run-llamacpp.sh" "${DEST}/prewarm-opencode.sh"

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
       <string>-m</string><string>HOME_PATH/Library/Application Support/slopcode/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf</string>
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
cp "${HERE}/prewarm-opencode.sh" "${DEST}/prewarm-opencode.sh"
cp -n "${ROOT}/models/"*.gguf "${DEST}/models/"
ln -sf "${DEST}/opencode/opencode" "${HOME}/.local/bin/opencode"
bash "${HERE}/opencode_privacy.sh"

cat >"${DEST}/run-llamacpp.sh" <<RUN
#!/usr/bin/env bash
export PATH="${DEST}/opencode:${HOME}/.local/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:\${PATH}"
export DYLD_LIBRARY_PATH="${DEST}/llama.cpp\${DYLD_LIBRARY_PATH:+:\${DYLD_LIBRARY_PATH}}"
# Comment the next line to disable startup OpenCode prewarm.
"${DEST}/prewarm-opencode.sh" --no-start >/tmp/slopcode-opencode-prewarm.log 2>&1 &
exec "${DEST}/llama.cpp/llama-server" -m "${DEST}/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" --mmproj "${DEST}/models/mmproj-BF16.gguf" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on -np 1 --alias qwen --jinja --reasoning on --reasoning-budget 4096 --no-context-shift --no-webui --host 127.0.0.1 --port 8080
RUN
chmod +x "${DEST}/run-llamacpp.sh" "${DEST}/prewarm-opencode.sh"

LLAMA_PLIST="${AGENTS}/com.slopcode.llamacpp.plist"
cat >"${LLAMA_PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.slopcode.llamacpp</string>
<key>ProgramArguments</key><array>
<string>${DEST}/run-llamacpp.sh</string>
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
  install -m 644 "${SCRIPT_DIR}/llamacpp_prewarm_opencode.bat" "${t}/prewarm-opencode.bat"
  sync_dir "${SCRIPT_DIR}/../meeting" "${t}/meeting"

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
       REM Intel Arc Vulkan stability workarounds:
       REM   GGML_VK_DISABLE_COOPMAT / COOPMAT2 -- Arc 140V Xe2 KHR_coopmat TDR (ggml-org/llama.cpp#20554)
       REM   GGML_VK_DISABLE_F16                -- Intel iGPU F16 acc NaN/garbage (#18969)
       set "GGML_VK_DISABLE_COOPMAT=1"
       set "GGML_VK_DISABLE_COOPMAT2=1"
       set "GGML_VK_DISABLE_F16=1"
       set "PATH=%USERPROFILE%\slopcode\llama.cpp;%PATH%"
       "%USERPROFILE%\slopcode\llama.cpp\llama-server.exe" -m "%USERPROFILE%\slopcode\models\Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" --mmproj "%USERPROFILE%\slopcode\models\mmproj-BF16.gguf" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 512 -ngl 99 -fa on -np 1 --threads 6 --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui --host 127.0.0.1 --port 8080

   On Arc 140V (Lunar Lake, 4P + 4LP = 8 physical cores) --threads 6 is
   the right value (physical - 2). On other Arc hosts substitute
   physical-cores - 2 (min 2).

   No --cpu-moe / --n-cpu-moe: all 40 MoE expert layers stay on the Arc
   iGPU together with attention + KV + DeltaNet. On a Core Ultra 7
   with 64 GB unified RAM and the "Shared GPU Memory Override" raised
   to 32 GB this is meaningfully faster than --cpu-moe; if you hit
   Vulkan OOM on a smaller host, add "--n-cpu-moe 20" (or higher up
   to 40 = --cpu-moe) to push expert layers back to CPU.

7. Create the CPU fallback launcher
   %USERPROFILE%\slopcode\run-llamacpp-cpu.bat with this exact
   content. Same Notepad steps as above:

       @echo off
       set "PATH=%USERPROFILE%\slopcode\llama.cpp;%PATH%"
       "%USERPROFILE%\slopcode\llama.cpp\llama-server.exe" -m "%USERPROFILE%\slopcode\models\Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -ngl 0 -np 1 --threads 6 --threads-http 2 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui --host 127.0.0.1 --port 8080

8. Create the whisper launcher %USERPROFILE%\slopcode\run-whisper.bat
   with this exact content:

       @echo off
       set "PATH=%USERPROFILE%\slopcode\whisper.cpp;%PATH%"
       "%USERPROFILE%\slopcode\whisper.cpp\whisper-server.exe" -m "%USERPROFILE%\slopcode\models\ggml-large-v3-turbo.bin" --host 127.0.0.1 --port 8427 -l auto -t 4 -fa --inference-path /v1/audio/transcriptions --convert --tmp-dir "%TEMP%"

9. Create the opencode config. In Command Prompt:

       > mkdir "%USERPROFILE%\.config\opencode"

   Then open Notepad and paste this exact content (one long line):

       {"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B Q4 (Arc)","limit":{"context":131072,"output":16384},"reasoning":true,"interleaved":{"field":"reasoning_content"},"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}

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

run-llamacpp.bat       Vulkan GPU build, era-1 safe profile
                       (all 40 MoE expert layers on the Arc iGPU;
                       no --cpu-moe / --n-cpu-moe). Tuned for
                       Core Ultra 7 with 64 GB unified RAM and
                       "Shared GPU Memory Override" raised to 32 GB.
                       Sets three stability env vars:
                         GGML_VK_DISABLE_COOPMAT/COOPMAT2 -- Arc 140V Xe2
                           KHR_coopmat TDR bug (ggml-org/llama.cpp#20554)
                         GGML_VK_DISABLE_F16             -- Intel iGPU
                           F16 accumulator NaN bug (#18969)
                       -c 131072, -ub 512, q8_0 KV.
                       If Vulkan OOM on a smaller host, add
                       "--n-cpu-moe 20" (or higher, up to 40 =
                       --cpu-moe) to push experts back to CPU.
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
The three GGML_VK_DISABLE_* env vars in run-llamacpp.bat already cover
the known coopmat (140V Xe2) and F16-acc (155H Xe-LPG) bugs. If you
still see garbage:

1. Confirm the env vars actually took effect: in the llama-server
   startup banner you should see "matrix cores: none" (not
   "KHR_coopmat"). If it shows KHR_coopmat, the env vars aren't being
   read - launch from the same Command Prompt that the bat file sets up.

2. Try bumping the KV cache to bf16 (slower, doubles memory, but Unsloth
   recommends it as the gibberish remedy). Edit run-llamacpp.bat and
   change "--cache-type-k q8_0 --cache-type-v q8_0" to
   "--cache-type-k bf16 --cache-type-v bf16". You may also need to
   drop -c from 131072 to 65536 to keep VRAM in budget.

3. Try disabling flash attention. Change "-fa on" to "-fa off". This
   trades performance for more conservative attention compute paths
   that have been better-behaved on Intel iGPUs historically.

4. Use the CPU fallback (run-llamacpp-cpu.bat). If that also produces
   garbage, the model file is corrupt - re-copy from the USB.
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
echo.
echo === Aggressive cleanup of any prior slopcode install ===
echo Stopping any running llama-server / opencode...
taskkill /F /IM llama-server.exe /T >nul 2>&1
taskkill /F /IM opencode.exe /T >nul 2>&1
REM Brief pause so Windows releases file handles before we rmdir.
ping -n 3 127.0.0.1 >nul 2>&1
echo Removing old Startup shortcuts...
del /Q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\slopcode-llamacpp.bat" 2>nul
del /Q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\slopcode-whisper.bat" 2>nul
echo Removing old launchers and opencode config...
del /Q "%DEST%\run-llamacpp.bat" 2>nul
del /Q "%DEST%\run-llamacpp-cpu.bat" 2>nul
del /Q "%DEST%\run-whisper.bat" 2>nul
del /Q "%USERPROFILE%\.config\opencode\opencode.json" 2>nul
echo Removing old llama.cpp + opencode dirs...
rmdir /S /Q "%DEST%\llama.cpp" 2>nul
rmdir /S /Q "%DEST%\opencode" 2>nul
echo Removing old GGUFs from %DEST%\models...
del /Q "%DEST%\models\*.gguf" 2>nul
del /Q "%DEST%\models\*.sha256" 2>nul
echo Clearing Intel shader cache...
rmdir /S /Q "%LOCALAPPDATA%\Intel\ShaderCache" 2>nul
echo === Cleanup done; installing fresh ===
echo.
mkdir "%DEST%\models" "%DEST%\llama.cpp" "%DEST%\opencode" "%DEST%\bin" "%DEST%\cache" 2>nul
xcopy /E /I /Y "%HERE%\llama.cpp" "%DEST%\llama.cpp" >nul
xcopy /E /I /Y "%HERE%\opencode" "%DEST%\opencode" >nul
copy /Y "%ROOT%\models\*.gguf" "%DEST%\models\" >nul
copy /Y "%HERE%\prewarm-opencode.bat" "%DEST%\bin\prewarm-opencode.bat" >nul
setx OPENCODE_DISABLE_AUTOUPDATE 1 >nul
setx OPENCODE_DISABLE_SHARE 1 >nul
setx OPENCODE_DISABLE_MODELS_FETCH 1 >nul
setx OPENCODE_DISABLE_LSP_DOWNLOAD 1 >nul
setx OPENCODE_DISABLE_DEFAULT_PLUGINS 1 >nul
setx OPENCODE_DISABLE_EMBEDDED_WEB_UI 1 >nul
set "MODEL=%DEST%\models\Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
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
>>"%DEST%\run-llamacpp.bat" echo REM Intel Arc Vulkan stability workarounds:
>>"%DEST%\run-llamacpp.bat" echo REM   GGML_VK_DISABLE_COOPMAT / COOPMAT2 -- Arc 140V Xe2 KHR_coopmat TDR ^(ggml-org/llama.cpp#20554^)
>>"%DEST%\run-llamacpp.bat" echo REM   GGML_VK_DISABLE_F16                -- Intel iGPU F16 acc NaN/garbage ^(#18969^)
>>"%DEST%\run-llamacpp.bat" echo set "GGML_VK_DISABLE_COOPMAT=1"
>>"%DEST%\run-llamacpp.bat" echo set "GGML_VK_DISABLE_COOPMAT2=1"
>>"%DEST%\run-llamacpp.bat" echo set "GGML_VK_DISABLE_F16=1"
>>"%DEST%\run-llamacpp.bat" echo set "PATH=%DEST%\llama.cpp;%%PATH%%"
>>"%DEST%\run-llamacpp.bat" echo REM Comment the next line to disable startup OpenCode prewarm.
>>"%DEST%\run-llamacpp.bat" echo start "slopcode-opencode-prewarm" /MIN "%DEST%\bin\prewarm-opencode.bat" --no-start
>>"%DEST%\run-llamacpp.bat" echo "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" --mmproj "%MMPROJ%" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 512 -ngl 99 -fa on -np 1 --threads !THREADS! --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui --host 127.0.0.1 --port 8080
>"%DEST%\run-llamacpp-cpu.bat" echo @echo off
>>"%DEST%\run-llamacpp-cpu.bat" echo set "PATH=%DEST%\llama.cpp;%%PATH%%"
>>"%DEST%\run-llamacpp-cpu.bat" echo REM Comment the next line to disable startup OpenCode prewarm.
>>"%DEST%\run-llamacpp-cpu.bat" echo start "slopcode-opencode-prewarm" /MIN "%DEST%\bin\prewarm-opencode.bat" --no-start
>>"%DEST%\run-llamacpp-cpu.bat" echo "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -ngl 0 -np 1 --threads !THREADS! --threads-http 2 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --no-webui --host 127.0.0.1 --port 8080
mkdir "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup" 2>nul
>"%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\slopcode-llamacpp.bat" echo start "slopcode-llamacpp" /MIN "%DEST%\run-llamacpp.bat"
mkdir "%USERPROFILE%\.config\opencode" 2>nul
>"%USERPROFILE%\.config\opencode\opencode.json" echo {"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B Q4 (Arc)","limit":{"context":131072,"output":16384},"reasoning":true,"interleaved":{"field":"reasoning_content"},"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}
powershell -NoProfile -Command "$p=[Environment]::GetEnvironmentVariable('Path','User'); $adds=@('%DEST%\opencode','%DEST%\bin'); foreach($add in $adds){ if (($p -split ';') -notcontains $add) { $p=($add+';'+$p) } }; [Environment]::SetEnvironmentVariable('Path', $p, 'User')"
start "slopcode-llamacpp" /MIN "%DEST%\run-llamacpp.bat"
echo Installed localhost-only llama.cpp 8080 and opencode (--threads !THREADS!).
echo (whisper/meeting tools are shipped on the USB but not auto-installed.)
echo If you see repeated slashes in opencode thinking, run: %DEST%\run-llamacpp-cpu.bat
echo and update the Startup shortcut to point at run-llamacpp-cpu.bat instead.
echo To run the OpenCode startup prewarm manually: %DEST%\bin\prewarm-opencode.bat
echo Open a new terminal before running opencode.
EOF
}

copy_models
for target in "${TARGETS[@]}"; do
  case "${target}" in
    linux-cuda)
      write_linux
      write_simple_platform_readme "${OUT}/linux-cuda" "slopcode for Linux (NVIDIA CUDA)" "bash install.sh" "./prewarm-opencode.sh"
      prune_dir_entries "${OUT}/linux-cuda" llama.cpp opencode whisper.cpp opencode_privacy.sh prewarm-opencode.sh meeting start.sh README.md install.sh
      ;;
    mac-m1)
      write_mac
      write_simple_platform_readme "${OUT}/mac-m1" "slopcode for macOS (Apple Silicon)" "bash install.sh" "./prewarm-opencode.sh"
      prune_dir_entries "${OUT}/mac-m1" llama.cpp opencode whisper.cpp opencode_privacy.sh prewarm-opencode.sh meeting README.md install.sh
      ;;
    windows-arc)
      write_windows
      write_simple_platform_readme "${OUT}/windows-arc" "slopcode for Windows (Intel Arc, Vulkan)" ".\\install.bat" ".\\prewarm-opencode.bat"
      prune_dir_entries "${OUT}/windows-arc" llama.cpp opencode whisper.cpp meeting verify-models.ps1 prewarm-opencode.bat README.md install.bat
      ;;
  esac
done

copy_local_luna
download_llama_vscode
write_vscode_helpers
download_lmstudio_installers

cat >"${OUT}/README.md" <<'EOF'
# slopcode USB bundle

A local AI coding bundle. The primary automatic path is llama.cpp + OpenCode on
localhost. LM Studio is included as a manual fallback.

## Automatic llama.cpp path

Open your platform folder and run its installer:

- `linux-cuda/`
- `mac-m1/`
- `windows-arc/`

Each installer binds llama.cpp to `127.0.0.1:8080` and configures OpenCode for
that local endpoint.

## Manual or LM Studio path

Open `local-luna/README.md`.

That tutorial is copied onto this stick for people who want step-by-step setup,
or who prefer LM Studio instead of the automatic llama.cpp scripts.

## VS Code

Open `vscode/README.md` to install the bundled latest llama.vscode extension
and apply settings for the local llama.cpp server.

## LM Studio installers

Current LM Studio desktop installers are in `lm-studio/`. They are included for
manual fallback only; the slopcode scripts use llama.cpp by default.
EOF

echo "bundle ready at ${OUT}"
