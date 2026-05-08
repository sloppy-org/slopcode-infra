#!/usr/bin/env bash
# Install whisper.cpp from source and fetch the default model. Mirrors
# setup_llamacpp.sh's shape. Idempotent: safe to re-run; pulls the pinned tag
# and rebuilds only when needed.
#
# GPU backend per platform (the encoder is GPU-bound; we never fall back to
# CPU on a host that has accelerated hardware):
#   Mac  -> Metal     (DGGML_METAL=1)
#   Linux nvidia      -> CUDA  (DGGML_CUDA=1)
#   Linux/Windows GPU -> Vulkan (DGGML_VULKAN=1)
#   Linux CPU-only    -> BLAS  (only when nothing better is present)
# faepmac1 hits the Mac/Metal path.
#
# Env overrides:
#   WHISPER_HOME        install dir. Defaults to ~/code/whisper.cpp when
#                       ~/code exists (so sources live alongside the rest
#                       of the user's hackable code), else ~/.local/whisper.cpp.
#   WHISPER_REF         git ref to check out (default master). Tracks upstream
#                       main so we get the same flag set the README documents.
#                       Pin to a tag (e.g. WHISPER_REF=v1.8.4) for reproducibility.
#   WHISPER_MODEL       model basename (default ggml-large-v3-turbo.bin)
#   WHISPER_MODEL_URL   override download URL
#   WHISPER_CMAKE_EXTRA extra flags appended to cmake configure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
default_whisper_home() {
  if [[ -d "${HOME}/code" ]]; then
    echo "${HOME}/code/whisper.cpp"
  else
    echo "${HOME}/.local/whisper.cpp"
  fi
}
WHISPER_HOME="${WHISPER_HOME:-$(default_whisper_home)}"
WHISPER_REF="${WHISPER_REF:-master}"
WHISPER_MODEL="${WHISPER_MODEL:-ggml-large-v3-turbo.bin}"
WHISPER_MODEL_URL="${WHISPER_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${WHISPER_MODEL}}"

have cmake || die "cmake not installed. macOS: brew install cmake. Linux: pacman -S cmake or apt-get install cmake"
have ninja || die "ninja not installed. macOS: brew install ninja. Linux: pacman -S ninja or apt-get install ninja-build"
have curl  || die "curl not installed"
have git   || die "git not installed"

if [[ ! -d "${WHISPER_HOME}/.git" ]]; then
  echo "cloning whisper.cpp into ${WHISPER_HOME}"
  mkdir -p "$(dirname "${WHISPER_HOME}")"
  git clone https://github.com/ggml-org/whisper.cpp "${WHISPER_HOME}"
fi

cd "${WHISPER_HOME}"
git fetch --all --tags --prune --quiet
# Track the requested ref. Default master ⇒ always rebuild on top of the latest
# upstream, matching what the README/help documents at any given time.
echo "checking out whisper.cpp ${WHISPER_REF}"
git checkout "${WHISPER_REF}"
if git symbolic-ref -q HEAD >/dev/null; then
  git pull --ff-only --quiet
fi
PREV_HEAD="$(cat "${WHISPER_HOME}/build/.head" 2>/dev/null || true)"
NEW_HEAD="$(git rev-parse HEAD)"

# Backend selection mirrors detect_gpu(): Metal on Mac, CUDA when available on
# Linux (much faster encoder), Vulkan on Windows, plain CPU+BLAS otherwise.
CMAKE_ARGS=(-S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_SERVER=1)
case "${PLATFORM}" in
  mac)
    CMAKE_ARGS+=(-DGGML_METAL=1)
    ;;
  linux|wsl)
    if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
      CMAKE_ARGS+=(-DGGML_CUDA=1)
    elif have vulkaninfo && vulkaninfo --summary >/dev/null 2>&1; then
      CMAKE_ARGS+=(-DGGML_VULKAN=1)
    else
      die "no GPU backend available (nvidia-smi / vulkaninfo). Install drivers or set WHISPER_ALLOW_CPU=1 explicitly to override."
    fi
    ;;
  windows)
    CMAKE_ARGS+=(-DGGML_VULKAN=1)
    ;;
esac
[[ "${WHISPER_ALLOW_CPU:-0}" == "1" && "${PLATFORM}" =~ ^(linux|wsl)$ ]] && CMAKE_ARGS=("${CMAKE_ARGS[@]/-DGGML_CUDA=1}") # honour explicit CPU opt-in

if [[ ! -x build/bin/whisper-server ]] || [[ "${PREV_HEAD}" != "${NEW_HEAD}" ]] || [[ "${WHISPER_REBUILD:-false}" == "true" ]]; then
  echo "configuring whisper.cpp"
  # shellcheck disable=SC2086
  cmake "${CMAKE_ARGS[@]}" ${WHISPER_CMAKE_EXTRA:-}
  echo "building whisper.cpp @ ${NEW_HEAD:0:12} ($(detect_physical_cores) cores)"
  cmake --build build --config Release -j"$(detect_physical_cores)"
  mkdir -p build
  printf '%s\n' "${NEW_HEAD}" > build/.head
else
  echo "whisper-server already built at ${WHISPER_HOME}/build/bin/whisper-server (HEAD ${NEW_HEAD:0:12})"
fi

mkdir -p "${WHISPER_HOME}/models"
MODEL_PATH="${WHISPER_HOME}/models/${WHISPER_MODEL}"
if [[ ! -f "${MODEL_PATH}" ]]; then
  echo "downloading ${WHISPER_MODEL}"
  curl -L --fail -o "${MODEL_PATH}.partial" "${WHISPER_MODEL_URL}"
  mv "${MODEL_PATH}.partial" "${MODEL_PATH}"
fi
size_human="$(du -h "${MODEL_PATH}" | awk '{print $1}')"
echo "whisper-server ready"
echo "- binary: ${WHISPER_HOME}/build/bin/whisper-server"
echo "- model:  ${MODEL_PATH} (${size_human})"
echo "- next:   scripts/server_start_whisper.sh (foreground) or scripts/install_mac_launchagents.sh (launchd)"
