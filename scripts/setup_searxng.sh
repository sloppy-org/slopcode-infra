#!/usr/bin/env bash
# Install or update a local SearXNG checkout plus its Python environment and a
# localhost-only default configuration.
#
# The install stays inside the user's profile:
#   source checkout  -> ~/code/searxng when ~/code exists, else ~/.local/searxng/src
#   virtualenv       -> ~/.local/searxng/.venv
#   settings.yml     -> ~/.config/searxng/settings.yml
#   runtime URL      -> http://127.0.0.1:8888
#
# Env overrides:
#   SEARXNG_HOME          runtime home (default ~/.local/searxng)
#   SEARXNG_SRC           git checkout path
#   SEARXNG_REF           git ref to track (default master)
#   SEARXNG_VENV          virtualenv path
#   SEARXNG_SETTINGS_DIR  config dir (default ~/.config/searxng)
#   SEARXNG_SETTINGS_PATH config file path
#   SEARXNG_BIND_ADDRESS  listen address (default 127.0.0.1)
#   SEARXNG_PORT          listen port (default 8888)
#   SEARXNG_BASE_URL      public local URL (default http://127.0.0.1:8888)
#   SEARXNG_METHOD        GET or POST (default GET)
#   SEARXNG_SAFE_SEARCH   0 none, 1 moderate, 2 strict (default 0)
#   SEARXNG_AUTOCOMPLETE  autocomplete backend (default blank/off)
#   SEARXNG_IMAGE_PROXY   true/false (default true)
#   SEARXNG_SECRET        explicit secret key; auto-generated when omitted
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

default_searxng_src() {
  if [[ -d "${HOME}/code" ]]; then
    echo "${HOME}/code/searxng"
  else
    echo "${HOME}/.local/searxng/src"
  fi
}

SEARXNG_HOME="${SEARXNG_HOME:-${HOME}/.local/searxng}"
SEARXNG_SRC="${SEARXNG_SRC:-$(default_searxng_src)}"
SEARXNG_REF="${SEARXNG_REF:-master}"
SEARXNG_VENV="${SEARXNG_VENV:-${SEARXNG_HOME}/.venv}"
SEARXNG_SETTINGS_DIR="${SEARXNG_SETTINGS_DIR:-${HOME}/.config/searxng}"
SEARXNG_SETTINGS_PATH="${SEARXNG_SETTINGS_PATH:-${SEARXNG_SETTINGS_DIR}/settings.yml}"
SEARXNG_BIND_ADDRESS="${SEARXNG_BIND_ADDRESS:-127.0.0.1}"
SEARXNG_PORT="${SEARXNG_PORT:-8888}"
SEARXNG_BASE_URL="${SEARXNG_BASE_URL:-http://127.0.0.1:${SEARXNG_PORT}}"
SEARXNG_METHOD="${SEARXNG_METHOD:-GET}"
SEARXNG_SAFE_SEARCH="${SEARXNG_SAFE_SEARCH:-0}"
SEARXNG_AUTOCOMPLETE="${SEARXNG_AUTOCOMPLETE:-}"
SEARXNG_IMAGE_PROXY="${SEARXNG_IMAGE_PROXY:-true}"

have git || die "git is required"
have python3 || die "python3 is required"

mkdir -p "${SEARXNG_HOME}" "${SEARXNG_SETTINGS_DIR}" "$(dirname "${SEARXNG_SRC}")"

if [[ ! -d "${SEARXNG_SRC}/.git" ]]; then
  echo "cloning searxng into ${SEARXNG_SRC}"
  git clone https://github.com/searxng/searxng.git "${SEARXNG_SRC}"
fi

cd "${SEARXNG_SRC}"
git fetch --all --tags --prune --quiet
echo "checking out searxng ${SEARXNG_REF}"
git checkout "${SEARXNG_REF}"
if git symbolic-ref -q HEAD >/dev/null; then
  git pull --ff-only --quiet
fi
SEARXNG_HEAD="$(git rev-parse HEAD)"

if have uv; then
  uv venv --seed --clear --python python3 "${SEARXNG_VENV}" >/dev/null
else
  python3 -m venv "${SEARXNG_VENV}"
fi

VENV_PYTHON="${SEARXNG_VENV}/bin/python"
[[ -x "${VENV_PYTHON}" ]] || die "python missing from virtualenv: ${VENV_PYTHON}"
if ! "${VENV_PYTHON}" -m pip --version >/dev/null 2>&1; then
  "${VENV_PYTHON}" -m ensurepip --upgrade >/dev/null
fi

echo "installing python packages into ${SEARXNG_VENV}"
"${VENV_PYTHON}" -m pip install -U pip setuptools wheel pyyaml msgspec typing-extensions pybind11 granian >/dev/null
"${VENV_PYTHON}" -m pip install --use-pep517 --no-build-isolation -e "${SEARXNG_SRC}" >/dev/null

SEARXNG_SECRET="${SEARXNG_SECRET:-}"
if [[ -z "${SEARXNG_SECRET}" && -f "${SEARXNG_SETTINGS_PATH}" ]]; then
  SEARXNG_SECRET="$(awk -F'"' '/secret_key:/{print $2; exit}' "${SEARXNG_SETTINGS_PATH}" || true)"
fi
if [[ -z "${SEARXNG_SECRET}" ]]; then
  SEARXNG_SECRET="$("${VENV_PYTHON}" -c 'import secrets; print(secrets.token_urlsafe(32))')"
fi

cat > "${SEARXNG_SETTINGS_PATH}" <<EOF
use_default_settings:
  engines:
    keep_only:
      - aol
      - wikipedia
      - bing
      - mojeek
      - searchmysite
      - wiby
      - presearch

general:
  debug: false
  instance_name: "SearXNG (local)"

search:
  safe_search: ${SEARXNG_SAFE_SEARCH}
  autocomplete: '${SEARXNG_AUTOCOMPLETE}'
  ban_time_on_fail: 60
  max_ban_time_on_fail: 3600
  suspended_times:
    SearxEngineAccessDenied: 3600
    SearxEngineCaptcha: 21600
    SearxEngineTooManyRequests: 3600
  formats:
    - html
    - json
    - rss

server:
  base_url: ${SEARXNG_BASE_URL}
  bind_address: "${SEARXNG_BIND_ADDRESS}"
  port: ${SEARXNG_PORT}
  secret_key: "${SEARXNG_SECRET}"
  limiter: false
  public_instance: false
  image_proxy: ${SEARXNG_IMAGE_PROXY}
  method: "${SEARXNG_METHOD}"

outgoing:
  retries: 0
  pool_connections: 10
  pool_maxsize: 2

engines:
  - name: bing
    disabled: false
  - name: mojeek
    disabled: false
  - name: searchmysite
    disabled: false
  - name: wiby
    disabled: false
  - name: presearch
    disabled: false
EOF

echo "searxng ready"
echo "- source:   ${SEARXNG_SRC} (${SEARXNG_HEAD:0:12})"
echo "- venv:     ${SEARXNG_VENV}"
echo "- config:   ${SEARXNG_SETTINGS_PATH}"
echo "- endpoint: ${SEARXNG_BASE_URL}"
echo "- next:     scripts/server_start_searxng.sh (foreground) or a platform install script"
