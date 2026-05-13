#!/usr/bin/env bash
# Install peteonrails/voxtype (push-to-talk dictation daemon) on Linux,
# pointed at the local whisper.cpp server (slopcode-infra), as a
# systemd --user unit. No sudo, no admin.
#
# Auto-detects CPU class (AVX-512 vs AVX-2) and GPU class (CUDA, ROCm,
# Vulkan, none) and picks the matching upstream release binary. The
# Whisper backend is the default; pass VOXTYPE_BACKEND=onnx to install
# the Parakeet/ONNX variant instead. CUDA users get the onnx-cuda build
# even with VOXTYPE_BACKEND=whisper if they pass GPU=cuda explicitly,
# since the Whisper Vulkan binary works on NVIDIA but the dedicated
# CUDA binary lives on the ONNX side.
#
# Env overrides:
#   VOXTYPE_VERSION   release tag without leading v (default: latest from
#                     gh release view; falls back to GitHub API if gh is
#                     not on PATH).
#   VOXTYPE_BACKEND   whisper (default) or onnx.
#   VOXTYPE_VARIANT   force a specific binary suffix (avx2, avx512,
#                     vulkan, onnx-avx2, onnx-avx512, onnx-cuda,
#                     onnx-rocm). Skips auto-detection.
#   VOXTYPE_BIN_DIR   install dir for the binary (default ~/.local/bin)
#   VOXTYPE_CONFIG    config file to write (default
#                     ~/.config/voxtype/config.toml). The script never
#                     overwrites a pre-existing config; pass
#                     VOXTYPE_FORCE_CONFIG=true to opt in.
#   WHISPER_HOST      whisper-server bind host the daemon talks to
#                     (default 127.0.0.1).
#   WHISPER_PORT      whisper-server port (default 8427).
#   INSTALL_DRY_RUN   true to download + write everything but skip
#                     systemctl enable/start.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
case "${PLATFORM}" in
  linux|wsl) ;;
  *) die "install_voxtype_linux.sh is Linux-only (got ${PLATFORM}); see install_voxtype_mac.sh / install_voxtype_windows.bat" ;;
esac

REPO="${VOXTYPE_REPO:-peteonrails/voxtype}"
BACKEND="${VOXTYPE_BACKEND:-whisper}"
BIN_DIR="${VOXTYPE_BIN_DIR:-${HOME}/.local/bin}"
CONFIG_FILE="${VOXTYPE_CONFIG:-${HOME}/.config/voxtype/config.toml}"
FORCE_CONFIG="${VOXTYPE_FORCE_CONFIG:-false}"
WHISPER_HOST_DAEMON="${WHISPER_HOST:-127.0.0.1}"
WHISPER_PORT_DAEMON="${WHISPER_PORT:-8427}"
DRY_RUN="${INSTALL_DRY_RUN:-false}"
SERVICE_NAME="voxtype"

have curl   || die "curl not installed"
have shasum || have sha256sum || die "sha256sum (or shasum) not installed"

# ---------------------------------------------------------------------------
# Resolve release tag

resolve_tag() {
  if [[ -n "${VOXTYPE_VERSION:-}" ]]; then
    echo "v${VOXTYPE_VERSION#v}"
    return
  fi
  if have gh; then
    gh release view --repo "${REPO}" --json tagName --jq '.tagName' 2>/dev/null && return
  fi
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
}

TAG="$(resolve_tag)"
[[ -n "${TAG}" ]] || die "could not resolve voxtype release tag"
VERSION="${TAG#v}"
echo "voxtype: ${TAG}"

# ---------------------------------------------------------------------------
# Detect CPU + GPU class

detect_voxtype_cpu() {
  if grep -qE '\bavx512f\b' /proc/cpuinfo 2>/dev/null; then
    echo "avx512"
  else
    echo "avx2"
  fi
}

detect_voxtype_gpu() {
  if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    echo "cuda"
    return
  fi
  if have rocminfo && rocminfo >/dev/null 2>&1; then
    echo "rocm"
    return
  fi
  if have vulkaninfo && vulkaninfo --summary >/dev/null 2>&1; then
    echo "vulkan"
    return
  fi
  echo "cpu"
}

resolve_variant() {
  if [[ -n "${VOXTYPE_VARIANT:-}" ]]; then
    echo "${VOXTYPE_VARIANT}"
    return
  fi
  local cpu gpu
  cpu="$(detect_voxtype_cpu)"
  gpu="$(detect_voxtype_gpu)"
  case "${BACKEND}:${gpu}" in
    onnx:cuda)   echo "onnx-cuda" ;;
    onnx:rocm)   echo "onnx-rocm" ;;
    onnx:vulkan) echo "onnx-${cpu}" ;;
    onnx:cpu)    echo "onnx-${cpu}" ;;
    whisper:cuda)
      # Upstream Whisper CUDA shipping is via Vulkan (works on NVIDIA);
      # the dedicated CUDA binary lives on the ONNX side. Vulkan is
      # the right choice here for fast Whisper on NVIDIA.
      echo "vulkan"
      ;;
    whisper:vulkan) echo "vulkan" ;;
    whisper:rocm)   echo "vulkan" ;;
    whisper:cpu)    echo "${cpu}" ;;
    *) die "unsupported BACKEND/GPU combo: ${BACKEND}/${gpu}" ;;
  esac
}

