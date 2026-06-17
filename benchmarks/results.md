# Backend benchmark results

Mac Studio M3 Ultra, 256 GB, `iogpu.wired_limit_mb=253952`. Single stream,
~3.8k-token cold prompt, 256 generated tokens, 128k context configured.
TTFT is the cold-prompt value (prompt-cache miss). See `README.md` for method.

## Large models (Q4 / closest-fitting)

| Model | Format | Backend | Quant | TTFT | prefill tok/s | decode tok/s |
|-------|--------|---------|-------|-----:|--------------:|-------------:|
| MiniMax M3 | MLX | mlx-lm | mixed-3/6bit | 14.4 s | 267 | 10.0 |
| MiniMax M3 | MLX | Rapid-MLX | mixed-3/6bit | 14.5 s | 268 | **22.4** |
| MiniMax M3 | GGUF | llama.cpp (PR #24523) | UD-IQ4_XS | 18.3 s | 210 | 21.7 |
| DeepSeek V4-Flash | GGUF | antirez llama.cpp | Q4KExperts | 20.3 s | 181 | 22.0 |
| DeepSeek V4-Flash | MLX | vMLX | Q4Q8 | pending | pending | pending |
| DeepSeek V4-Flash | MLX | Rapid-MLX | Q4Q8 | pending | pending | pending |

Cannot load (architecture unsupported by that backend):
- MiniMax M3 on **LM Studio**, **vLLM**, and **vMLX** (`minimax_m3` is not in their
  bundled mlx-lm and the signed app cannot be patched).
- DeepSeek V4-Flash on **stock mlx-lm**, **LM Studio**, **mainline llama.cpp**.

## Findings

- **Stock mlx-lm is the slow outlier**, not the model. MiniMax M3 decodes ~22
  tok/s on both Rapid-MLX (22.4) and llama.cpp GGUF (21.7); mlx-lm only manages
  10.0 for the same weights. mlx-lm's MoE decode loop leaves ~2.2x on the table.
- DeepSeek V4-Flash (13B active) and MiniMax M3 (23B active) land at the same
  ~22 tok/s decode on their fastest backend, despite M3 being larger; M3's
  dense-attention fallback and slower prefill (210 vs 181) are the cost.
- Prefill is comparable across MLX and GGUF (~180-270 tok/s); TTFT is dominated
  by it on a cold ~3.8k prompt (14-20 s). Prompt caching collapses a repeated
  prefix to ~1 s.

## Reproduction gotchas

- DeepSeek V4-Flash on the antirez llama.cpp fork needs `-fa` **off** (flash
  attention garbles its compressed attention) and `--jinja`.
- `minimax_m3` must be copied into each MLX engine's bundled `mlx_lm/models/`
  (works for mlx-lm and Rapid-MLX; impossible for the signed vMLX app).
- M3 GGUF runs on the PR #24523 llama.cpp build, not mainline.
