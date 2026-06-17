# slopcode-infra

Local coding stack that runs entirely in the user profile: **llama.cpp
+ Qwen3.6 27B (Q4_K_M) + OpenCode**, plus whisper.cpp, meeting tools,
and dictation. No root, no admin. User-level services on Linux,
macOS, and Windows.

License: [MIT](LICENSE)

## Supported hosts

| Target           | OS      | GPU          | Memory        | Backend | CPU-MoE |
| ---------------- | ------- | ------------ | ------------- | ------- | ------- |
| Local (this box) | Linux   | NVIDIA 16 GB | 96 GB         | CUDA    | on      |
| Intel Arc box    | Windows | Intel Arc    | 32 GB shared  | Vulkan  | on      |
| Apple M1         | macOS   | M1           | 32 GB unified | Metal   | off     |

- **Model:** `bartowski/Qwen_Qwen3.6-27B-GGUF` at `Q4_K_M` (~18 GB),
  served as `qwen`.
- **Runtime:** `llama-server` (upstream release, Q8_0 KV, 128 K
  context, `-fa on`, `--jinja`).
- **Harness:** `opencode`. Title generation disabled, local llama.cpp
  provider only, telemetry off, `reasoning: true`, server-enforced
  thinking budget (`4096` by default).

Nothing else is downloaded automatically. Optional aliases live in
`scripts/llamacpp_models.py` for manual prefetch, including the
35B-A3B and FortBench profiles.

## Install

Every script runs as the unprivileged user and assumes `git`,
`cmake`, `ninja`, and `curl`.

```
scripts/setup_llamacpp.sh                     # fetch latest upstream release for this OS
python3 scripts/llamacpp_models.py prefetch   # download the blessed model
scripts/server_start_qwen27b.sh               # on-demand foreground run, smoke test
scripts/install_linux_systemd.sh              # systemd --user unit (Linux)
scripts/install_mac_launchagents.sh           # launchd user agents (macOS)
scripts/opencode_install.sh                   # curl|bash the opencode CLI
scripts/opencode_set_llamacpp.sh              # write ~/.config/opencode/opencode.json
opencode                                      # go
```

## Components

| Component | Doc |
| --- | --- |
| SearXNG (local web search for Helpy)         | [docs/searxng.md](docs/searxng.md) |
| Whisper.cpp (STT server on `:8427`)          | [docs/whisper.md](docs/whisper.md) |
| Meeting workflow (record, transcribe, notes) | [docs/meeting.md](docs/meeting.md) |
| Voxtype (push-to-talk dictation)             | [docs/voxtype.md](docs/voxtype.md) |
| USB bundle and chat-vs-coder swap            | [docs/usb-bundle.md](docs/usb-bundle.md) |
| FIM autocomplete endpoint (Coder, 2nd port)  | [docs/fim-autocomplete.md](docs/fim-autocomplete.md) |
| AI model share (NFS from faepmac1)           | [docs/ai-share.md](docs/ai-share.md) |

## Tests

```
bash ci/run_tests.sh
```

Covers the llama.cpp launcher (dry-run), the OpenCode config
generator, USB and meeting script syntax/help, and a pure-stdlib
mock-server health check. CI does not run real inference.
