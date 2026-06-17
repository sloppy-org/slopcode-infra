# Backend benchmark results

Mac Studio M3 Ultra, 256 GB, `iogpu.wired_limit_mb=253952`. Single stream,
~3.8k-token cold prompt, 256 generated tokens, 128k context configured.
TTFT is the cold-prompt value (prompt-cache miss). See `README.md` for method.

| Model | Format | Backend | Quant | TTFT | prefill tok/s | decode tok/s |
|-------|--------|---------|-------|-----:|--------------:|-------------:|
| MiniMax M3 | MLX | mlx-lm | mixed-3/6bit | 14.4 s | 267 | 10.0 |
| MiniMax M3 | MLX | vMLX | mixed-3/6bit | pending | pending | pending |
| MiniMax M3 | MLX | Rapid-MLX | mixed-3/6bit | pending | pending | pending |
| MiniMax M3 | GGUF | llama.cpp (PR #24523) | UD-IQ4_XS | pending | pending | pending |
| DeepSeek V4-Flash | MLX | vMLX | Q4Q8 | pending | pending | pending |
| DeepSeek V4-Flash | MLX | Rapid-MLX | 4bit | pending | pending | pending |
| DeepSeek V4-Flash | GGUF | antirez llama.cpp | Q4KExperts | pending | pending | pending |

Empty by architecture (cannot load): MiniMax M3 on LM Studio / vLLM; DeepSeek
V4-Flash on stock mlx-lm / LM Studio / mainline llama.cpp.
