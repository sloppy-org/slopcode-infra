# Meeting workflow

The USB installers put these commands on PATH:

```
record-meeting                  # browser microphone recorder, saves timestamped WAV
meeting-transcribe meeting.wav  # writes transcript.json/txt via localhost whisper.cpp
meeting-notes <meeting-folder>  # writes MEETING_NOTES.md via localhost opencode
meeting-process meeting.wav     # transcribe, then generate notes
```

`meeting-notes` writes in the detected meeting language by default.
Override with `--notes-language en|de|match` on `meeting-process` or
`--language en|de|match` on `meeting-notes`.

Explicit meeting documents can be attached with `--context-file PATH`
or `--context-dir PATH`. The transcript remains authoritative.

PCM WAV works without extra codecs. Recordings are split into 5-minute
chunks before transcription, matching the Nextcloud meeting workflow's
large-recording behavior.
