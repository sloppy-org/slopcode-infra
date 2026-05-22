#!/usr/bin/env bash
# Build a USB-ready slopcode bundle for Linux, macOS, and Windows.
#
# Contents:
#   <target>/llama.cpp/      upstream llama.cpp binary release
#   <target>/opencode/       upstream opencode binary release
#   <target>/whisper.cpp/    whisper source (Linux/macOS) or Windows binaries
#   <target>/install.*       localhost-only user install
#   <target>/start.*         foreground localhost-only launchers
#   local-luna/              concise manual llama.cpp tutorial
#   vscode/                  latest llama.vscode VSIX + settings helpers
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
RIPGREP_TAG="${RIPGREP_TAG:-}"
FD_TAG="${FD_TAG:-}"
JQ_TAG="${JQ_TAG:-}"
SHELLCHECK_TAG="${SHELLCHECK_TAG:-}"
YQ_TAG="${YQ_TAG:-}"
DELTA_TAG="${DELTA_TAG:-}"
DUCKDB_TAG="${DUCKDB_TAG:-}"
XQ_TAG="${XQ_TAG:-}"
SQLITE_TOOLS_WIN_URL="${SQLITE_TOOLS_WIN_URL:-https://www.sqlite.org/2026/sqlite-tools-win-x64-3530100.zip}"
SKIP_MODEL="${SKIP_MODEL:-false}"
LOCAL_LUNA_SOURCE="${LOCAL_LUNA_SOURCE:-${HOME}/code/computor-dev/local-luna}"
BUNDLE_CACHE_DIR="${BUNDLE_CACHE_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --llamacpp-tag) LLAMACPP_TAG="$2"; shift 2 ;;
    --opencode-tag) OPENCODE_TAG="$2"; shift 2 ;;
    --whisper-tag) WHISPER_TAG="$2"; shift 2 ;;
    --ripgrep-tag) RIPGREP_TAG="$2"; shift 2 ;;
    --skip-model) SKIP_MODEL=true; shift ;;
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
  # Persistent cache survives USB swaps and bundle rebuilds. Override
  # with BUNDLE_CACHE_DIR=<path> for one-off builds.
  BUNDLE_CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/slopcode-bundle"
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

# Download a GitHub release asset (tar.gz/tar.xz/zip), extract it, and
# install one binary from the archive into <target>/bin/<out_name>.
# Args: target_dir repo tag suffix archive_member out_name
fetch_github_binary() {
  local target_dir="$1" repo="$2" tag="$3" suffix="$4" member="$5" out="$6"
  local rel_tag url archive tmp inner
  read -r rel_tag url <<<"$(github_asset "${repo}" "${tag}" "${suffix}")"
  echo "${repo} ${rel_tag} (${suffix} -> ${out})"
  archive="$(download_cached "${url}" "${repo} ${suffix}")"
  tmp="$(mktemp -d)"
  case "${archive}" in
    *.tar.gz|*.tgz) tar -xzf "${archive}" -C "${tmp}" ;;
    *.tar.xz)       tar -xJf "${archive}" -C "${tmp}" ;;
    *.zip)          unzip -q -o "${archive}" -d "${tmp}" ;;
    *) die "unknown archive: ${archive}" ;;
  esac
  inner="$(find "${tmp}" -type f -name "${member}" -print -quit)"
  [[ -n "${inner}" && -f "${inner}" ]] || die "${member} not found in ${archive}"
  mkdir -p "${target_dir}/bin"
  install -m 755 "${inner}" "${target_dir}/bin/${out}"
  rm -rf "${tmp}"
}

# Download a bare GitHub release binary (no archive) directly into
# <target>/bin/<out_name>. Used for jq, which ships unwrapped binaries.
# Args: target_dir repo tag suffix out_name
fetch_github_bare() {
  local target_dir="$1" repo="$2" tag="$3" suffix="$4" out="$5"
  local rel_tag url cache
  read -r rel_tag url <<<"$(github_asset "${repo}" "${tag}" "${suffix}")"
  echo "${repo} ${rel_tag} (${suffix} -> ${out})"
  cache="$(download_cached "${url}" "${repo} ${suffix}")"
  mkdir -p "${target_dir}/bin"
  install -m 755 "${cache}" "${target_dir}/bin/${out}"
}

# Download a non-GitHub archive (sqlite.org), extract, install one binary.
# Args: target_dir url label archive_member out_name
fetch_direct_binary() {
  local target_dir="$1" url="$2" label="$3" member="$4" out="$5"
  local archive tmp inner
  echo "${label} (${url##*/} -> ${out})"
  archive="$(download_cached "${url}" "${label}")"
  tmp="$(mktemp -d)"
  case "${archive}" in
    *.zip)          unzip -q -o "${archive}" -d "${tmp}" ;;
    *.tar.gz|*.tgz) tar -xzf "${archive}" -C "${tmp}" ;;
    *) die "unknown archive: ${archive}" ;;
  esac
  inner="$(find "${tmp}" -type f -name "${member}" -print -quit)"
  [[ -n "${inner}" && -f "${inner}" ]] || die "${member} not found in ${archive}"
  mkdir -p "${target_dir}/bin"
  install -m 755 "${inner}" "${target_dir}/bin/${out}"
  rm -rf "${tmp}"
}

