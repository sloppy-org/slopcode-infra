#!/usr/bin/env bash
# Set up the MLX runtime for the Apple-silicon exclusive-big-model host:
# a dedicated venv with mlx-lm (latest git) plus the hf CLI for prefetch.
#
# llama.cpp does not yet run MiniMax M3 / DeepSeek V4-Flash well on Metal, so a
# Mac dedicated to one of those serves it via mlx_lm.server. This is host-local
# tooling, never part of the USB bundle.
#
# Env overrides:
#   MLX_VENV        venv dir (default ~/.venvs/mlx-lm)
#   MLX_LM_SPEC     pip target for mlx-lm
#                   (default: mlx-lm @ git+https://github.com/ml-explore/mlx-lm.git)
#   MLX_DRY_RUN     true to print the plan and exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "setup_mlx.sh is macOS only (MLX needs Metal)"
have uv || die "uv not found. Install it first: https://docs.astral.sh/uv/"

MLX_VENV="${MLX_VENV:-${HOME}/.venvs/mlx-lm}"
MLX_LM_SPEC="${MLX_LM_SPEC:-mlx-lm @ git+https://github.com/ml-explore/mlx-lm.git}"
VENV_PY="${MLX_VENV}/bin/python"

echo "MLX setup plan:"
echo "- venv:    ${MLX_VENV}"
echo "- mlx-lm:  ${MLX_LM_SPEC}"

if [[ "${MLX_DRY_RUN:-false}" == "true" ]]; then
  echo "MLX_DRY_RUN=true; not installing."
  exit 0
fi

if [[ ! -x "${VENV_PY}" ]]; then
  uv venv "${MLX_VENV}"
fi

uv pip install --python "${VENV_PY}" "${MLX_LM_SPEC}" hf_transfer huggingface_hub

# hf CLI for prefetch (idempotent; ignore "already exists").
uv tool install --force --with hf_transfer huggingface_hub >/dev/null 2>&1 || true

VERSION="$("${VENV_PY}" -c 'import mlx_lm; print(mlx_lm.__version__)')"
echo "- mlx-lm installed: ${VERSION}"

# MiniMax M3 needs the minimax_m3 model class. mlx-lm ships it from a later
# release; until then the pipenetwork repo carries the module. ensure_model_class
# copies it out of the downloaded snapshot into the venv if mlx-lm lacks it.
ensure_model_class() {
  local mod="$1" snapshot="$2"
  local models_dir
  models_dir="$("${VENV_PY}" -c 'import os,mlx_lm;print(os.path.join(os.path.dirname(mlx_lm.__file__),"models"))')"
  if [[ -f "${models_dir}/${mod}.py" ]]; then
    echo "- model class ${mod}: present in mlx-lm"
    return 0
  fi
  if [[ -n "${snapshot}" && -f "${snapshot}/${mod}.py" ]]; then
    cp "${snapshot}/${mod}.py" "${models_dir}/${mod}.py"
    echo "- model class ${mod}: copied from snapshot into ${models_dir}"
    return 0
  fi
  warn "model class ${mod} not in mlx-lm and not found in the model snapshot."
  warn "download the model first (scripts/mlx_models.py prefetch), then re-run setup_mlx.sh."
}

MODELS_SCRIPT="${SCRIPT_DIR}/mlx_models.py"
DEFAULT_ALIAS="$(python3 "${MODELS_SCRIPT}" default-alias)"
SNAPSHOT="$(python3 "${MODELS_SCRIPT}" resolve --json "${DEFAULT_ALIAS}" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("snapshot_dir",""))' 2>/dev/null || true)"
ensure_model_class minimax_m3 "${SNAPSHOT}"

echo "MLX runtime ready."
echo "next: python3 ${MODELS_SCRIPT} prefetch    # download the default model"
echo "      scripts/server_start_mlx.sh          # smoke-test the server"
