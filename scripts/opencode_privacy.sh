#!/usr/bin/env bash
# Pin user-level environment variables that disable opencode's outbound
# network calls beyond the configured LLM endpoint. Idempotent: each run
# rewrites the marker-delimited block in place and silently overwrites
# the environment.d drop-in.
#
# What gets disabled (all confirmed by string-searching opencode 1.14.x):
#   OPENCODE_DISABLE_AUTOUPDATE       no version check against github/brew/choco
#   OPENCODE_DISABLE_SHARE            no session upload to opencode.ai
#   OPENCODE_DISABLE_MODELS_FETCH     no https://models.dev/api.json fetch
#   OPENCODE_DISABLE_LSP_DOWNLOAD     no clangd/texlab/zls/etc. auto-download
#   OPENCODE_DISABLE_DEFAULT_PLUGINS  no github-copilot/llmgateway probes
#   OPENCODE_DISABLE_EMBEDDED_WEB_UI  no inlined web-ui code path
#
# On Linux / macOS this edits a marker block in ~/.profile and
# ~/.bashrc / ~/.zshrc / ~/.zprofile (if they exist), and writes
# ~/.config/environment.d/99-opencode-privacy.conf so systemd-user-spawned
# TUIs inherit the same env.
#
# Windows installers should write the same values via HKCU environment
# variables because there is no shell rc file.
set -euo pipefail

MARK_BEGIN='# >>> slopcode-infra opencode privacy >>>'
MARK_END='# <<< slopcode-infra opencode privacy <<<'
# Legacy markers from when this project was named devstral-infra. Stripped
# from existing rc files on first run after the rename so the rewrite stays
# idempotent on already-bootstrapped hosts.
LEGACY_MARK_BEGIN='# >>> devstral-infra opencode privacy >>>'
LEGACY_MARK_END='# <<< devstral-infra opencode privacy <<<'

SHELL_BLOCK=$(cat <<'EOF'
# Disables every non-LLM outbound call opencode makes. Managed by
# slopcode-infra/scripts/opencode_privacy.sh. Do not edit by hand.
export OPENCODE_DISABLE_AUTOUPDATE=1
export OPENCODE_DISABLE_SHARE=1
export OPENCODE_DISABLE_MODELS_FETCH=1
export OPENCODE_DISABLE_LSP_DOWNLOAD=1
export OPENCODE_DISABLE_DEFAULT_PLUGINS=1
export OPENCODE_DISABLE_EMBEDDED_WEB_UI=1
EOF
)

ENV_D_BLOCK=$(cat <<'EOF'
# Managed by slopcode-infra/scripts/opencode_privacy.sh. Do not edit.
OPENCODE_DISABLE_AUTOUPDATE=1
OPENCODE_DISABLE_SHARE=1
OPENCODE_DISABLE_MODELS_FETCH=1
OPENCODE_DISABLE_LSP_DOWNLOAD=1
OPENCODE_DISABLE_DEFAULT_PLUGINS=1
OPENCODE_DISABLE_EMBEDDED_WEB_UI=1
EOF
)

is_linux() { [[ "$(uname -s)" == "Linux" ]]; }

apply_shell_rc() {
  local target="$1"
  [[ -e "${target}" || "${target}" == "${HOME}/.profile" ]] || return 0
  [[ -e "${target}" ]] || : > "${target}"

  python3 - "${target}" "${MARK_BEGIN}" "${MARK_END}" "${SHELL_BLOCK}" "${LEGACY_MARK_BEGIN}" "${LEGACY_MARK_END}" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
begin, end, body = sys.argv[2], sys.argv[3], sys.argv[4]
legacy_begin, legacy_end = sys.argv[5], sys.argv[6]
text = path.read_text() if path.exists() else ""
# Drop any legacy block from when this project was named devstral-infra.
if legacy_begin in text and legacy_end in text:
    pre, rest = text.split(legacy_begin, 1)
    _, post = rest.split(legacy_end, 1)
    text = pre.rstrip() + ("\n\n" if pre.strip() else "") + post.lstrip()
block = f"{begin}\n{body}\n{end}\n"
if begin in text and end in text:
    pre, rest = text.split(begin, 1)
    _, post = rest.split(end, 1)
    new = pre.rstrip() + ("\n\n" if pre.strip() else "") + block + post.lstrip()
else:
    new = text.rstrip() + ("\n\n" if text.strip() else "") + block
path.write_text(new)
PY
  echo "  updated: ${target}"
}

apply_environment_d() {
  is_linux || return 0
  local dir="${XDG_CONFIG_HOME:-${HOME}/.config}/environment.d"
  local file="${dir}/99-opencode-privacy.conf"
  mkdir -p "${dir}"
  printf '%s\n' "${ENV_D_BLOCK}" > "${file}"
  echo "  wrote:   ${file}"
}

echo "pinning opencode privacy env for $(whoami) on $(uname -s)..."
apply_shell_rc "${HOME}/.profile"
[[ -e "${HOME}/.bashrc"   ]] && apply_shell_rc "${HOME}/.bashrc"   || true
[[ -e "${HOME}/.zshrc"    ]] && apply_shell_rc "${HOME}/.zshrc"    || true
[[ -e "${HOME}/.zprofile" ]] && apply_shell_rc "${HOME}/.zprofile" || true
apply_environment_d

cat <<EOF
done. Start a new shell (or 'source ~/.profile') for the vars to take effect.
verify with: env | grep ^OPENCODE_DISABLE_
EOF
