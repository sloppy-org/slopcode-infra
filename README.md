# slopcode-infra

Single-path local coding stack: **llama.cpp + Qwen3.6 35B A3B (UD-Q4_K_M) +
OpenCode**, whisper.cpp, meeting tools, and voxtype install scripts.
Every component lives in the user profile and runs as a user-level service.
No root, no admin.

License: [MIT](LICENSE)

## The one blessed configuration

| Target           | OS      | GPU          | Memory         | Backend | CPU-MoE |
| ---------------- | ------- | ------------ | -------------- | ------- | ------- |
| Local (this box) | Linux   | NVIDIA 16 GB | 96 GB          | CUDA    | on      |
| Intel Arc box    | Windows | Intel Arc    | 32 GB shared   | Vulkan  | on      |
| Apple M1         | macOS   | M1           | 32 GB unified  | Metal   | off     |

- **Model**: `unsloth/Qwen3.6-35B-A3B-GGUF` at `UD-Q4_K_M` (~22 GB), served as `qwen`.
- **Runtime**: `llama-server` (upstream release, Q8_0 KV, 128 K context, `-fa on`, `--jinja`).
- **Harnesses**: `opencode` by default; title generation disabled for OpenCode, local llama.cpp provider, telemetry disabled, `reasoning: true`, server-enforced thinking budget (`4096` by default).

Nothing else is downloaded automatically. Optional aliases live in
`scripts/llamacpp_models.py` for manual prefetch only, including the FortBench
MiniMax benchmark profiles.

## Install from this repo

Every script below runs as the unprivileged user and assumes `git`,
`cmake`, `ninja`, and `curl`.

```
scripts/setup_llamacpp.sh                     # fetch latest upstream release for this OS
python3 scripts/llamacpp_models.py prefetch   # download the blessed model
scripts/server_start_llamacpp.sh              # foreground run, smoke test
scripts/install_linux_systemd.sh              # systemd --user unit (Linux)
scripts/install_mac_launchagents.sh           # launchd user agents (macOS)
scripts/opencode_install.sh                   # curl|bash the opencode CLI
scripts/opencode_set_llamacpp.sh              # write ~/.config/opencode/opencode.json
opencode                                      # go
```

## Whisper.cpp (STT for voxtype, slopbox, meeting notes)

Whisper.cpp builds from source against the local GPU (CUDA on Linux/NVIDIA,
Metal on Mac, Vulkan on Linux/Windows without CUDA). The same scripts power
the macOS launchd agent (`com.slopcode.whisper-server`) and a Linux
`systemd --user` unit (`whisper-server.service`).

```
scripts/setup_whisper.sh                      # clone + build into ~/code/whisper.cpp
                                              # (falls back to ~/.local/whisper.cpp
                                              #  if ~/code is absent)
scripts/install_linux_whisper_systemd.sh      # systemd --user unit (Linux)
scripts/install_mac_launchagents.sh           # bundles whisper-server agent on macOS
```

The server speaks the OpenAI `/v1/audio/transcriptions` API on
`http://127.0.0.1:8427` so any whisper-1 client (voxtype, slopbox, the
voice-memo classifier) works against it without changes.

If a previous installation left the AUR `whisper.cpp-cuda` package in place
the installer refuses to clobber the system unit and prints the one-time
`sudo pacman -Rns ...` line to remove it. The new user-level unit then takes
the same `:8427` port.

## Meeting workflow

The USB installers put these commands on PATH:

```
record-meeting                                # browser microphone recorder, saves timestamped WAV
meeting-transcribe meeting.wav                # writes transcript.json/txt via localhost whisper.cpp
meeting-notes <meeting-folder>                # writes MEETING_NOTES.md via localhost opencode
meeting-process meeting.wav                   # transcribe, then generate notes
```

`meeting-notes` writes in the detected meeting language by default. Use
`--notes-language en|de|match` with `meeting-process`, or
`--language en|de|match` with `meeting-notes`, to override. Explicit meeting
documents can be attached with `--context-file PATH` or `--context-dir PATH`;
the transcript remains authoritative. PCM WAV works without extra codecs and
is split into 5-minute chunks before transcription, matching the Nextcloud
meeting workflow's large-recording behavior.

## USB bundle

Build a localhost-only offline bundle for colleagues:

```
scripts/build_bundle.sh all --out /mnt/usb
```

The bundle includes llama.cpp, opencode, whisper.cpp, Qwen3.6 35B A3B
UD-Q4_K_M, the Qwen mmproj, and `ggml-large-v3-turbo.bin`. It does not include
Pi, Node, or an npm cache. Generated installers bind llama.cpp to
`127.0.0.1:8080` and whisper.cpp to `127.0.0.1:8427`; opencode is configured
only against the local llama.cpp endpoint with telemetry/share/update/model
fetch paths disabled. The installers also add the meeting commands above to
PATH and start the llama.cpp and whisper.cpp services.

## Voxtype install (push-to-talk dictation)

`peteonrails/voxtype` is the Linux-native push-to-talk dictation daemon. The
helpers below wrap the upstream release artefacts so the user does not have
to read the upstream README before hitting the F-key.

```
scripts/install_voxtype_linux.sh              # systemd --user, deb/rpm fallback
scripts/install_voxtype_mac.sh                # documented manual path (no Mac binary upstream)
scripts/install_voxtype_windows.ps1           # documented manual path (no Windows binary upstream)
```

The Linux installer detects GPU class (CUDA / Vulkan / CPU-only) and pulls
the matching release binary; it points the daemon at the local whisper
server on `127.0.0.1:8427` by default and registers a `systemd --user`
service. macOS and Windows scripts surface the upstream non-goal of those
platforms instead of pretending support exists.

## Tests

```
bash ci/run_tests.sh
```

Exercises the llama.cpp launcher (dry-run), the OpenCode config generator,
USB and meeting script syntax/help, and a pure-stdlib mock-server health
check. Real inference is out of scope for CI.
