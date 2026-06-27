#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN=""

for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v "$candidate")"
    break
  fi
done

if [[ -z "$PYTHON_BIN" ]]; then
  echo "python3 was not found."
  exit 1
fi

"$PYTHON_BIN" <<'PY'
import json
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ENDPOINT = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"


def parse_time(value):
    if not value:
        return None
    if isinstance(value, (int, float)):
        seconds = value / 1000 if value > 10_000_000_000 else value
        return datetime.fromtimestamp(seconds, tz=timezone.utc)
    if isinstance(value, str):
        value = value.strip()
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        dt = datetime.fromisoformat(value)
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    return None


def format_time(value):
    dt = parse_time(value)
    if not dt:
        return "unknown"
    local = dt.astimezone()
    hour = local.strftime("%I").lstrip("0") or "0"
    return f"{local.strftime('%b')} {local.day}, {hour}:{local:%M %p}"


def time_left(value):
    dt = parse_time(value)
    if not dt:
        return "unknown"
    remaining = dt - datetime.now(dt.tzinfo)
    seconds = int(remaining.total_seconds())
    if seconds <= 0:
        return "expired"
    days, remainder = divmod(seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes = remainder // 60
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"


def first(mapping, names):
    for name in names:
        if isinstance(mapping, dict) and mapping.get(name) is not None:
            return mapping[name]
    return None


def table(headers, rows):
    widths = [
        max(len(str(row[i])) for row in [headers] + rows)
        for i in range(len(headers))
    ]

    def fmt(row):
        return "  ".join(str(cell).ljust(widths[i]) for i, cell in enumerate(row))

    separator = "  ".join("-" * width for width in widths)
    return "\n".join([fmt(headers), separator] + [fmt(row) for row in rows])


auth_path = Path.home() / ".codex" / "auth.json"

try:
    auth = json.loads(auth_path.read_text())
except FileNotFoundError:
    raise SystemExit(f"Auth file not found: {auth_path}")

tokens = auth.get("tokens") or auth
access_token = tokens.get("access_token") or auth.get("access_token")
account_id = (
    tokens.get("account_id")
    or tokens.get("chatgpt_account_id")
    or auth.get("account_id")
    or auth.get("chatgpt_account_id")
)

if not access_token:
    raise SystemExit(f"No access_token found in {auth_path}")

headers = {
    "Accept": "application/json",
    "Authorization": f"Bearer {access_token}",
    "OpenAI-Beta": "codex-1",
    "User-Agent": "codex-reset-expiry-shortcut/1.0",
    "originator": "Codex Desktop",
}

if account_id:
    headers["ChatGPT-Account-ID"] = account_id

req = urllib.request.Request(ENDPOINT, headers=headers)

try:
    with urllib.request.urlopen(req, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", errors="replace")
    raise SystemExit(f"Request failed with HTTP {exc.code}:\n{body}")

credits = payload.get("credits") or payload.get("data") or payload.get("items") or []
count = payload.get("available_count", len(credits))
label = "reset" if count == 1 else "resets"

rows = []
for i, credit in enumerate(credits, 1):
    expires = first(
        credit,
        ("expires_at", "expiresAt", "expiry", "expires", "expiration", "expiration_at"),
    )
    rows.append([i, format_time(expires), time_left(expires)])

now = datetime.now().astimezone()
checked_hour = now.strftime("%I").lstrip("0") or "0"
checked = f"{now.strftime('%b')} {now.day}, {checked_hour}:{now:%M %p %Z}"

lines = [
    "ChatGPT / Codex Reset Credits",
    f"Available: {count} {label}",
    f"Checked: {checked}",
    "",
]

if rows:
    lines.append(table(["#", "Expires", "Time left"], rows))
else:
    lines.append("No reset credits found.")

print("\n".join(lines))
PY
