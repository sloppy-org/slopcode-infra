# USB bundle

Build a localhost-only offline bundle for colleagues:

```
scripts/build_bundle.sh all --out /mnt/usb
```

The bundle includes:

- llama.cpp, opencode, whisper.cpp.
- Qwen3.6-35B-A3B-Instruct UD-Q4_K_XL (Unsloth's recommended variant;
  the chat default).
- Qwen3-Coder-30B-A3B-Instruct UD-Q4_K_XL (the FIM swap model).
- The Qwen mmproj and `ggml-large-v3-turbo.bin`.
- The `local-luna` tutorial, the latest llama.vscode VSIX with
  settings helpers, and current LM Studio desktop installers for
  manual fallback.

It does not include Pi, Node, or an npm cache.

Generated installers:

- bind llama.cpp to `127.0.0.1:8080`,
- bind whisper.cpp to `127.0.0.1:8427`,
- put the meeting scripts on PATH,
- configure opencode only against the local llama.cpp endpoint with
  telemetry, share, update, and model-fetch paths disabled.

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
