# FIM autocomplete endpoint

Inline completion (fill-in-the-middle) runs on its own low-latency endpoint,
separate from the chat/agent model. It needs a Coder model: only the
Qwen-Coder line ships the infill tokens (`<|fim_prefix|>`, `<|fim_suffix|>`,
`<|fim_middle|>`). General chat models (Qwen3.5/3.6, Gemma) carry none, so the
chat server alone cannot drive real autocomplete.

## Who serves what

- **faepmac1** (M3 Ultra, 256 GB) serves both roles at once: chat as `qwen`,
  plus a dedicated `fim` endpoint. The `fim` / `qwenfim` alias resolves to
  `qwen3-coder-next` (80B-A3B Q4, the `qwen3-coder-next-q4` spec in
  `scripts/llamacpp_models.py`). Big unified memory holds the 80B FIM model and
  the chat model together.
- **A 32 GB host** (laptop, 16 GB-class GPU box) cannot fit the 80B beside a
  chat model. Use a small dense Coder for FIM. The registry carries three
  aliases (`scripts/llamacpp_models.py`): `qwen2.5-coder-1.5b-q4`,
  `qwen2.5-coder-3b-q4`, `qwen2.5-coder-7b-q4`, all Q4_K_M Instruct GGUFs.
  Prefetch the one that fits:

  ```
  scripts/llamacpp_models.py prefetch qwen2.5-coder-3b-q4
  ```

  3B Q4_K_M (~2 GB wired) is the default beside a 35B-A3B chat model on a
  32 GB box; 7B (~5 GB) needs whisper on-demand to leave headroom; 1.5B is
  for the tightest hosts. The Instruct GGUF keeps the FIM tokens and doubles
  as a fast small chat model for opencode.

## 32 GB side-by-side

One 32 GB box (M1 Pro, macOS), three launchagents, measured 2026-05-31:

- chat/agent: `qwen3.6-35b-a3b-mtp-iq4_xs` on `:8080`, alias `qwen`, `-c 131072`,
  `--no-mmproj-offload` (mmproj on CPU), prompt cache capped at 2 GB. MTP head
  drafts via `--spec-type draft-mtp --spec-draft-n-max 2`.
- FIM: `qwen2.5-coder-3b-q4` on `:8084`, alias `qwenfim`, `-c 16384`, FIM sampler
  (temp 0.15), no reasoning flags.
- whisper: `ggml-large-v3-turbo` on `:8427`.

The 35B-A3B is hybrid-attention: KV at the full 131072 context is only 1360 MiB
(10 KV layers, q8_0), so 128K costs the same as 32K. Raise the Metal wired cap
first; the default 75% (24576 MiB) is below the resident stack:

```
sudo sysctl iogpu.wired_limit_mb=28672
```

Persist it with a boot LaunchDaemon (`com.slopcode.iogpu-wired-limit`).

Measured all-resident: wired ~30 GB of 32, free 3-4%, ~4 GB cold swap left over
from the build phase. Under a 285-token generation only 36 pages paged out, so
it does not thrash; headroom is thin, not negative. MTP draft acceptance 0.81
(158/194), decode 38-41 t/s. For more headroom, run whisper on-demand instead of
resident, or drop FIM to 1.5B.

FIM fires on every keystroke, so the small slot wants a small model. Avoid a
large dense Coder such as Codestral 22B on a laptop: every token activates all
weights, which is too slow for inline completion. Prefer a small dense Coder or
a low-active-param MoE.

## Client wiring

Point the editor at two endpoints: chat at the chat server, autocomplete at the
FIM server. Leave the autocomplete model unset so the FIM endpoint serves
whatever it loaded, or name the alias (`fim` on faepmac1).
