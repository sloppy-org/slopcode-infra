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
  --chunk-seconds N    WAV chunk size for long recordings. Default: 300
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
chunk_seconds="${MEETING_CHUNK_SECONDS:-300}"
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-root) output_root="$2"; shift 2 ;;
    --meeting-name) meeting_name="$2"; shift 2 ;;
    --language) language="$2"; shift 2 ;;
    --base-url) base_url="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --chunk-seconds) chunk_seconds="$2"; shift 2 ;;
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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

transcribe_chunk() {
  local chunk_audio="$1" chunk_mime="$2" out_json="$3" attempt
  local chunk_curl_args=(
    -fsS --max-time 3600
    "${base_url}/v1/audio/transcriptions"
    -F "file=@${chunk_audio};type=${chunk_mime}"
    -F "model=${model}"
    -F "response_format=verbose_json"
  )
  if [[ -n "${language}" ]]; then
    chunk_curl_args+=(-F "language=${language}")
  fi
  for attempt in 1 2 3; do
    if curl "${chunk_curl_args[@]}" >"${out_json}.partial" \
      && python3 -m json.tool "${out_json}.partial" >/dev/null 2>&1; then
      mv "${out_json}.partial" "${out_json}"
      return 0
    fi
    rm -f "${out_json}.partial"
    printf 'chunk attempt %d failed, retrying in %ds\n' "${attempt}" "$((attempt * 5))" >&2
    sleep "$((attempt * 5))"
  done
  return 1
}

if [[ "${mime}" == "audio/wav" ]]; then
  manifest="${tmp_dir}/chunks.tsv"
  python3 - "${audio}" "${tmp_dir}/chunks" "${chunk_seconds}" >"${manifest}" <<'PY'
import math
import pathlib
import sys
import wave

src = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
chunk_seconds = int(sys.argv[3])
if chunk_seconds <= 0:
    raise SystemExit("chunk seconds must be positive")
out_dir.mkdir(parents=True, exist_ok=True)

with wave.open(str(src), "rb") as wav:
    params = wav.getparams()
    frames = wav.getnframes()
    rate = wav.getframerate()
    duration = frames / float(rate)
    frames_per_chunk = max(1, chunk_seconds * rate)
    n_chunks = max(1, math.ceil(frames / frames_per_chunk))
    for idx in range(n_chunks):
        start = idx * frames_per_chunk
        count = min(frames_per_chunk, frames - start)
        wav.setpos(start)
        data = wav.readframes(count)
        chunk = out_dir / f"chunk_{idx:04d}.wav"
        with wave.open(str(chunk), "wb") as out:
            out.setparams(params)
            out.writeframes(data)
        print(f"{chunk}\t{start / rate:.6f}\t{count / rate:.6f}\t{duration:.6f}")
PY
  n_chunks="$(wc -l <"${manifest}" | tr -d ' ')"
  if [[ "${n_chunks}" -gt 1 ]]; then
    printf 'Audio is long; splitting into %s WAV chunks of %ss\n' "${n_chunks}" "${chunk_seconds}" >&2
  fi
  result_dir="${tmp_dir}/results"
  mkdir -p "${result_dir}"
  idx=0
  while IFS=$'\t' read -r chunk_file offset _duration _total; do
    chunk_json="${result_dir}/chunk_$(printf '%04d' "${idx}").json"
    printf 'Transcribing chunk %d/%d\n' "$((idx + 1))" "${n_chunks}" >&2
    transcribe_chunk "${chunk_file}" "audio/wav" "${chunk_json}" \
      || meeting_die "transcription failed for chunk $((idx + 1))"
    printf '%s\t%s\n' "${chunk_json}" "${offset}" >>"${tmp_dir}/results.tsv"
    idx=$((idx + 1))
  done <"${manifest}"
  python3 - "${tmp_dir}/results.tsv" "${json_out}" <<'PY'
import json
import sys

rows = []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        path, offset = line.rstrip("\n").split("\t")
        with open(path, encoding="utf-8") as chunk:
            rows.append((json.load(chunk), float(offset)))

merged = {"text": "", "language": "unknown", "duration": 0.0, "segments": []}
for data, offset in rows:
    text = (data.get("text") or "").strip()
    if text:
        merged["text"] = (merged["text"] + " " + text).strip()
    if data.get("language"):
        merged["language"] = data["language"]
    merged["duration"] = max(merged["duration"], offset + float(data.get("duration") or 0))
    for seg in data.get("segments") or []:
        copied = dict(seg)
        copied["start"] = float(copied.get("start") or 0) + offset
        copied["end"] = float(copied.get("end") or 0) + offset
        copied["id"] = len(merged["segments"])
        merged["segments"].append(copied)
if merged["duration"] == 0 and rows:
    merged["duration"] = rows[-1][1]
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(merged, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
else
  transcribe_chunk "${audio}" "${mime}" "${json_out}" \
    || meeting_die "transcription failed. For M4A, retry with a WAV file if ffmpeg is not installed for whisper-server."
fi
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
