#!/usr/bin/env bash
# Free this host's GPU(s) for a heavy ad-hoc job (e.g. a Qwen3-TTS slopcast /
# slopask render) by stopping the llama-server, then restore it afterwards.
#
# Background: the MTP Q4_K_XL GPU-only profile uses ~31 of 32 GB, so Qwen3-TTS
# (~4.4 GB at synth peak) cannot load alongside it. The normal home for TTS is
# faepmac1 (256 GB unified), so this script is the fallback for when you must
# render on this box instead: stop llama (frees the GPUs in seconds), render,
# then restore (llama reloads ~30-60 s and the slopgate-agent re-registers it).
#
# Usage:
#   scripts/tts_swap.sh free       # stop llama-server, report free VRAM
#   scripts/tts_swap.sh restore    # start llama-server, wait until ready
#   scripts/tts_swap.sh status     # show llama state + free VRAM
#
# Env:
#   TTS_SWAP_SERVICE   systemd --user unit (default slopcode-llamacpp.service)
#   TTS_SWAP_HEALTH    health URL to poll on restore (default from drop-in bind)
#   TTS_SWAP_DRY_RUN   true to print actions without touching systemd
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

SERVICE="${TTS_SWAP_SERVICE:-slopcode-llamacpp.service}"
DRY_RUN="${TTS_SWAP_DRY_RUN:-false}"
DROPIN="${SERVE_SWITCH_DROPIN:-${HOME}/.config/systemd/user/slopcode-llamacpp.service.d/wg-only.conf}"

health_url() {
  if [[ -n "${TTS_SWAP_HEALTH:-}" ]]; then echo "${TTS_SWAP_HEALTH}"; return; fi
  local host port
  host="$(sed -n 's/^[[:space:]]*Environment=LLAMACPP_HOST=//p' "${DROPIN}" 2>/dev/null | tail -1)"
  port="$(sed -n 's/^[[:space:]]*Environment=LLAMACPP_PORT=//p' "${DROPIN}" 2>/dev/null | tail -1)"
  echo "http://${host:-127.0.0.1}:${port:-8080}/health"
}

gpu_free() {
  have nvidia-smi || { echo "(no nvidia-smi)"; return; }
  nvidia-smi --query-gpu=index,memory.free --format=csv,noheader 2>/dev/null \
    | awk -F', ' '{printf "  GPU%s free: %s\n", $1, $2}'
}

run() { if [[ "${DRY_RUN}" == "true" ]]; then echo "DRY: $*"; else "$@"; fi; }

case "${1:-status}" in
  free)
    echo "stopping ${SERVICE} to free the GPU(s)..."
    run systemctl --user stop "${SERVICE}"
    [[ "${DRY_RUN}" == "true" ]] || sleep 3
    echo "free VRAM now:"; gpu_free
    echo "GPU is free. Run your Qwen3-TTS render, then: scripts/tts_swap.sh restore"
    ;;
  restore)
    echo "starting ${SERVICE}..."
    run systemctl --user reset-failed "${SERVICE}" 2>/dev/null || true
    run systemctl --user start "${SERVICE}"
    if [[ "${DRY_RUN}" == "true" ]]; then echo "DRY: would poll $(health_url)"; exit 0; fi
    url="$(health_url)"
    echo "waiting for ${url} ..."
    deadline=$(( $(date +%s) + 240 ))
    until curl -fsS --max-time 4 "${url}" >/dev/null 2>&1; do
      [[ $(date +%s) -ge ${deadline} ]] && die "timed out waiting for ${SERVICE}"
      [[ "$(systemctl --user is-active "${SERVICE}")" == "failed" ]] && die "${SERVICE} failed to start"
      sleep 3
    done
    echo "llama-server is back (the slopgate-agent re-registers automatically)."
    gpu_free
    ;;
  status)
    echo "service: $(systemctl --user is-active "${SERVICE}" 2>/dev/null || echo unknown)"
    echo "free VRAM:"; gpu_free
    ;;
  *)
    die "usage: tts_swap.sh {free|restore|status}"
    ;;
esac
