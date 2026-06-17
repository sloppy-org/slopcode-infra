# Backend benchmarks (exclusive-big-model Mac)

Single-stream speed of one large model across MLX and GGUF runtimes on the
faepmac1-class Mac Studio (M3 Ultra, 256 GB, `iogpu.wired_limit_mb=253952`).
The question these answer: for one big coding model at 128k context, which
backend is fastest, and is MLX or GGUF the better path per model.

## Harness

`bench.py BASE_URL MODEL [WORDS] [MAX_TOKENS] [LABEL]` drives any
OpenAI-compatible `/v1/chat/completions` endpoint. It runs one warmup (to warm
MLX kernel compilation for the prompt-length bucket), then a measured run with a
**different** prompt of the same length so the prompt cache misses and prefill
is real. Token counts come from the streamed `usage` block.

Metrics, all single stream:
- **TTFT**: wall time to the first generated token on a cold (uncached) prompt.
  With prompt caching a repeated prefix drops this to ~1 s. The table reports the
  cold number, which is what a fresh agent turn pays.
- **prefill tok/s**: `prompt_tokens / TTFT`.
- **decode tok/s**: generated tokens per second after the first.

Each row uses a ~3.8k-token prompt and 256 generated tokens. Servers are
configured for 128k context (`--ctx-size 131072` / `--max-kv-size` where the
backend supports it); the prompt is kept moderate so prefill stays measurable
(a full 128k prefill at ~250 tok/s is ~9 minutes and is not run per cell).

## Architecture support (why some cells are empty)

The newest flagships ship novel attention, so a build only runs where its
architecture is implemented.

| Model | mlx-lm | vMLX | Rapid-MLX | LM Studio | llama.cpp |
|-------|--------|------|-----------|-----------|-----------|
| MiniMax M3 (`minimax_m3`, MSA) | yes (vendored class) | test | test | no | PR #24523 fork |
| DeepSeek V4-Flash (`deepseek_v4`, CSA/HCA) | no | yes | yes | no | antirez fork only |

LM Studio's shipped mlx runtime rejects both (`Model type ... not supported`);
mainline llama.cpp and vLLM/vLLM-metal do not implement either attention yet.

## Quant policy

Q4 or the closest-fitting equivalent that leaves room for 128k KV:
- MiniMax M3 MLX: `pipenetwork/MiniMax-M3-MLX-mixed-3_6bit` (~178 GiB; the 4-bit
  build is ~240 GiB and does not fit with 128k KV).
- MiniMax M3 GGUF: `unsloth/MiniMax-M3-GGUF:UD-IQ4_XS` (~208 GiB).
- DeepSeek V4-Flash MLX: `Deviad/DeepSeek-V4-Flash-MLX-Q4Q8` (~173 GiB).
- DeepSeek V4-Flash GGUF: `antirez/deepseek-v4-gguf` Q4KExperts chat-v2 (~153 GiB).

## Results

`results.tsv` is appended by each run. See `results.md` for the rendered table.

## Reproduce

```bash
python3 benchmarks/bench.py http://127.0.0.1:8090 \
  pipenetwork/MiniMax-M3-MLX-mixed-3_6bit 3000 256 "M3 / MLX / mlx-lm"
```
