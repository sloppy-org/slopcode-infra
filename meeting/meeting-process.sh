#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

force=0
transcribe_args=()
notes_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context-file|--context-dir|--model)
      notes_args+=("$1" "$2")
      shift 2
      ;;
    --notes-language)
      notes_args+=(--language "$2")
      shift 2
      ;;
    --force)
      force=1
      transcribe_args+=("$1")
      shift
      ;;
    *)
      transcribe_args+=("$1")
      shift
      ;;
  esac
done

meeting_dir="$("${SCRIPT_DIR}/meeting-transcribe.sh" "${transcribe_args[@]}")"
[[ "${force}" -eq 1 ]] && notes_args+=(--force)
notes_args+=("${meeting_dir}")
"${SCRIPT_DIR}/meeting-notes.sh" "${notes_args[@]}"
