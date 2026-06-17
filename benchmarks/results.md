# Backend benchmark results

Mac Studio M3 Ultra, 256 GB, `iogpu.wired_limit_mb=253952`. Single stream,
~3.8k-token cold prompt, 256 generated tokens, 128k context configured.
TTFT is the cold-prompt value (prompt-cache miss). See `README.md` for method.

| Model | Format | Backend | Quant | TTFT | prefill tok/s | decode tok/s |
|-------|--------|---------|-------|-----:|--------------:|-------------:|
| MiniMax M3 | MLX | mlx-lm | mixed-3/6bit | 14.4 s | 267 | 10.0 |
| MiniMax M3 | MLX | Rapid-MLX | mixed-3/6bit | 14.5 s | 268 | **22.4** |
| MiniMax M3 | MLX | vMLX | mixed-3/6bit | pending | pending | pending |
| MiniMax M3 | GGUF | llama.cpp (PR #24523) | UD-IQ4_XS | pending | pending | pending |
| DeepSeek V4-Flash | GGUF | antirez llama.cpp | Q4KExperts | 20.3 s | 181 | 22.0 |
| DeepSeek V4-Flash | MLX | vMLX | Q4Q8 | pending | pending | pending |
| DeepSeek V4-Flash | MLX | Rapid-MLX | 4bit | pending | pending | pending |

Empty by architecture (cannot load): MiniMax M3 on LM Studio / vLLM; DeepSeek
V4-Flash on stock mlx-lm / LM Studio / mainline llama.cpp.

## Notes

- **Rapid-MLX more than doubles mlx-lm decode on the same M3 model** (22.4 vs
  10.0 tok/s; prefill identical at ~268, same MLX kernels). Its BatchedEngine
  decode loop is the difference, not speculative decoding — a non-repetitive
  generation held 24 tok/s. Caveat: Rapid-MLX logged a Mistral tokenizer-regex
  warning for M3, so output quality needs a separate check.
- `minimax_m3` is not in Rapid-MLX's bundled mlx-lm; the vendored `minimax_m3.py`
  model class was copied in (same fix as `setup_mlx.sh`).
- DeepSeek V4-Flash on the antirez fork needs flash-attention **off** (`-fa` on
  produces garbage — its compressed attention is incompatible with llama.cpp FA)
  and `--jinja` for the chat template.
- DeepSeek decodes faster than M3 (13B vs 23B active params).
