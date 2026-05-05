#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
recorder="${SCRIPT_DIR}/record-meeting.html"
[[ -f "${recorder}" ]] || { echo "missing recorder: ${recorder}" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) open "${recorder}" ;;
  Linux) xdg-open "${recorder}" ;;
  *) echo "open this file in a browser: ${recorder}" ;;
esac
