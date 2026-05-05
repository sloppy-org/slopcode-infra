#!/usr/bin/env bash
set -euo pipefail

meeting_die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

meeting_require() {
  command -v "$1" >/dev/null 2>&1 || meeting_die "missing required command: $1"
}

meeting_abs() {
  local target="$1"
  if [[ -d "${target}" ]]; then
    (cd "${target}" && pwd)
  else
    local dir base
    dir="$(dirname "${target}")"
    base="$(basename "${target}")"
    (cd "${dir}" && printf '%s/%s\n' "$(pwd)" "${base}")
  fi
}

meeting_output_root() {
  if [[ -n "${MEETING_OUTPUT_ROOT:-}" ]]; then
    printf '%s\n' "${MEETING_OUTPUT_ROOT}"
  elif [[ -d "${HOME}/Nextcloud/plasma/DOCUMENTS/MEETINGS" ]]; then
    printf '%s\n' "${HOME}/Nextcloud/plasma/DOCUMENTS/MEETINGS"
  else
    printf '%s\n' "${HOME}/Meetings"
  fi
}

meeting_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/\.[^.]+$//; s/[^a-z0-9]+/_/g; s/^_+//; s/_+$//; s/__+/_/g'
}

meeting_timestamp() {
  date '+%Y%m%d-%H%M%S'
}

meeting_recorded_parts() {
  local file="$1"
  if date -r "${file}" '+%Y-%m-%d	%H%M%S' >/dev/null 2>&1; then
    date -r "${file}" '+%Y-%m-%d	%H%M%S'
  else
    stat -c '%y' "${file}" | awk '{gsub(/:/, "", $2); print $1 "\t" substr($2,1,6)}'
  fi
}

meeting_json_text() {
  python3 - "$1" "$2" <<'PY'
import json
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
data = json.loads(src.read_text(encoding="utf-8"))
text = data.get("text") or ""
if not text:
    parts = []
    for seg in data.get("segments") or []:
        value = (seg.get("text") or "").strip()
        if value:
            parts.append(value)
    text = " ".join(parts)
dst.write_text(text.strip() + "\n", encoding="utf-8")
PY
}

meeting_json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
value = data
for part in sys.argv[2].split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
print("" if value is None else value)
PY
}