# Bundle a shared offline-coding AGENTS.md hint at the target root.
# Copied into the install dir by install.sh / install.bat; colleagues
# can drop it into project roots so coding agents pick it up.
write_bundle_agents_md() {
  local target_dir="$1"
  cat >"${target_dir}/AGENTS.md" <<'AGENTSMD'
# AGENTS.md

Offline coding box. No network.

## Tools in PATH

`rg` text · `fd` files · `jq` JSON · `yq` YAML · `xq` XML · `sqlite3` and `duckdb` SQL · `shellcheck` bash lint · `delta` diff · `opencode` agent · `llama-server` :8080 · `whisper-server` :8427.

## Rules

- Terse. No filler. No emojis in code, commits, PRs, issues.
- Search text with `rg`, files with `fd`. Not `find` or `grep -r`.
- JSON/YAML/XML via `jq` / `yq` / `xq`. Tabular data via `sqlite3` or `duckdb`.
- `shellcheck` every bash script before declaring it done.
- No `curl | sh`, no `pip install`, no `npm install`, no `gh` / `glab`. Network is closed.
- Use repo tooling. Do not invent build or test commands.
- Stage paths explicitly. Never `git add .` or `git add -A`.
- Fix failing tests. Do not skip, weaken, or label them unrelated.
- Comments say why, not what.
- Never claim success without real command output.

## Endpoint

opencode points at `http://127.0.0.1:8080/v1` (alias `qwen`). Loopback only.
AGENTSMD
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
  # Single chat GGUF: Qwen3.6-35B-A3B UD-IQ4_XS from the MTP repo (~18 GB).
  # Carries the MTP head so the bundled launchers can use --spec-type
  # draft-mtp for the decode speedup; runs fine without the flag too if
  # MTP misbehaves on a particular host. No coder model, no XL variant.
  prune_dir_entries "${OUT}/models" \
    Qwen3.6-35B-A3B-UD-IQ4_XS.gguf \
    Qwen3.6-35B-A3B-UD-IQ4_XS.gguf.sha256 \
    mmproj-BF16.gguf \
    mmproj-BF16.gguf.sha256 \
    ggml-large-v3-turbo.bin \
    ggml-large-v3-turbo.bin.partial
  copy_model_alias qwen3.6-35b-a3b-mtp-iq4_xs true
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
    configure-llama-vscode.bat \
    README.md
  # llama.vscode settings pointing chat/tools at the local llama-server on
  # :8080. Same endpoint for every llama-vscode role (chat, tools, FIM) —
  # one localhost server, one model.
  cat >"${d}/settings.llamacpp.json" <<'EOF'
{
  "llama-vscode.endpoint": "http://127.0.0.1:8080",
  "llama-vscode.endpoint_chat": "http://127.0.0.1:8080",
  "llama-vscode.endpoint_tools": "http://127.0.0.1:8080",
  "llama-vscode.ai_api_version": "v1",
  "llama-vscode.ai_model": "qwen",
  "llama-vscode.api_key": "",
  "llama-vscode.n_predict": 128,
  "llama-vscode.t_max_prompt_ms": 500,
  "llama-vscode.t_max_predict_ms": 500,
  "llama-vscode.ring_n_chunks": 16,
  "llama-vscode.n_prefix": 256,
  "llama-vscode.n_suffix": 64
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
  cat >"${d}/configure-llama-vscode.bat" <<'EOF'
@echo off
setlocal
set "HERE=%~dp0"
code --install-extension "%HERE%llama-vscode-latest.vsix"
if errorlevel 1 exit /b 1
set "SETTINGS=%APPDATA%\Code\User\settings.json"
for %%I in ("%SETTINGS%") do mkdir "%%~dpI" 2>nul
where py >nul 2>&1 && (set "PYEXE=py -3") || (set "PYEXE=python")
%PYEXE% -c "import json,os,sys;p=sys.argv[1];q=sys.argv[2];s=json.load(open(p,encoding='utf-8')) if os.path.exists(p) else {};s.update(json.load(open(q,encoding='utf-8')));open(p,'w',encoding='utf-8').write(json.dumps(s,indent=2)+'\n')" "%SETTINGS%" "%HERE%settings.llamacpp.json"
if errorlevel 1 exit /b 1
echo configured llama.vscode for http://127.0.0.1:8080
endlocal
EOF
  cat >"${d}/README.md" <<'EOF'
# VS Code llama.vscode

Install the bundled extension and apply the localhost settings:

```sh
bash configure-llama-vscode.sh        # Linux / macOS
configure-llama-vscode.bat            # Windows
```

The settings point chat, tools, and autocomplete at the same local
llama.cpp server on `http://127.0.0.1:8080`. The bundle ships one
model: Qwen3.6-35B-A3B-IQ4_XS-MTP. Use it from OpenCode (agentic
coding) or directly from the llama.vscode panel.
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
  local target="$1" title="$2" installer="$3"
  cat >"${target}/README.md" <<EOF
# ${title}

## Automatic install

Run the installer in this folder:

\`\`\`sh
${installer}
\`\`\`

It copies the bundled llama.cpp, OpenCode, whisper.cpp, meeting tools, and
model files into your user profile. It starts llama.cpp on
\`127.0.0.1:8080\`, starts whisper.cpp on \`127.0.0.1:8427\`, and writes the
OpenCode local provider config.

The meeting workflow is local and expects PCM WAV input:

\`\`\`sh
meeting-transcribe meeting.wav
meeting-process meeting.wav
\`\`\`

## Manual path

Open \`../local-luna/README.md\` for a step-by-step manual setup that does
the same thing as this folder's automatic installer.

## VS Code llama.vscode

Open \`../vscode/README.md\` to install the bundled extension and point
it at the local llama.cpp server on \`127.0.0.1:8080\`.
EOF
}

write_common_unix_files() {
  local t="$1"
  install -m 644 "${SCRIPT_DIR}/_common.sh" "${t}/_common.sh"
  install -m 755 "${SCRIPT_DIR}/opencode_privacy.sh" "${t}/opencode_privacy.sh"
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
  fetch_github_binary "${t}" BurntSushi/ripgrep "${RIPGREP_TAG}" "-x86_64-unknown-linux-musl.tar.gz"  rg                rg
  fetch_github_binary "${t}" sharkdp/fd          "${FD_TAG}"      "-x86_64-unknown-linux-musl.tar.gz"  fd                fd
  fetch_github_bare   "${t}" jqlang/jq           "${JQ_TAG}"      "jq-linux-amd64"                                       jq
  fetch_github_binary "${t}" koalaman/shellcheck "${SHELLCHECK_TAG}" ".linux.x86_64.tar.xz"           shellcheck        shellcheck
  fetch_github_binary "${t}" mikefarah/yq        "${YQ_TAG}"      "yq_linux_amd64.tar.gz"             yq_linux_amd64    yq
  fetch_github_binary "${t}" dandavison/delta    "${DELTA_TAG}"   "-x86_64-unknown-linux-musl.tar.gz" delta             delta
  fetch_github_binary "${t}" duckdb/duckdb       "${DUCKDB_TAG}"  "duckdb_cli-linux-amd64.zip"        duckdb            duckdb
  fetch_github_binary "${t}" sibprogrammer/xq    "${XQ_TAG}"      "_linux_amd64.tar.gz"               xq                xq
  write_common_unix_files "${t}"
  write_bundle_agents_md "${t}"

  # Bundle-root preview launcher (no install). Loads the MTP-trained
  # IQ4_XS GGUF and enables --spec-type draft-mtp for the decode speedup.
  cat >"${t}/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${HERE}/bin:${HERE}/opencode:${PATH}"
export LD_LIBRARY_PATH="${HERE}/llama.cpp${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
exec "${HERE}/llama.cpp/llama-server" \
  -m "${HERE}/../models/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf" \
  --mmproj "${HERE}/../models/mmproj-BF16.gguf" \
  -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 \
  -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads 4 --threads-http 4 \
  --alias qwen --jinja \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
  --presence-penalty 0.0 --repeat-penalty 1.0 \
  --reasoning-format deepseek --reasoning-budget 4096 --reasoning on \
  --spec-type draft-mtp --spec-draft-n-max 2 \
  --no-context-shift --host 127.0.0.1 --port 8080
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

The automatic installer also installs whisper.cpp + meeting tools. The meeting
workflow expects PCM WAV input and does not require ffmpeg.


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
         -m "$HOME/.local/slopcode/models/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf" \
         --mmproj "$HOME/.local/slopcode/models/mmproj-BF16.gguf" \
         -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 \
         -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 \
         -np 1 --threads 4 --threads-http 4 \
         --alias qwen --jinja \
         --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
         --presence-penalty 0.0 --repeat-penalty 1.0 \
         --reasoning-format deepseek --reasoning-budget 4096 \
         --reasoning on --spec-type draft-mtp --spec-draft-n-max 2 \
         --no-context-shift --host 127.0.0.1 --port 8080

   Then:

       chmod +x ~/.local/slopcode/run-llamacpp.sh

8. Create the whisper launcher
   ~/.local/slopcode/run-whisper.sh with this exact content:

       #!/usr/bin/env bash
       exec "$HOME/.local/slopcode/whisper.cpp/build/bin/whisper-server" \
         -m "$HOME/.local/slopcode/models/ggml-large-v3-turbo.bin" \
         --host 127.0.0.1 --port 8427 -l auto -t 4 -fa \
         --inference-path /v1/audio/transcriptions \
         --tmp-dir /tmp

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
mkdir -p "${DEST}/models" "${DEST}/llama.cpp" "${DEST}/opencode" "${DEST}/whisper.cpp" "${DEST}/meeting" "${DEST}/bin" "${HOME}/.local/bin" "${HOME}/.config/systemd/user" "${HOME}/.config/opencode"
cp -R "${HERE}/llama.cpp/." "${DEST}/llama.cpp/"
cp -R "${HERE}/opencode/." "${DEST}/opencode/"
cp -R "${HERE}/whisper.cpp/." "${DEST}/whisper.cpp/"
cp -R "${HERE}/meeting/." "${DEST}/meeting/"
if [[ -d "${HERE}/bin" ]]; then cp -R "${HERE}/bin/." "${DEST}/bin/"; fi
[[ -f "${HERE}/AGENTS.md" ]] && cp "${HERE}/AGENTS.md" "${DEST}/AGENTS.md"
cp "${HERE}/_common.sh" "${DEST}/_common.sh"
cp -n "${ROOT}/models/"*.gguf "${DEST}/models/"
cp -n "${ROOT}/models/ggml-large-v3-turbo.bin" "${DEST}/models/"
ln -sf "${DEST}/opencode/opencode" "${HOME}/.local/bin/opencode"
for binname in rg fd jq yq xq shellcheck delta duckdb; do
  [[ -x "${DEST}/bin/${binname}" ]] && ln -sf "${DEST}/bin/${binname}" "${HOME}/.local/bin/${binname}"
done
chmod +x "${DEST}/meeting/"*.sh
ln -sf "${DEST}/meeting/record-meeting.sh" "${HOME}/.local/bin/record-meeting"
ln -sf "${DEST}/meeting/meeting-transcribe.sh" "${HOME}/.local/bin/meeting-transcribe"
ln -sf "${DEST}/meeting/meeting-notes.sh" "${HOME}/.local/bin/meeting-notes"
ln -sf "${DEST}/meeting/meeting-process.sh" "${HOME}/.local/bin/meeting-process"
bash "${HERE}/opencode_privacy.sh"

command -v cmake >/dev/null 2>&1 || { echo "cmake is required to build whisper.cpp" >&2; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "ninja is required to build whisper.cpp" >&2; exit 1; }
cmake -S "${DEST}/whisper.cpp" \
  -B "${DEST}/whisper.cpp/build" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_SERVER=1 \
  -DGGML_CUDA=1
cmake --build "${DEST}/whisper.cpp/build" -j"$(nproc)"

cat >"${DEST}/run-llamacpp.sh" <<RUN
#!/usr/bin/env bash
# Chat launcher: Qwen3.6-35B-A3B UD-IQ4_XS-MTP, c=131072, MTP draft-mtp
# enabled (delete --spec-type / --spec-draft-n-max if the host's backend
# misbehaves on the MTP path; the same GGUF runs without MTP at lower
# decode speed).
export PATH="${DEST}/opencode:${HOME}/.local/bin:\${PATH}"
export LD_LIBRARY_PATH="${DEST}/llama.cpp\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
exec "${DEST}/llama.cpp/llama-server" -m "${DEST}/models/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf" --mmproj "${DEST}/models/mmproj-BF16.gguf" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads 4 --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --reasoning on --spec-type draft-mtp --spec-draft-n-max 2 --no-context-shift --host 127.0.0.1 --port 8080
RUN
cat >"${DEST}/stop-llamacpp.sh" <<RUN
#!/usr/bin/env bash
set -euo pipefail
systemctl --user stop slopcode-llamacpp.service 2>/dev/null || true
pkill -f "${DEST}/llama.cpp/llama-server" 2>/dev/null || true
echo "stopped"
RUN
chmod +x "${DEST}/stop-llamacpp.sh"

cat >"${DEST}/run-whisper.sh" <<RUN
#!/usr/bin/env bash
exec "${DEST}/whisper.cpp/build/bin/whisper-server" \
  -m "${DEST}/models/ggml-large-v3-turbo.bin" \
  --host 127.0.0.1 --port 8427 -l auto -t 4 -fa \
  --inference-path /v1/audio/transcriptions \
  --tmp-dir /tmp
RUN
chmod +x "${DEST}/run-whisper.sh"

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
cat >"${HOME}/.config/opencode/opencode.json" <<JSON
{"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B MTP","limit":{"context":131072,"output":16384},"reasoning":true,"interleaved":{"field":"reasoning_content"},"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}
JSON
echo "installed: opencode + llama.cpp on 127.0.0.1:8080 + whisper.cpp on 127.0.0.1:8427"
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
  fetch_github_binary "${t}" BurntSushi/ripgrep "${RIPGREP_TAG}" "-aarch64-apple-darwin.tar.gz" rg                rg
  fetch_github_binary "${t}" sharkdp/fd          "${FD_TAG}"      "-aarch64-apple-darwin.tar.gz" fd                fd
  fetch_github_bare   "${t}" jqlang/jq           "${JQ_TAG}"      "jq-macos-arm64"                                 jq
  fetch_github_binary "${t}" koalaman/shellcheck "${SHELLCHECK_TAG}" ".darwin.aarch64.tar.xz"    shellcheck        shellcheck
  fetch_github_binary "${t}" mikefarah/yq        "${YQ_TAG}"      "yq_darwin_arm64.tar.gz"       yq_darwin_arm64   yq
  fetch_github_binary "${t}" dandavison/delta    "${DELTA_TAG}"   "-aarch64-apple-darwin.tar.gz" delta             delta
  fetch_github_binary "${t}" duckdb/duckdb       "${DUCKDB_TAG}"  "duckdb_cli-osx-universal.zip" duckdb            duckdb
  fetch_github_binary "${t}" sibprogrammer/xq    "${XQ_TAG}"      "_darwin_arm64.tar.gz"         xq                xq
  write_common_unix_files "${t}"
  write_bundle_agents_md "${t}"

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

The automatic installer also installs whisper.cpp + meeting tools. The meeting
workflow expects PCM WAV input and does not require ffmpeg.


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
       <string>--no-context-shift</string>
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
mkdir -p "${DEST}/models" "${DEST}/llama.cpp" "${DEST}/opencode" "${DEST}/whisper.cpp" "${DEST}/meeting" "${DEST}/bin" "${LOGS}" "${AGENTS}" "${HOME}/.local/bin" "${HOME}/.config/opencode"
cp -R "${HERE}/llama.cpp/." "${DEST}/llama.cpp/"
cp -R "${HERE}/opencode/." "${DEST}/opencode/"
cp -R "${HERE}/whisper.cpp/." "${DEST}/whisper.cpp/"
cp -R "${HERE}/meeting/." "${DEST}/meeting/"
if [[ -d "${HERE}/bin" ]]; then cp -R "${HERE}/bin/." "${DEST}/bin/"; fi
[[ -f "${HERE}/AGENTS.md" ]] && cp "${HERE}/AGENTS.md" "${DEST}/AGENTS.md"
cp "${HERE}/_common.sh" "${DEST}/_common.sh"
cp -n "${ROOT}/models/"*.gguf "${DEST}/models/"
cp -n "${ROOT}/models/ggml-large-v3-turbo.bin" "${DEST}/models/"
ln -sf "${DEST}/opencode/opencode" "${HOME}/.local/bin/opencode"
for binname in rg fd jq yq xq shellcheck delta duckdb; do
  [[ -x "${DEST}/bin/${binname}" ]] && ln -sf "${DEST}/bin/${binname}" "${HOME}/.local/bin/${binname}"
done
chmod +x "${DEST}/meeting/"*.sh
ln -sf "${DEST}/meeting/record-meeting.sh" "${HOME}/.local/bin/record-meeting"
ln -sf "${DEST}/meeting/meeting-transcribe.sh" "${HOME}/.local/bin/meeting-transcribe"
ln -sf "${DEST}/meeting/meeting-notes.sh" "${HOME}/.local/bin/meeting-notes"
ln -sf "${DEST}/meeting/meeting-process.sh" "${HOME}/.local/bin/meeting-process"
bash "${HERE}/opencode_privacy.sh"

command -v cmake >/dev/null 2>&1 || { echo "cmake is required to build whisper.cpp; install it with: brew install cmake ninja" >&2; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "ninja is required to build whisper.cpp; install it with: brew install cmake ninja" >&2; exit 1; }
cmake -S "${DEST}/whisper.cpp" \
  -B "${DEST}/whisper.cpp/build" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_SERVER=1 \
  -DGGML_METAL=1
cmake --build "${DEST}/whisper.cpp/build" -j"$(sysctl -n hw.physicalcpu)"

# Chat launcher: Qwen3.6-35B-A3B UD-IQ4_XS-MTP on Metal, c=131072, MTP
# draft-mtp enabled (delete --spec-type / --spec-draft-n-max if MTP
# misbehaves on this host; the same GGUF runs without MTP).
cat >"${DEST}/run-llamacpp.sh" <<RUN
#!/usr/bin/env bash
export PATH="${DEST}/opencode:${HOME}/.local/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:\${PATH}"
export DYLD_LIBRARY_PATH="${DEST}/llama.cpp\${DYLD_LIBRARY_PATH:+:\${DYLD_LIBRARY_PATH}}"
exec "${DEST}/llama.cpp/llama-server" -m "${DEST}/models/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf" --mmproj "${DEST}/models/mmproj-BF16.gguf" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on -np 1 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --reasoning on --spec-type draft-mtp --spec-draft-n-max 2 --no-context-shift --host 127.0.0.1 --port 8080
RUN
cat >"${DEST}/stop-llamacpp.sh" <<RUN
#!/usr/bin/env bash
set -euo pipefail
launchctl bootout "gui/\$(id -u)/com.slopcode.llamacpp" 2>/dev/null || true
pkill -f "${DEST}/llama.cpp/llama-server" 2>/dev/null || true
echo "stopped"
RUN
chmod +x "${DEST}/run-llamacpp.sh" "${DEST}/stop-llamacpp.sh"

cat >"${DEST}/run-whisper.sh" <<RUN
#!/usr/bin/env bash
export DYLD_LIBRARY_PATH="${DEST}/whisper.cpp/build/bin\${DYLD_LIBRARY_PATH:+:\${DYLD_LIBRARY_PATH}}"
exec "${DEST}/whisper.cpp/build/bin/whisper-server" \
  -m "${DEST}/models/ggml-large-v3-turbo.bin" \
  --host 127.0.0.1 --port 8427 -l auto -t 4 -fa \
  --inference-path /v1/audio/transcriptions \
  --tmp-dir /tmp
RUN
chmod +x "${DEST}/run-whisper.sh"

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
WHISPER_PLIST="${AGENTS}/com.slopcode.whisper-server.plist"
cat >"${WHISPER_PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.slopcode.whisper-server</string>
<key>ProgramArguments</key><array>
<string>${DEST}/run-whisper.sh</string>
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
cat >"${HOME}/.config/opencode/opencode.json" <<JSON
{"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B MTP","limit":{"context":131072,"output":16384},"reasoning":true,"interleaved":{"field":"reasoning_content"},"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}
JSON
echo "installed: opencode + llama.cpp on 127.0.0.1:8080 + whisper.cpp on 127.0.0.1:8427"
EOF
  chmod +x "${t}/install.sh"
}

write_windows() {
  local t="${OUT}/windows-arc"
  mkdir -p "${t}/llama.cpp" "${t}/opencode" "${t}/whisper.cpp"
  local tag url oc_tag oc_url wh_tag wh_url
  # SYCL prebuilt instead of Vulkan: ~2x prefill on Lunar Lake / Arc 140V,
  # sidesteps Vulkan-Arc bugs (#18808 agentic-use, #22275 silent exits,
  # #20554 coopmat TDR). Upstream Windows SYCL zip now ships oneAPI runtime
  # DLLs so colleagues need no separate Intel install.
  read -r tag url <<<"$(llama_asset win-sycl-x64)"
  echo "windows-arc llama.cpp ${tag} (SYCL)"
  fetch_archive "${url}" "${t}/llama.cpp" llama-server.exe
  read -r oc_tag oc_url <<<"$(github_asset sst/opencode "${OPENCODE_TAG}" opencode-windows-x64.zip)"
  echo "windows-arc opencode ${oc_tag}"
  fetch_archive "${oc_url}" "${t}/opencode" opencode.exe
  read -r wh_tag wh_url <<<"$(github_asset ggml-org/whisper.cpp "${WHISPER_TAG}" whisper-bin-x64.zip)"
  echo "windows whisper.cpp ${wh_tag}"
  fetch_archive "${wh_url}" "${t}/whisper.cpp" whisper-server.exe
  fetch_github_binary "${t}" BurntSushi/ripgrep "${RIPGREP_TAG}" "-x86_64-pc-windows-msvc.zip" rg.exe         rg.exe
  fetch_github_binary "${t}" sharkdp/fd          "${FD_TAG}"      "-x86_64-pc-windows-msvc.zip" fd.exe         fd.exe
  fetch_github_bare   "${t}" jqlang/jq           "${JQ_TAG}"      "jq-windows-amd64.exe"                       jq.exe
  fetch_github_binary "${t}" koalaman/shellcheck "${SHELLCHECK_TAG}" ".zip"                       shellcheck.exe shellcheck.exe
  fetch_github_binary "${t}" mikefarah/yq        "${YQ_TAG}"      "yq_windows_amd64.zip"        yq_windows_amd64.exe yq.exe
  fetch_github_binary "${t}" dandavison/delta    "${DELTA_TAG}"   "-x86_64-pc-windows-msvc.zip" delta.exe      delta.exe
  fetch_github_binary "${t}" duckdb/duckdb       "${DUCKDB_TAG}"  "duckdb_cli-windows-amd64.zip" duckdb.exe    duckdb.exe
  fetch_github_binary "${t}" sibprogrammer/xq    "${XQ_TAG}"      "_windows_amd64.zip"          xq.exe         xq.exe
  fetch_direct_binary "${t}" "${SQLITE_TOOLS_WIN_URL}" "sqlite-tools-win-x64" sqlite3.exe sqlite3.exe
  write_bundle_agents_md "${t}"
  sync_dir "${SCRIPT_DIR}/../meeting" "${t}/meeting"

  # verify-models.bat: certutil-based SHA256 verification, no powershell.
  cat >"${t}/verify-models.bat" <<'BAT'
@echo off
setlocal EnableDelayedExpansion
set "MODELS_DIR=%~1"
if "%MODELS_DIR%"=="" set "MODELS_DIR=%~dp0..\models"
set "OK=1"
for %%S in ("%MODELS_DIR%\*.sha256") do (
  set "SHA_FILE=%%~fS"
  set "GGUF=%%~dpnS"
  if not exist "!GGUF!" (
    echo missing model file: !GGUF! 1>&2
    set "OK=0"
  ) else (
    set "EXPECTED="
    for /f "usebackq tokens=1 delims= " %%H in ("!SHA_FILE!") do if not defined EXPECTED set "EXPECTED=%%H"
    set "ACTUAL="
    for /f "tokens=*" %%H in ('certutil -hashfile "!GGUF!" SHA256 ^| findstr /R "^[0-9a-f][0-9a-f][0-9a-f]"') do (
      if not defined ACTUAL set "ACTUAL=%%H"
    )
    set "ACTUAL=!ACTUAL: =!"
    if /I "!EXPECTED!"=="!ACTUAL!" (
      echo OK  %%~nxS
    ) else (
      echo SHA256 mismatch: %%~nxS 1>&2
      echo   expected: !EXPECTED! 1>&2
      echo   actual:   !ACTUAL! 1>&2
      set "OK=0"
    )
  )
)
if "%OK%"=="0" exit /b 1
exit /b 0
BAT

  cat >"${t}/README.md" <<'EOF'
slopcode for Windows (Intel Arc, SYCL / oneAPI)
===============================================

This bundle uses the Intel oneAPI / SYCL backend of llama.cpp instead of
the older Vulkan backend. SYCL prefill is ~2x faster on Lunar Lake / Arc
140V and the historic Vulkan-coopmat TDR bugs do not apply here. The
upstream Windows SYCL prebuilt ships its oneAPI runtime DLLs next to
llama-server.exe, so you do not need to install Intel oneAPI separately.

WHAT THIS IS
------------
A local AI coding assistant. Everything runs on your computer: no
cloud, no account, no data leaves the machine. One background
service binds to localhost only:

  http://127.0.0.1:8080/v1   (llama.cpp, the LLM)

"Endpoint" just means a URL the opencode coding tool talks to.

The automatic installer also installs whisper.cpp + meeting tools. The meeting
workflow expects PCM WAV input and does not require ffmpeg.


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
       > copy prewarm-opencode.bat   "%USERPROFILE%\slopcode\bin\"

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
       set "PATH=%USERPROFILE%\slopcode\llama.cpp;%PATH%"
       "%USERPROFILE%\slopcode\llama.cpp\llama-server.exe" -m "%USERPROFILE%\slopcode\models\Qwen3.6-35B-A3B-UD-IQ4_XS.gguf" --mmproj "%USERPROFILE%\slopcode\models\mmproj-BF16.gguf" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on -np 1 --threads 6 --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --reasoning on --spec-type draft-mtp --spec-draft-n-max 2 --no-context-shift --host 127.0.0.1 --port 8080

   On Arc 140V (Lunar Lake, 4P + 4LP = 8 physical cores) --threads 6 is
   the right value (physical - 2). On other Arc hosts substitute
   physical-cores - 2 (min 2).

   No --cpu-moe / --n-cpu-moe: all 40 MoE expert layers stay on the Arc
   iGPU together with attention + KV + DeltaNet. The IQ4_XS-MTP weights
   plus the MTP head fit the 32 GB Shared GPU Memory Override budget with
   ~10 GB of headroom. If you hit out-of-memory on a smaller host, add
   "--n-cpu-moe 20" (or higher up to 40 = --cpu-moe) to push expert
   layers back to CPU.

7. Create the CPU fallback launcher
   %USERPROFILE%\slopcode\run-llamacpp-cpu.bat with this exact
   content. Same Notepad steps as above:

       @echo off
       set "PATH=%USERPROFILE%\slopcode\llama.cpp;%PATH%"
       "%USERPROFILE%\slopcode\llama.cpp\llama-server.exe" -m "%USERPROFILE%\slopcode\models\Qwen3.6-35B-A3B-UD-IQ4_XS.gguf" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -ngl 0 -np 1 --threads 6 --threads-http 2 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --reasoning on --spec-type draft-mtp --spec-draft-n-max 2 --no-context-shift --host 127.0.0.1 --port 8080

8. Create the whisper launcher %USERPROFILE%\slopcode\run-whisper.bat
   with this exact content:

       @echo off
       set "PATH=%USERPROFILE%\slopcode\whisper.cpp;%PATH%"
       "%USERPROFILE%\slopcode\whisper.cpp\whisper-server.exe" -m "%USERPROFILE%\slopcode\models\ggml-large-v3-turbo.bin" --host 127.0.0.1 --port 8427 -l auto -t 4 -fa --inference-path /v1/audio/transcriptions --tmp-dir "%TEMP%"

9. Create the opencode config. In Command Prompt:

       > mkdir "%USERPROFILE%\.config\opencode"

   Then open Notepad and paste this exact content (one long line):

       {"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B MTP (Arc SYCL)","limit":{"context":131072,"output":16384},"reasoning":true,"interleaved":{"field":"reasoning_content"},"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}

   Save as opencode.json in %USERPROFILE%\.config\opencode\
   (set "Save as type" to "All Files").

10. Auto-start at login. In File Explorer go to
    %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\
    (paste that into the address bar). Create a new .bat file named
    slopcode-llamacpp.bat containing exactly:

        start "slopcode" /MIN "%USERPROFILE%\slopcode\run-llamacpp.bat"

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

run-llamacpp.bat       Active SYCL GPU launcher. Copied from
                       run-llamacpp-iq4xs.bat or run-llamacpp-xl.bat
                       depending on which installer you ran. All 40
                       MoE expert layers stay on the Arc iGPU; no
                       --cpu-moe / --n-cpu-moe. Tuned for Lunar Lake
                       Arc 140V with the Shared GPU Memory Override at
                       32 GB. -c 131072, -ub 1024, q8_0 KV, MTP
                       speculative decoding via --spec-type draft-mtp.
run-llamacpp-iq4xs.bat IQ4_XS-MTP variant (~18 GB). Default.
run-llamacpp-xl.bat    UD-Q4_K_XL-MTP variant (~23 GB). Opt-in via
                       install-xl.bat or switch-quant.bat xl.
switch-quant.bat       Flip the active quant: `switch-quant.bat iq4_xs`
                       or `switch-quant.bat xl`. Restarts the service.
run-llamacpp-cpu.bat   Pure CPU fallback (-ngl 0). Always correct
                       output but only ~10 tokens per second.

WHEN TO SWITCH TO CPU FALLBACK
If the SYCL path produces garbage (repeated slashes "/////" in
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


SECONDARY FALLBACK - garbage output that isn't TDR
The SYCL backend sidesteps the Vulkan-coopmat (#20554) and F16-acc
(#18969) bugs that needed env-var workarounds. If you still see
garbage:

1. Try the IQ4_XS variant if you were on XL (switch-quant.bat iq4_xs).
   The smaller weights leave more room for the MTP head and KV cache.

2. Try bumping the KV cache to bf16 (slower, doubles memory, but a
   common remedy for Intel iGPU numerical issues). Edit
   run-llamacpp.bat and change "--cache-type-k q8_0 --cache-type-v q8_0"
   to "--cache-type-k bf16 --cache-type-v bf16". You may also need to
   drop -c from 131072 to 65536 to keep VRAM in budget.

3. Try disabling MTP. Remove "--spec-type draft-mtp --spec-draft-n-max 2"
   from run-llamacpp.bat. The MTP code path is newer than the rest of
   llama.cpp; if a future driver regression is MTP-specific, plain
   speculation-free decode keeps working.

4. Try disabling flash attention. Change "-fa on" to "-fa off". This
   trades performance for more conservative attention compute paths.

5. Use the CPU fallback (run-llamacpp-cpu.bat). If that also produces
   garbage, the model file is corrupt - re-copy from the USB.
EOF

  cat >"${t}/install.bat" <<'EOF'
@echo off
setlocal EnableDelayedExpansion
set "HERE=%~dp0"
for %%I in ("%HERE%\..") do set "ROOT=%%~fI"
set "DEST=%USERPROFILE%\slopcode"
echo Verifying model checksums...
call "%HERE%\verify-models.bat" "%ROOT%\models"
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
taskkill /F /IM whisper-server.exe /T >nul 2>&1
taskkill /F /IM opencode.exe /T >nul 2>&1
REM Brief pause so Windows releases file handles before we rmdir.
ping -n 3 127.0.0.1 >nul 2>&1
echo Removing old Startup shortcuts...
del /Q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\slopcode-llamacpp.bat" 2>nul
del /Q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\slopcode-whisper.bat" 2>nul
echo Removing old launchers and opencode config...
del /Q "%DEST%\run-llamacpp.bat" 2>nul
del /Q "%DEST%\run-llamacpp-iq4xs.bat" 2>nul
del /Q "%DEST%\run-llamacpp-xl.bat" 2>nul
del /Q "%DEST%\run-llamacpp-coder.bat" 2>nul
del /Q "%DEST%\run-llamacpp-cpu.bat" 2>nul
del /Q "%DEST%\switch-quant.bat" 2>nul
del /Q "%DEST%\start-slopcode.bat" 2>nul
del /Q "%DEST%\run-whisper.bat" 2>nul
del /Q "%DEST%\stop-llamacpp.bat" 2>nul
del /Q "%DEST%\llama-chat.bat" 2>nul
del /Q "%DEST%\llama-coder.bat" 2>nul
del /Q "%DEST%\bin\prewarm-opencode.bat" 2>nul
del /Q "%DEST%\bin\record-meeting.bat" 2>nul
del /Q "%DEST%\bin\meeting-transcribe.bat" 2>nul
del /Q "%DEST%\bin\meeting-notes.bat" 2>nul
del /Q "%DEST%\bin\meeting-process.bat" 2>nul
del /Q "%USERPROFILE%\.config\opencode\opencode.json" 2>nul
echo Removing old llama.cpp + opencode dirs...
rmdir /S /Q "%DEST%\llama.cpp" 2>nul
rmdir /S /Q "%DEST%\opencode" 2>nul
rmdir /S /Q "%DEST%\whisper.cpp" 2>nul
rmdir /S /Q "%DEST%\meeting" 2>nul
echo Removing old GGUFs from %DEST%\models...
del /Q "%DEST%\models\*.gguf" 2>nul
del /Q "%DEST%\models\*.sha256" 2>nul
del /Q "%DEST%\models\ggml-large-v3-turbo.bin" 2>nul
echo Clearing Intel shader cache...
rmdir /S /Q "%LOCALAPPDATA%\Intel\ShaderCache" 2>nul
echo === Cleanup done; installing fresh ===
echo.
mkdir "%DEST%\models" "%DEST%\llama.cpp" "%DEST%\opencode" "%DEST%\whisper.cpp" "%DEST%\meeting" "%DEST%\bin" "%DEST%\cache" 2>nul
xcopy /E /I /Y "%HERE%\llama.cpp" "%DEST%\llama.cpp" >nul
xcopy /E /I /Y "%HERE%\opencode" "%DEST%\opencode" >nul
xcopy /E /I /Y "%HERE%\whisper.cpp" "%DEST%\whisper.cpp" >nul
xcopy /E /I /Y "%HERE%\meeting" "%DEST%\meeting" >nul
if exist "%HERE%\bin" xcopy /E /I /Y "%HERE%\bin" "%DEST%\bin" >nul
if exist "%HERE%\AGENTS.md" copy /Y "%HERE%\AGENTS.md" "%DEST%\AGENTS.md" >nul
copy /Y "%ROOT%\models\*.gguf" "%DEST%\models\" >nul
copy /Y "%ROOT%\models\ggml-large-v3-turbo.bin" "%DEST%\models\" >nul
setx OPENCODE_DISABLE_AUTOUPDATE 1 >nul
setx OPENCODE_DISABLE_SHARE 1 >nul
setx OPENCODE_DISABLE_MODELS_FETCH 1 >nul
setx OPENCODE_DISABLE_LSP_DOWNLOAD 1 >nul
setx OPENCODE_DISABLE_DEFAULT_PLUGINS 1 >nul
setx OPENCODE_DISABLE_EMBEDDED_WEB_UI 1 >nul
REM Single chat GGUF: Qwen3.6-35B-A3B UD-IQ4_XS-MTP. Fits the Arc 140V
REM 32 GB GPU cap with the MTP head loaded plus ~10 GB headroom.
set "MODEL=%DEST%\models\Qwen3.6-35B-A3B-UD-IQ4_XS.gguf"
set "MMPROJ=%DEST%\models\mmproj-BF16.gguf"
REM Detect physical cores via wmic; --threads = physical - 2 (min 2). On Lunar
REM Lake Arc 140V (4P + 4LP = 8 physical) this lands on --threads 6. If wmic
REM is not installed (Windows 11 24H2+ without the optional feature) we fall
REM back to logical cores / 2 - 1, which approximates physical on hyperthreaded
REM hosts.
set "PHYS="
for /f "skip=1 tokens=*" %%C in ('wmic cpu get NumberOfCores 2^>nul') do (
  if not defined PHYS for /f "tokens=1" %%N in ("%%C") do set "PHYS=%%N"
)
if defined PHYS (set /a THREADS=%PHYS% - 2) else (set /a THREADS=%NUMBER_OF_PROCESSORS%/2 - 1)
if !THREADS! LSS 2 set THREADS=2
REM Per-quant launchers; switch-quant.bat below copies the active one to
REM run-llamacpp.bat. Both load the MTP-trained GGUF and emit
REM --spec-type draft-mtp for the 1.4-2.2x decode speedup; sampler block
REM (temp 0.6, presence-penalty 0.0) is Qwen's "thinking + precise
REM coding" preset — the right default for agent loops.
REM Backend: SYCL (Intel oneAPI) prebuilt. No GGML_VK_* env vars needed —
REM those workarounds were Vulkan-specific. The bundled llama-server.exe
REM ships oneAPI runtime DLLs so no separate Intel install is required.
>"%DEST%\run-llamacpp.bat" echo @echo off
>>"%DEST%\run-llamacpp.bat" echo set "PATH=%DEST%\llama.cpp;%%PATH%%"
>>"%DEST%\run-llamacpp.bat" echo "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" --mmproj "%MMPROJ%" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on -np 1 --threads !THREADS! --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --reasoning on --spec-type draft-mtp --spec-draft-n-max 2 --no-context-shift --host 127.0.0.1 --port 8080
REM CPU fallback (-ngl 0); always correct but ~10 tok/s.
>"%DEST%\run-llamacpp-cpu.bat" echo @echo off
>>"%DEST%\run-llamacpp-cpu.bat" echo set "PATH=%DEST%\llama.cpp;%%PATH%%"
>>"%DEST%\run-llamacpp-cpu.bat" echo "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -ngl 0 -np 1 --threads !THREADS! --threads-http 2 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --reasoning on --spec-type draft-mtp --spec-draft-n-max 2 --no-context-shift --host 127.0.0.1 --port 8080
>"%DEST%\stop-llamacpp.bat" echo @echo off
>>"%DEST%\stop-llamacpp.bat" echo taskkill /F /IM llama-server.exe /T ^>nul 2^>^&1
>>"%DEST%\stop-llamacpp.bat" echo echo stopped
>"%DEST%\run-whisper.bat" echo @echo off
>>"%DEST%\run-whisper.bat" echo set "PATH=%DEST%\whisper.cpp;%%PATH%%"
>>"%DEST%\run-whisper.bat" echo "%DEST%\whisper.cpp\whisper-server.exe" -m "%DEST%\models\ggml-large-v3-turbo.bin" --host 127.0.0.1 --port 8427 -l auto -t 4 -fa --inference-path /v1/audio/transcriptions --tmp-dir "%%TEMP%%"
mkdir "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup" 2>nul
>"%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\slopcode-llamacpp.bat" echo start "slopcode" /MIN "%DEST%\run-llamacpp.bat"
>"%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\slopcode-whisper.bat" echo start "slopcode-whisper" /MIN "%DEST%\run-whisper.bat"
>"%DEST%\bin\record-meeting.bat" echo @echo off
>>"%DEST%\bin\record-meeting.bat" echo start "" "%DEST%\meeting\record-meeting.html"
>"%DEST%\bin\meeting-transcribe.bat" echo @echo off
>>"%DEST%\bin\meeting-transcribe.bat" echo where pwsh ^>nul 2^>^&1 ^|^| ^(echo PowerShell 7 pwsh is required for meeting scripts. Install it from https://aka.ms/powershell ^& exit /b 1^)
>>"%DEST%\bin\meeting-transcribe.bat" echo pwsh -NoProfile -ExecutionPolicy Bypass -File "%DEST%\meeting\meeting-transcribe.ps1" %%*
>"%DEST%\bin\meeting-notes.bat" echo @echo off
>>"%DEST%\bin\meeting-notes.bat" echo where pwsh ^>nul 2^>^&1 ^|^| ^(echo PowerShell 7 pwsh is required for meeting scripts. Install it from https://aka.ms/powershell ^& exit /b 1^)
>>"%DEST%\bin\meeting-notes.bat" echo pwsh -NoProfile -ExecutionPolicy Bypass -File "%DEST%\meeting\meeting-notes.ps1" %%*
>"%DEST%\bin\meeting-process.bat" echo @echo off
>>"%DEST%\bin\meeting-process.bat" echo where pwsh ^>nul 2^>^&1 ^|^| ^(echo PowerShell 7 pwsh is required for meeting scripts. Install it from https://aka.ms/powershell ^& exit /b 1^)
>>"%DEST%\bin\meeting-process.bat" echo pwsh -NoProfile -ExecutionPolicy Bypass -File "%DEST%\meeting\meeting-process.ps1" %%*
mkdir "%USERPROFILE%\.config\opencode" 2>nul
>"%USERPROFILE%\.config\opencode\opencode.json" echo {"model":"llamacpp/qwen","small_model":"llamacpp/qwen","share":"disabled","autoupdate":false,"tools":{"websearch":false},"experimental":{"openTelemetry":false},"disabled_providers":["exa","opencode","llmgateway","github-copilot","copilot","openai","anthropic","google","mistral","groq","xai","ollama"],"provider":{"llamacpp":{"npm":"@ai-sdk/openai-compatible","name":"llama.cpp (Local)","options":{"baseURL":"http://127.0.0.1:8080/v1"},"models":{"qwen":{"name":"Qwen3.6 35B A3B MTP (Arc SYCL)","limit":{"context":131072,"output":16384},"reasoning":true,"interleaved":{"field":"reasoning_content"},"attachment":true,"tool_call":true,"modalities":{"input":["text","image"],"output":["text"]}}}}}}
REM Update user PATH (HKCU\Environment) without touching system entries.
set "USERPATH="
for /f "tokens=2*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul ^| findstr /I "Path"') do set "USERPATH=%%B"
set "NEWPATH=%DEST%\opencode;%DEST%\bin"
if defined USERPATH (
  echo !USERPATH! | findstr /I /C:"%DEST%\opencode" >nul || set "NEWPATH=!NEWPATH!;!USERPATH!"
  if "!NEWPATH:%DEST%\opencode=!"=="!NEWPATH!" set "NEWPATH=!USERPATH!"
)
setx Path "!NEWPATH!" >nul
start "slopcode" /MIN "%DEST%\run-llamacpp.bat"
start "slopcode-whisper" /MIN "%DEST%\run-whisper.bat"
echo Installed localhost-only llama.cpp 8080, whisper.cpp 8427, opencode, and meeting scripts (--threads !THREADS!).
echo If you see repeated slashes in opencode thinking, run: %DEST%\run-llamacpp-cpu.bat
echo and update the Startup shortcut to point at run-llamacpp-cpu.bat instead.
echo Open a new terminal before running opencode.
EOF
}

copy_models
for target in "${TARGETS[@]}"; do
  case "${target}" in
    linux-cuda)
      write_linux
      write_simple_platform_readme "${OUT}/linux-cuda" "slopcode for Linux (NVIDIA CUDA)" "bash install.sh" "./prewarm-opencode.sh"
      prune_dir_entries "${OUT}/linux-cuda" llama.cpp opencode whisper.cpp bin _common.sh opencode_privacy.sh prewarm-opencode.sh meeting start.sh README.md AGENTS.md install.sh
      ;;
    mac-m1)
      write_mac
      write_simple_platform_readme "${OUT}/mac-m1" "slopcode for macOS (Apple Silicon)" "bash install.sh" "./prewarm-opencode.sh"
      prune_dir_entries "${OUT}/mac-m1" llama.cpp opencode whisper.cpp bin _common.sh opencode_privacy.sh prewarm-opencode.sh meeting README.md AGENTS.md install.sh
      ;;
    windows-arc)
      write_windows
      write_simple_platform_readme "${OUT}/windows-arc" "slopcode for Windows (Intel Arc, Vulkan)" ".\\install.bat" ".\\prewarm-opencode.bat"
      prune_dir_entries "${OUT}/windows-arc" llama.cpp opencode whisper.cpp bin meeting verify-models.bat README.md AGENTS.md install.bat
      ;;
  esac
done

copy_local_luna
download_llama_vscode
write_vscode_helpers

cat >"${OUT}/README.md" <<'EOF'
# slopcode USB bundle

A local AI coding bundle: llama.cpp + OpenCode + whisper.cpp meeting
transcription, all bound to localhost. One model, one server, no cloud.

## Automatic localhost path

Open your platform folder and run its installer:

- `linux-cuda/`
- `mac-m1/`
- `windows-arc/`

Each installer binds llama.cpp to `127.0.0.1:8080`, binds whisper.cpp to
`127.0.0.1:8427`, configures OpenCode for the local LLM endpoint, and installs
the meeting scripts on PATH. `meeting-process <audio.wav>` transcribes PCM WAV
through whisper.cpp and then calls `opencode run` once to write meeting notes.

## Manual path

Open `local-luna/README.md` for a step-by-step manual setup that does the
same thing as the automatic installer.

## VS Code llama.vscode

Open `vscode/README.md` to install the bundled extension. It points
at the same `127.0.0.1:8080` server the OpenCode install uses.
EOF

echo "bundle ready at ${OUT}"
