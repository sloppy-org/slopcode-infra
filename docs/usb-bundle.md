# USB bundle

Build a localhost-only offline bundle for colleagues:

```
scripts/build_bundle.sh all --out /mnt/usb
```

The bundle includes:

- llama.cpp (latest release): Vulkan on Linux, Metal on macOS,
  **SYCL / oneAPI on Windows** (sidesteps the active Vulkan-Arc bugs and
  gives ~2x prefill on Lunar Lake; upstream paused the win-sycl prebuilt,
  so the builder auto-pins windows-arc to the newest release that still
  ships it, see CLAUDE.md).
- opencode (latest), whisper.cpp.
- Qwen3.6-35B-A3B **UD-Q4_K_XL** from `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`
  (~22 GB), the default chat GGUF. It carries the MTP head, so the
  generated launchers run `--spec-type draft-mtp` for the 1.4-2.2x decode
  speedup; the sampler is Qwen's "thinking + precise coding" preset
  (`--temp 0.6 --top-p 0.95 --top-k 20 --presence-penalty 0`).
- Optionally `gpt-oss-20b-mxfp4.gguf` (~11.3 GB) when prefetched: a
  chat-only profile for 16 GB machines, run via the generated
  `run-gpt-oss.{bat,sh}`. See [gpt-oss-20b.md](gpt-oss-20b.md). Ship it with
  `scripts/llamacpp_models.py prefetch gpt-oss-20b` before building.
- The Qwen mmproj and `ggml-large-v3-turbo.bin`.
- The `local-luna` tutorial and two VS Code VSIX files with settings
  helpers: llama.vscode and hackl (built from `HACKL_SOURCE`).

Bundle size is roughly 26 GB on disk (~22 GGUF + ~0.9 mmproj + ~1.6
whisper + binaries / opencode / docs), plus ~11.3 GB if the optional
gpt-oss GGUF is shipped. A 64 GB USB stick is the sane minimum.

It does not include Pi, Node, or an npm cache.

Each per-platform directory ships a single `install.{sh,bat}` that runs the
full install: copies the bundled llama.cpp / opencode / whisper.cpp /
meeting scripts into the user profile, writes the launcher, registers the
service, and configures opencode against the local endpoint.

Generated installers:

- bind llama.cpp to `127.0.0.1:8080`,
- bind whisper.cpp to `127.0.0.1:8427`,
- put the meeting scripts on PATH,
- configure opencode only against the local llama.cpp endpoint with
  telemetry, share, update, and model-fetch paths disabled,
- enable MTP speculative decoding (`--spec-type draft-mtp
  --spec-draft-n-max 2`) for the ~1.4-2.2x decode speedup. A llama.cpp
  binary too old for MTP refuses to start; rerun the installer after
  updating the bundled binary, or delete the `--spec-type` flag from the
  generated launcher (the same GGUF runs without MTP at lower decode
  speed).