VARIANT="$(resolve_variant)"
ASSET="voxtype-${VERSION}-linux-x86_64-${VARIANT}"
URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
SUMS_URL="https://github.com/${REPO}/releases/download/${TAG}/SHA256SUMS"
echo "asset:   ${ASSET}"
echo "from:    ${URL}"

mkdir -p "${BIN_DIR}"

# ---------------------------------------------------------------------------
# Download + verify

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl -fL --connect-timeout 30 --retry 3 --retry-delay 5 \
  -o "${tmp}/${ASSET}" "${URL}"

if curl -fsSL --connect-timeout 30 -o "${tmp}/SHA256SUMS" "${SUMS_URL}" 2>/dev/null; then
  expected="$(grep -E "[[:space:]]${ASSET}\$" "${tmp}/SHA256SUMS" | awk '{print $1}')"
  if [[ -n "${expected}" ]]; then
    if have sha256sum; then
      actual="$(sha256sum "${tmp}/${ASSET}" | awk '{print $1}')"
    else
      actual="$(shasum -a 256 "${tmp}/${ASSET}" | awk '{print $1}')"
    fi
    [[ "${expected}" == "${actual}" ]] \
      || die "checksum mismatch: expected ${expected}, got ${actual}"
    echo "sha256:  ${actual}  (matches SHA256SUMS)"
  else
    warn "no sha256 entry for ${ASSET} in SHA256SUMS; proceeding without verification"
  fi
else
  warn "could not fetch SHA256SUMS; proceeding without verification"
fi

install -m 755 "${tmp}/${ASSET}" "${BIN_DIR}/voxtype"
echo "wrote:   ${BIN_DIR}/voxtype"

# Sanity-check: the binary should print its version and not crash on
# CPU instruction issues (the upstream installs an .init_array SIGILL
# handler so a mis-matched build dies with a friendly message rather
# than a silent core dump).
if ! "${BIN_DIR}/voxtype" --version >/dev/null 2>&1; then
  die "${BIN_DIR}/voxtype --version failed; the binary may be incompatible with this CPU. Re-run with VOXTYPE_VARIANT=avx2 to fall back."
fi

# ---------------------------------------------------------------------------
# Config file pointed at the local whisper-server

config_dir="$(dirname "${CONFIG_FILE}")"
mkdir -p "${config_dir}"

if [[ -f "${CONFIG_FILE}" && "${FORCE_CONFIG}" != "true" ]]; then
  echo "config:  ${CONFIG_FILE} (preserved; pass VOXTYPE_FORCE_CONFIG=true to overwrite)"
else
  cat > "${CONFIG_FILE}" <<TOML
# Generated by slopcode-infra/scripts/install_voxtype_linux.sh
# Override fields here freely; re-running the installer leaves this
# file alone unless VOXTYPE_FORCE_CONFIG=true.

[hotkey]
key = "F13"
modifiers = []
mode = "push_to_talk"

[audio]
device = "default"
sample_rate = 16000
max_duration_secs = 60

[audio.feedback]
enabled = false

[whisper]
mode = "remote"
model = "large-v3-turbo"
language = "auto"
translate = false
on_demand_loading = false
remote_endpoint = "http://${WHISPER_HOST_DAEMON}:${WHISPER_PORT_DAEMON}"
remote_model = "large-v3-turbo"
remote_timeout_secs = 60

[output]
mode = "type"
fallback_to_clipboard = true
driver_order = ["wtype", "ydotool", "clipboard"]
type_delay_ms = 0
pre_type_delay_ms = 0

[output.notification]
on_recording_start = false
on_recording_stop = false
on_transcription = false

state_file = "auto"
TOML
  echo "config:  ${CONFIG_FILE} (written)"
fi

# ---------------------------------------------------------------------------
# systemd --user unit

UNIT_DIR="${HOME}/.config/systemd/user"
UNIT_FILE="${UNIT_DIR}/${SERVICE_NAME}.service"
mkdir -p "${UNIT_DIR}"

cat > "${UNIT_FILE}" <<UNIT
[Unit]
Description=Voxtype push-to-talk STT daemon (whisper-server backend)
After=network.target whisper-server.service
Wants=whisper-server.service

[Service]
Type=simple
ExecStart=${BIN_DIR}/voxtype
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT

echo "wrote:   ${UNIT_FILE}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "INSTALL_DRY_RUN=true; skipping systemctl enable/start."
  exit 0
fi

have systemctl || die "systemctl not found (non-systemd distro?)"
systemctl --user daemon-reload
systemctl --user enable "${SERVICE_NAME}.service"
systemctl --user restart "${SERVICE_NAME}.service"

# Tell the user where to look for state.
echo
echo "voxtype: installed and started"
echo "- binary:  ${BIN_DIR}/voxtype"
echo "- config:  ${CONFIG_FILE}"
echo "- backend: http://${WHISPER_HOST_DAEMON}:${WHISPER_PORT_DAEMON}/v1/audio/transcriptions"
echo "- logs:    journalctl --user -u ${SERVICE_NAME}.service -f"
echo
echo "If the F13 hotkey isn't reachable on your keyboard, edit the [hotkey]"
echo "section of ${CONFIG_FILE} and 'systemctl --user restart ${SERVICE_NAME}'."
