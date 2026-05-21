# USB bundle

Build a localhost-only offline bundle for colleagues:

```
scripts/build_bundle.sh all --out /mnt/usb
```

The bundle includes:

- llama.cpp (latest release) — Vulkan on Linux, Metal on macOS,
  **SYCL / oneAPI on Windows** (switched from Vulkan 2026-05-22; sidesteps
  the active Vulkan-Arc bugs and gives ~2x prefill on Lunar Lake).
- opencode, whisper.cpp.
- Qwen3.6-35B-A3B UD-IQ4_XS from `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`
  (~18 GB) — the single chat GGUF for the bundle. Carries the MTP
  head so the generated launchers run `--spec-type draft-mtp` for
  the 1.4-2.2x decode speedup; the same file runs without MTP at
  lower decode speed if the host's backend misbehaves on the MTP
  path.
- The Qwen mmproj and `ggml-large-v3-turbo.bin`.
- The `local-luna` tutorial, the latest llama.vscode VSIX with
  settings helpers, and current LM Studio desktop installers for
  manual fallback.

Bundle size is roughly 24 GB on disk (~18 GGUF + ~1 mmproj +
~1.6 whisper + binaries / opencode / docs). A 32 GB USB stick is
the sane minimum.

It does not include Pi, Node, or an npm cache.

Each per-platform directory ships a single `install.{sh,bat}` that
runs the full install: copies the bundled llama.cpp / opencode /
whisper.cpp / meeting scripts into the user profile, writes the
launcher, registers the service, and configures opencode against
the local endpoint.

Generated installers:

- bind llama.cpp to `127.0.0.1:8080`,
- bind whisper.cpp to `127.0.0.1:8427`,
- put the meeting scripts on PATH,
- configure opencode only against the local llama.cpp endpoint with
  telemetry, share, update, and model-fetch paths disabled,
- enable MTP speculative decoding (`--spec-type draft-mtp
  --spec-draft-n-max 2`) plus the Qwen "Thinking + general" sampler
  (`--temp 1.0 --top-p 0.95 --top-k 20 --presence-penalty 1.5`) for
  ~1.4-2.2x decode speedup on hosts that support it; non-supporting
  llama.cpp binaries will refuse to start, in which case rerun the
  installer after updating the bundled binary, or delete the
  `--spec-type` flag from the generated launcher (the same GGUF
  runs without MTP at lower decode speed).

LM Studio is copied to the stick but is not wired by the scripts.
