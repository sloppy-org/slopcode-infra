#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/meeting-common.sh"

usage() {
  cat <<'EOF'
Usage:
  meeting-notes [options] <meeting-folder|transcript.txt>

Options:
  --output PATH        Output markdown path. Default: <meeting-folder>/MEETING_NOTES.md
  --context-file PATH  Attach an explicit meeting context document. Repeatable
  --context-dir PATH   Attach regular files from this meeting context folder
  --language MODE      en, de, or match. Default: match
  --model MODEL        opencode model. Default: OPENCODE_MODEL or llamacpp/qwen
  --force              Overwrite existing note
  --help               Show this help
EOF
}

output=""
language="match"
model="${OPENCODE_MODEL:-llamacpp/qwen}"
force=0
context_files=()
context_dirs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --context-file) context_files+=("$(meeting_abs "$2")"); shift 2 ;;
    --context-dir) context_dirs+=("$(meeting_abs "$2")"); shift 2 ;;
    --language) language="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --force) force=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) meeting_die "unknown option: $1" ;;
    *) break ;;
  esac
done

[[ $# -eq 1 ]] || { usage >&2; exit 1; }
target="$(meeting_abs "$1")"
if [[ -d "${target}" ]]; then
  meeting_dir="${target}"
  transcript="${meeting_dir}/transcript.txt"
else
  transcript="${target}"
  meeting_dir="$(dirname "${transcript}")"
fi
[[ -f "${transcript}" ]] || meeting_die "transcript.txt not found: ${transcript}"

meeting_require opencode
meeting_require python3
meeting_require mktemp

metadata="${meeting_dir}/metadata.json"
transcript_json="${meeting_dir}/transcript.json"
[[ -n "${output}" ]] || output="${meeting_dir}/MEETING_NOTES.md"
output="$(meeting_abs "${output}")"
mkdir -p "$(dirname "${output}")"
if [[ -e "${output}" && "${force}" -ne 1 ]]; then
  meeting_die "note exists at ${output}; use --force to overwrite"
fi

case "${language}" in
  en) language_instruction="Write the note in English and use the English template labels." ;;
  de) language_instruction="Write the note in German and use the German template labels." ;;
  match)
    detected=""
    if [[ -f "${transcript_json}" ]]; then
      detected="$(meeting_json_field "${transcript_json}" language || true)"
    fi
    case "${detected}" in
      de) language_instruction="Write the note in German and use the German template labels." ;;
      en) language_instruction="Write the note in English and use the English template labels." ;;
      *) language_instruction="Infer the dominant meeting language from the transcript. Write in that language, using German labels for German and English labels for English." ;;
    esac
    ;;
  *) meeting_die "unsupported language mode: ${language}" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
prompt="${tmp}/meeting-prompt.txt"
response="${tmp}/meeting-note.md"
metadata_text="{}"
[[ -f "${metadata}" ]] && metadata_text="$(cat "${metadata}")"
for dir in "${context_dirs[@]}"; do
  [[ -d "${dir}" ]] || meeting_die "context directory not found: ${dir}"
  while IFS= read -r file; do
    context_files+=("${file}")
  done < <(find "${dir}" -maxdepth 1 -type f \
    ! -name 'MEETING_NOTES.md' \
    ! -name 'transcript.txt' \
    ! -name 'transcript.json' \
    ! -name 'metadata.json' \
    ! -name '.DS_Store' \
    -print | sort)
done
for file in "${context_files[@]}"; do
  [[ -f "${file}" ]] || meeting_die "context file not found: ${file}"
done

context_list="none"
if [[ "${#context_files[@]}" -gt 0 ]]; then
  context_list="$(printf '%s\n' "${context_files[@]}")"
fi

cat >"${prompt}" <<EOF
Generate concise but complete meeting notes from the supplied transcript.

Constraints:
- ${language_instruction}
- Use explicit context files only when they clarify the transcript or meeting outcome. The transcript remains authoritative for what was actually said.
- The transcript may contain Whisper errors, repeated loops, bad punctuation, homophones, and mixed German/English technical terms.
- Correct obvious transcription mistakes only when context strongly supports the correction.
- Keep names, institutions, product names, acronyms, paths, code identifiers, and mathematical expressions precise.
- Infer participants conservatively. A person discussed in the meeting is not automatically present.
- Separate decisions, tasks, open questions, and topic walkthrough.
- Assign tasks to named owners only when the transcript supports ownership.
- Use markdown checkboxes for action items.
- Output only the final markdown note. No preamble, no explanation, no code fence.

Template:
$(cat "${SCRIPT_DIR}/meeting-notes-template.md")

Participant hints:
$(cat "${SCRIPT_DIR}/participant-name-hints.txt")

Metadata JSON:
${metadata_text}

Explicit context files:
${context_list}

Transcript:
$(cat "${transcript}")
EOF

opencode_args=(run --model "${model}" --file "${prompt}")
for file in "${context_files[@]}"; do
  opencode_args+=(--file "${file}")
done

if ! opencode "${opencode_args[@]}" \
    "Follow the attached prompt exactly and output only the meeting note markdown." \
    >"${response}"; then
  meeting_die "opencode failed while generating meeting notes"
fi
[[ -s "${response}" ]] || meeting_die "opencode produced no meeting note"
cp "${response}" "${output}"
printf '%s\n' "${output}"
