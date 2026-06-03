# gpt-oss-20b: optional chat-only profile for 16 GB machines

The blessed default is Qwen3.6-35B-A3B UD-Q4_K_XL (~22 GB), which needs a
32 GB GPU budget. A 16 GB-class machine cannot hold it. `gpt-oss-20b` is the
optional fallback for that tier.

gpt-oss-20b is OpenAI's open Mixture-of-Experts model: 20.9B total, ~3.6B
active per token, shipped natively in MXFP4 (~11.3 GB). Like the 35B-A3B it
decodes from a small active set, so it is much faster than a dense 8/9B that
fires all its parameters: ~26 t/s on a 16 GB Mac at 32K context, ~53-64 t/s
on a 16 GB GPU. A dense Qwen 8/9B on the same class of machine runs ~17-18
t/s. It is chat-only.

## What it is not

- **No FIM.** gpt-oss has no infill tokens, so it cannot serve inline
  completion. On a gpt-oss box, point `hackl.autocomplete.endpoint` at a
  separate Coder endpoint or leave autocomplete off. See
  [fim-autocomplete.md](fim-autocomplete.md).
- **No MTP head**, so no `--spec-type draft-mtp`.
- **No vision**, so no mmproj.

## Flags

Per the llama.cpp gpt-oss guide (discussion #15396):

```
--jinja --temp 1.0 --top-p 1.0 --top-k 40 --min-p 0 \
--presence-penalty 0.0 --repeat-penalty 1.0 \
--reasoning-format none --no-context-shift
```

- Reasoning rides the harmony "analysis" channel, so `--reasoning-format
  none`, not `deepseek`, and no token budget.
- Do not add repetition penalties; `--repeat-penalty 1.0` is neutral.
- `--top-k 40` is kept on purpose: the guide warns that disabling top-k adds
  CPU overhead and a small chance of sampling low-probability tokens.

The served alias stays `qwen`, so opencode and hackl need no reconfiguration.

## No experts on CPU

gpt-oss-20b is served GPU-only: the launcher emits no `--n-cpu-moe`. The
alias does not match the `*a3b*` partial-MoE rule in
`server_start_llamacpp.sh`, so the default is already zero CPU offload.

Full 128K context fits 16 GB GPU-only. gpt-oss uses sliding-window attention
on half its layers, so only the full-attention layers keep full-length KV:
the 128K cache is ~1.7 GB at q8_0, not the multi-GB a dense-attention model
would need. So `-c 131072` (the launchers' default, equivalent to the
guide's `--ctx-size 0`) sits comfortably beside the ~11.3 GB weights.

## Run it

Repo host:

```bash
python3 scripts/llamacpp_models.py prefetch gpt-oss-20b
LLAMACPP_MODEL_ALIAS=gpt-oss-20b scripts/server_start_llamacpp.sh
```

USB bundle: prefetch the alias before `build_bundle.sh`, and the GGUF rides
along (soft-fail otherwise). Each installer writes `run-gpt-oss.{bat,sh}`
next to `run-llamacpp.{bat,sh}`; run it instead of the default launcher. It
binds the same `127.0.0.1:8080` and serves alias `qwen`.
