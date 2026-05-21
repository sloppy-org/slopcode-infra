#!/usr/bin/env bash
# Fetch the Qwen3.6-35B-A3B UD-IQ4_XS GGUF into a target directory.
#
# Defaults per host class:
#   mailuefterl (Linux workstation): /mnt/storage/slopcode/models
#   faepmac1    (Mac Studio leader): /Volumes/AI
#   other Linux: ~/.cache/llama.cpp (unchanged)
#   other macOS: ~/Library/Caches/llama.cpp (unchanged)
#
# Run on each host that should serve the IQ4_XS quant. The leader (faepmac1)
# keeps UD-Q4_K_XL as its primary quant; pass IQ4_XS_TARGET=/Volumes/AI to also
# stage XS there if you want both available for ad-hoc testing.
#
# Env:
#   IQ4_XS_TARGET   override cache directory
#   IQ4_XS_FORCE    re-download even when the GGUF is already present
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_SCRIPT="${SCRIPT_DIR}/llamacpp_models.py"
# IQ4_XS hosts (Linux PC, Windows, tight-VRAM followers) intentionally stay
# off MTP because the MTP head wants ~1 GB extra resident memory the small
# VRAM budget cannot spare. Set IQ4_XS_MTP=true to download the MTP variant
# anyway (only do this on hosts with the headroom).
if [[ "${IQ4_XS_MTP:-false}" == "true" ]]; then
  ALIAS="qwen3.6-35b-a3b-mtp-iq4_xs"
else
  ALIAS="qwen3.6-35b-a3b-iq4_xs"
fi

detect_default_target() {
  case "$(uname -s)" in
    Linux)
      if [[ -d /mnt/storage ]]; then
        echo /mnt/storage/slopcode/models
        return
      fi
      echo "${HOME}/.cache/llama.cpp"
      ;;
    Darwin)
      if [[ -d /Volumes/AI ]]; then
        echo /Volumes/AI
        return
      fi
      echo "${HOME}/Library/Caches/llama.cpp"
      ;;
    *)
      echo "${HOME}/.cache/llama.cpp"
      ;;
  esac
}

TARGET="${IQ4_XS_TARGET:-$(detect_default_target)}"
mkdir -p "${TARGET}"

echo "target cache root: ${TARGET}"
echo "alias:             ${ALIAS}"

if [[ "${IQ4_XS_FORCE:-false}" != "true" ]]; then
  if path="$(LLAMACPP_CACHE_ROOT="${TARGET}" python3 "${MODELS_SCRIPT}" resolve "${ALIAS}" 2>/dev/null)" \
     && [[ -n "${path}" && -f "${path}" ]]; then
    echo "already present: ${path}"
    echo "set IQ4_XS_FORCE=true to re-download."
    exit 0
  fi
fi

LLAMACPP_CACHE_ROOT="${TARGET}" python3 "${MODELS_SCRIPT}" prefetch "${ALIAS}"

resolved="$(LLAMACPP_CACHE_ROOT="${TARGET}" python3 "${MODELS_SCRIPT}" resolve "${ALIAS}")"
echo "fetched: ${resolved}"
