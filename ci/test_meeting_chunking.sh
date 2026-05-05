#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/bin" "${TMP}/out-bash" "${TMP}/out-ps"
cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "${arg}" == '%{http_code}' ]]; then
    printf '200'
    exit 0
  fi
done
cat <<'JSON'
{"text":"chunk","language":"en","duration":1,"segments":[{"start":0,"end":1,"text":"chunk"}]}
JSON
EOF
chmod +x "${TMP}/bin/curl"
cp "${TMP}/bin/curl" "${TMP}/bin/curl.exe"

python3 - "${TMP}/meeting.wav" <<'PY'
import math
import struct
import sys
import wave

rate = 16000
seconds = 7
with wave.open(sys.argv[1], "wb") as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(rate)
    for i in range(rate * seconds):
        sample = int(1200 * math.sin(i / 18.0))
        wav.writeframes(struct.pack("<h", sample))
PY

check_json() {
  local json="$1"
  python3 - "${json}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
starts = [round(float(seg["start"]), 3) for seg in data["segments"]]
assert data["text"] == "chunk chunk chunk", data["text"]
assert starts == [0.0, 3.0, 6.0], starts
assert data["language"] == "en", data["language"]
PY
}

bash_dir="$(
  PATH="${TMP}/bin:${PATH}" MEETING_OUTPUT_ROOT="${TMP}/out-bash" \
    "${ROOT}/meeting/meeting-transcribe.sh" --chunk-seconds 3 "${TMP}/meeting.wav"
)"
check_json "${bash_dir}/transcript.json"

if command -v pwsh >/dev/null 2>&1; then
  ps_dir="$(
    PATH="${TMP}/bin:${PATH}" pwsh -NoProfile -File "${ROOT}/meeting/meeting-transcribe.ps1" \
      -Audio "${TMP}/meeting.wav" \
      -OutputRoot "${TMP}/out-ps" \
      -ChunkSeconds 3
  )"
  check_json "${ps_dir}/transcript.json"
fi

echo "meeting chunking tests passed"
