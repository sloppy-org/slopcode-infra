# FIM autocomplete endpoint

Inline completion (fill-in-the-middle) needs a model that ships the infill
tokens (`<|fim_prefix|>`, `<|fim_suffix|>`, `<|fim_middle|>`). The whole Qwen
line carries them, Qwen3.6-A3B instruct included, not just the Coder variants.
A Qwen chat model therefore drives autocomplete through `/infill` while still
answering chat through `/v1/chat/completions`. The `/infill` path skips the
chat template, so FIM never enters a reasoning phase even on a thinking model.
Plain Gemma instruct models carry no infill tokens and cannot do FIM.

So FIM can run two ways. One model serves both roles when memory is tight (the
32 GB laptop below). A separate Coder endpoint serves FIM when memory allows a
second model and you want lower latency than a large chat model gives per
keystroke.

hackl follows the same rule. Leave `hackl.autocomplete.endpoint` empty and it
reuses the main chat model for FIM when that model is FIM-capable (Qwen yes,
Gemma no); set it to point autocomplete at a dedicated Coder endpoint.

## Who serves what

- **faepmac1** (M3 Ultra, 256 GB) serves both roles at once: chat as `qwen`,
  plus a dedicated `fim` endpoint. The `fim` / `qwenfim` alias resolves to
  `qwen3-coder-next` (80B-A3B Q4, the `qwen3-coder-next-q4` spec in
  `scripts/llamacpp_models.py`). Big unified memory holds the 80B FIM model and
  the chat model together.
- **A 32 GB host** (laptop, 16 GB-class GPU box) cannot fit the 80B beside a
  chat model, and does not need a second model at all: the Qwen3.6-35B-A3B chat
  model carries the infill tokens and decodes from ~3B active params, fast
  enough for inline completion. Point autocomplete at the chat endpoint and run
  one model for both roles. The small dense Coder aliases stay in the registry
  (`scripts/llamacpp_models.py`: `qwen2.5-coder-1.5b-q4`, `qwen2.5-coder-3b-q4`,
  `qwen2.5-coder-7b-q4`, Q4_K_M Instruct GGUFs) for hosts that want a separate
  low-latency FIM slot instead:

  ```
  scripts/llamacpp_models.py prefetch qwen2.5-coder-3b-q4
  ```

## 32 GB single model

One 32 GB box (M1 Pro, macOS) runs one chat model for both roles plus whisper,
two launchagents:

- chat + FIM: `qwen3.6-35b-a3b-mtp-q4` (UD-Q4_K_XL) on `:8080`, alias `qwen`,
  `-c 131072`, `--cache-reuse 256` so FIM reuses the prompt prefix across
  keystrokes. MTP head drafts via `--spec-type draft-mtp --spec-draft-n-max 2`.
  Chat keeps reasoning; FIM hits `/infill`, which skips the chat template and
  stays non-reasoning.
- whisper: `ggml-large-v3-turbo` on `:8427`, resident for Voxtype dictation.

The 35B-A3B is hybrid-attention: KV at the full 131072 context is only 1360 MiB
(10 KV layers, q8_0), so 128K costs the same as 32K. Raise the Metal wired cap
first; the default 75% (24576 MiB) is below the resident stack:

```
sudo sysctl iogpu.wired_limit_mb=28672
```

Persist it with a boot LaunchDaemon (`com.slopcode.iogpu-wired-limit`).

Measured on llama.cpp b9444, XL + mmproj + whisper resident: llama RSS 21.8 GB,
wired ~27.7 GiB of 32, free ~4 percent, ~10 GB parked in swap. Decode 35 t/s,
MTP draft acceptance 0.82. Headroom is thin but it does not thrash. Loading
mmproj disables `--cache-reuse` (a llama.cpp restriction); the prompt cache and
context checkpoints still reuse FIM prefixes. Drop mmproj to re-enable
`--cache-reuse` and free ~1 GB if image input in chat is not needed.

One model for both drops the second resident model that pushed the earlier
3B-FIM-beside-chat layout to the wired-cap edge. FIM adds no model load: the
chat model is already resident, and `/infill` shares its KV cache.

A dedicated FIM endpoint still wants a small model, since FIM fires on every
keystroke. Avoid a large dense Coder such as Codestral 22B on a laptop: every
token activates all weights, too slow for inline completion. Prefer a small
dense Coder or a low-active-param MoE.

## Client wiring

One model for both: point chat at the chat server and leave the autocomplete
endpoint empty so hackl reuses the chat model for FIM. Separate FIM endpoint:
set the autocomplete endpoint to the FIM server and leave its model unset so it
serves whatever it loaded, or name the alias (`fim` on faepmac1).
