#!/usr/bin/env bash
# Wire the local sloppy-org MCP servers into every coding
# agent installed on this box (claude, codex, opencode, qwen-code).
#
# Pure stdio: no listening port, no unix socket, no daemon. The agent spawns
# the MCP binary as a subprocess per session, the subprocess inherits the
# agent's UID, and other local users cannot intercept anything. That's the
# right model on shared university workstations where loopback TCP would be
# reachable by every co-tenant.
#
# Idempotent. A missing CLI (or a missing MCP binary) is logged and skipped,
# never an error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

HELPY_BIN="${HELPY_BIN:-$(command -v helpy 2>/dev/null || echo "")}"
SLOPTOOLS_BIN="${SLOPTOOLS_BIN:-$(command -v sloptools 2>/dev/null || echo "")}"
SHOPPY_BIN="${SHOPPY_BIN:-$(command -v shoppy 2>/dev/null || echo "")}"
SLOPTOOLS_DATA_DIR="${SLOPTOOLS_DATA_DIR:-${HOME}/.local/share/sloppy}"
SLOPTOOLS_PROJECT_DIR="${SLOPTOOLS_PROJECT_DIR:-${HOME}}"
QWEN_SETTINGS_PATH="${QWEN_SETTINGS_PATH:-${HOME}/.qwen/settings.json}"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-${HOME}/.config/opencode/opencode.json}"

mkdir -p "${SLOPTOOLS_DATA_DIR}" "$(dirname "${OPENCODE_CONFIG}")" "$(dirname "${QWEN_SETTINGS_PATH}")"

claude_register() {
  local name="$1"; shift
  have claude || { echo "claude CLI not found; skipping ${name}"; return; }
  claude mcp remove -s user "${name}" >/dev/null 2>&1 || true
  claude mcp add -s user "${name}" -- "$@"
  echo "claude: registered ${name} -> $*"
}

codex_register() {
  local name="$1"; shift
  have codex || { echo "codex CLI not found; skipping ${name}"; return; }
  codex mcp remove "${name}" >/dev/null 2>&1 || true
  codex mcp add "${name}" -- "$@"
  echo "codex: registered ${name} -> $*"
}

opencode_register() {
  local name="$1"; shift
  have python3 || { echo "python3 not found; skipping opencode ${name}"; return; }
  if [[ ! -f "${OPENCODE_CONFIG}" ]]; then
    echo "{\"\$schema\": \"https://opencode.ai/config.json\"}" > "${OPENCODE_CONFIG}"
  fi
  python3 - "${OPENCODE_CONFIG}" "${name}" "$@" <<'PY'
import json
import sys

config_path, name, *cmd = sys.argv[1:]
with open(config_path) as f:
    config = json.load(f)
config.setdefault("mcp", {})
config["mcp"][name] = {"type": "local", "command": cmd, "enabled": True}
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PY
  echo "opencode: registered ${name} -> $*"
}

qwen_register() {
  local name="$1"; shift
  have python3 || { echo "python3 not found; skipping qwen ${name}"; return; }
  python3 - "${QWEN_SETTINGS_PATH}" "${name}" "$@" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
name = sys.argv[2]
cmd = sys.argv[3:]

if path.exists() and path.read_text(encoding="utf-8").strip():
    data = json.loads(path.read_text(encoding="utf-8"))
else:
    data = {}
if not isinstance(data, dict):
    raise SystemExit(f"invalid JSON object in {path}")
servers = data.get("mcpServers")
if not isinstance(servers, dict):
    servers = {}
data["mcpServers"] = servers
servers[name] = {"command": cmd[0], "args": cmd[1:]}
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  echo "qwen: registered ${name} -> $*"
}

register_all() {
  local name="$1"; shift
  claude_register "${name}" "$@"
  codex_register "${name}" "$@"
  opencode_register "${name}" "$@"
  qwen_register "${name}" "$@"
}

if [[ -n "${HELPY_BIN}" && -x "${HELPY_BIN}" ]]; then
  register_all "helpy" "${HELPY_BIN}" "mcp-stdio"
else
  warn "helpy binary not found on PATH; skipping helpy MCP install"
fi

if [[ -n "${SLOPTOOLS_BIN}" && -x "${SLOPTOOLS_BIN}" ]]; then
  register_all "sloppy" "${SLOPTOOLS_BIN}" "mcp-server" \
    "--project-dir" "${SLOPTOOLS_PROJECT_DIR}" \
    "--data-dir" "${SLOPTOOLS_DATA_DIR}"
else
  warn "sloptools binary not found on PATH; skipping sloptools MCP install"
fi

if [[ -n "${SHOPPY_BIN}" && -x "${SHOPPY_BIN}" ]]; then
  register_all "shoppy" "${SHOPPY_BIN}" "mcp-stdio"
else
  warn "shoppy binary not found on PATH; skipping shoppy MCP install"
fi

echo ""
echo "next: open claude/codex/opencode and confirm with 'claude mcp list' etc."
