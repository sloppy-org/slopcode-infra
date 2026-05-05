#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/meeting-common.sh"

usage() {
  cat <<'EOF'
Usage:
  meeting-transcribe [options] <audio.wav|audio.m4a>

Options:
  --output-root PATH   Meeting archive root. Default: Nextcloud meetings if present, else ~/Meetings
  --meeting-name NAME  Folder name hint. Default: audio filename
  --language CODE      Whisper language. Default: auto
  --base-url URL       whisper.cpp base URL. Default: http://127.0.0.1:8427
  --model NAME         Model name sent to the endpoint. Default: whisper-1
  --force              Overwrite transcript artifacts in the output folder
  --help               Show this help

WAV is dependency-free. M4A is submitted as-is and only works when the local
whisper-server has audio conversion support available.
EOF
}

output_root="$(meeting_output_root)"
meeting_name=""
language="${WHISPER_LANGUAGE:-auto}"
base_url="${WHISPER_BASE_URL:-http://127.0.0.1:8427}"
model="${WHISPER_MODEL:-whisper-1}"
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-root) output_root="$2"; shift 2 ;;
    --meeting-name) meeting_name="$2"; shift 2 ;;
    --language) language="$2"; shift 2 ;;
    --base-url) base_url="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --force) force=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) meeting_die "unknown option: $1" ;;
    *) break ;;
  esac
done

[[ $# -eq 1 ]] || { usage >&2; exit 1; }
audio="$(meeting_abs "$1")"
[[ -f "${audio}" ]] || meeting_die "audio file not found: ${audio}"

meeting_require curl
meeting_require python3

case "${audio,,}" in
  *.wav) mime="audio/wav" ;;
  *.m4a) mime="audio/mp4" ;;
  *) meeting_die "unsupported audio type. Use WAV, or M4A when whisper-server conversion is available." ;;
esac

base_url="${base_url%/}"
probe="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "${base_url}/" 2>/dev/null || true)"
[[ -n "${probe}" && "${probe}" != "000" ]] || meeting_die "whisper-server unreachable at ${base_url}"

IFS=$'\t' read -r recorded_date recorded_time < <(meeting_recorded_parts "${audio}")
stem="$(basename "${audio}")"
stem="${stem%.*}"
slug="$(meeting_slug "${meeting_name:-${recorded_time}_${stem}}")"
meeting_dir="${output_root}/${recorded_date}_${slug}"
mkdir -p "${meeting_dir}"

json_out="${meeting_dir}/transcript.json"
txt_out="${meeting_dir}/transcript.txt"
metadata_out="${meeting_dir}/metadata.json"
if [[ -e "${json_out}" && "${force}" -ne 1 ]]; then
  meeting_die "transcript exists in ${meeting_dir}; use --force to overwrite"
fi

curl_args=(
  -fsS --max-time 7200
  "${base_url}/v1/audio/transcriptions"
  -F "file=@${audio};type=${mime}"
  -F "model=${model}"
  -F "response_format=verbose_json"
)
if [[ -n "${language}" ]]; then
  curl_args+=(-F "language=${language}")
fi

if ! curl "${curl_args[@]}" >"${json_out}.partial"; then
  rm -f "${json_out}.partial"
  meeting_die "transcription failed. For M4A, retry with a WAV file if ffmpeg is not installed for whisper-server."
fi
python3 -m json.tool "${json_out}.partial" >/dev/null || meeting_die "transcription response was not valid JSON"
mv "${json_out}.partial" "${json_out}"
meeting_json_text "${json_out}" "${txt_out}"

detected_language="$(meeting_json_field "${json_out}" language || true)"
python3 - "${metadata_out}" "${audio}" "$(basename "${audio}")" "${recorded_date}" "${recorded_time}" "${language}" "${detected_language}" "${base_url}" "${model}" <<'PY'
import json
import sys

out, source, source_name, recorded_date, recorded_time, language, detected, base_url, model = sys.argv[1:]
data = {
    "source_file": source,
    "source_file_name": source_name,
    "recorded_date": recorded_date,
    "recorded_time": recorded_time,
    "meeting_language_mode": language,
    "detected_language": detected,
    "whisper_request": {
        "base_url": base_url,
        "model": model,
        "language": language,
    },
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

printf '%s\n' "${meeting_dir}"
