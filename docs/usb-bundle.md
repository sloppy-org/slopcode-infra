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
- Both quants of Qwen3.6-35B-A3B-Instruct MTP from
  `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`:
  - **UD-IQ4_XS** (~18 GB) — bundle default, fits 32 GB unified Macs and
    Windows-arc 32 GB iGPU caps with the MTP head loaded.
  - **UD-Q4_K_XL** (~23 GB) — opt-in via the `install-xl` variant, for
    hosts with 24 GB+ of free unified memory / VRAM headroom.
- Qwen3-Coder-30B-A3B-Instruct UD-Q4_K_XL (the FIM swap model, non-MTP).
- The Qwen mmproj and `ggml-large-v3-turbo.bin`.
- The `local-luna` tutorial, the latest llama.vscode VSIX with
  settings helpers, and current LM Studio desktop installers for
  manual fallback.

Bundle size is roughly 45 GB on disk (~18 + ~23 + ~18 + ~1 mmproj +
~1.6 whisper + binaries / opencode / docs). A 64 GB USB stick is the
sane minimum.

It does not include Pi, Node, or an npm cache.

Each per-platform directory ships:

- `install.sh` / `install.bat` — full install, IQ4_XS-MTP active.
- `install-xl.sh` / `install-xl.bat` — same install, UD-Q4_K_XL-MTP active.
- `switch-quant.sh` / `switch-quant.bat` — flip the active quant on an
  already-installed host. Reloads the service so the change is live.

Generated installers:

- bind llama.cpp to `127.0.0.1:8080`,
- bind whisper.cpp to `127.0.0.1:8427`,
- put the meeting scripts on PATH,
- configure opencode only against the local llama.cpp endpoint with
  telemetry, share, update, and model-fetch paths disabled,
- enable MTP speculative decoding (`--spec-type draft-mtp
  --spec-draft-n-max 2`) plus the Unsloth MTP sampler block
  (`--temp 1.0 --presence-penalty 1.5`) for ~1.4-2.2x decode speedup
  on hosts that support it; non-supporting llama.cpp binaries will
  refuse to start, in which case rerun the installer after updating
  the bundled binary.

LM Studio is copied to the stick but is not wired by the scripts.

## Chat vs autocomplete: swap, don't sidecar

There is no FIM autocomplete sidecar. The chat-tuned
Qwen3.6-35B-A3B-Instruct is not FIM-trained;
Qwen3-Coder-30B-A3B-Instruct is. Both fit roughly the same memory
budget (~22 GB / ~17.7 GB), so the bundle ships both and switches
which one is loaded depending on workload:

```
scripts/server_start_llamacpp.sh    # default: chat (agentic OpenCode)
scripts/server_start_qwen_coder.sh  # swap: stop chat, start FIM coder
scripts/server_stop_llamacpp.sh     # stop whichever is running
```

The bundle generates the same swap helpers in each platform install
(`llama-chat.{sh,bat}`, `llama-coder.{sh,bat}`,
`stop-llamacpp.{sh,bat}`).

Pick one at a time: opencode plus the chat panel run on the chat
model; llama.vscode autocomplete works on the coder model. The
chat-default Qwen3.6 returns HTTP 400 (or garbage completions) on
`/infill` because the model has no FIM training signal. See the
`Qwen3-Coder` README and `scripts/llamacpp_models.py` for the alias.
