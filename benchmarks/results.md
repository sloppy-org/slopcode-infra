# Backend benchmark results

Mac Studio M3 Ultra, 256 GB, `iogpu.wired_limit_mb=253952`. Single stream,
~3.8k-token cold prompt, 256 generated tokens, 128k context configured.
TTFT is the cold-prompt value (prompt-cache miss). See `README.md` for method.

## Large models (Q4 / closest-fitting)

| Model | Format | Backend | Quant | TTFT | prefill tok/s | decode tok/s |
|-------|--------|---------|-------|-----:|--------------:|-------------:|
| DeepSeek V4-Flash | MLX | Rapid-MLX | 4bit | 10.0 s | **367** | **33.5** |
| MiniMax M3 | MLX | Rapid-MLX | mixed-3/6bit | 14.5 s | 268 | 22.4 |
| DeepSeek V4-Flash | GGUF | antirez llama.cpp | Q4KExperts | 20.3 s | 181 | 22.0 |
| MiniMax M3 | GGUF | llama.cpp (PR #24523) | UD-IQ4_XS | 18.3 s | 210 | 21.7 |
| MiniMax M3 | MLX | mlx-lm | mixed-3/6bit | 14.4 s | 267 | 10.0 |

### Crossed out: backend cannot run the model (do not use)

| Model | Backend | Why |
|-------|---------|-----|
| ~~MiniMax M3~~ | ~~vMLX~~ | bundled mlx-lm lacks `minimax_m3`; signed app cannot be patched |
| ~~MiniMax M3~~ | ~~LM Studio~~ | `Model type minimax_m3 not supported` (runtime 1.8.5) |
| ~~MiniMax M3~~ | ~~vLLM / vLLM-metal~~ | MSA sparse attention unimplemented |
| ~~DeepSeek V4-Flash~~ | ~~vMLX~~ | refuses every available build (Deviad Q4Q8 = known-bad F16 control tensors; mlx-community 4bit = param mismatch); wants its own DSV4-safe converter output |
| ~~DeepSeek V4-Flash~~ | ~~mlx-lm~~ | `deepseek_v4` unimplemented |
| ~~DeepSeek V4-Flash~~ | ~~LM Studio~~ | `deepseek_v4` unsupported (bug #1872) |
| ~~DeepSeek V4-Flash~~ | ~~vLLM / mainline llama.cpp~~ | CSA/HCA attention unimplemented |

## Verdict

- **Usable backends for these flagships: `mlx-lm`, `Rapid-MLX`, `llama.cpp` (fork
  builds).** vMLX, LM Studio, and vLLM cannot load `minimax_m3` or `deepseek_v4`
  at all; do not use them in this stack. vMLX was uninstalled after testing.
- **Rapid-MLX is the fastest** on both models (DeepSeek 33.5, M3 22.4 tok/s
  decode) but is a third-party engine and logged a tokenizer-regex warning for
  M3, so output quality needs a separate check before trusting it.
- **llama.cpp ties Rapid-MLX on M3** (21.7 vs 22.4) and is the production pick:
  mature, integrates with slopgate as a normal probing agent, no quality
  caveat. **Wired as the opencode default** (MiniMax M3 `UD-IQ4_XS`).
- **Stock mlx-lm is the slow outlier** (M3 10.0 tok/s): its MoE decode loop
  leaves ~2.2x on the table vs Rapid-MLX / llama.cpp on the same weights.
- DeepSeek V4-Flash (13B active) is faster than MiniMax M3 (23B active) on every
  shared backend; M3's dense-attention fallback also makes its prefill slower.

## Why MLX is removed from this stack

These wins are raw throughput. Two findings retire MLX serving here regardless:

- **It panics the whole machine.** mlx-lm and Rapid-MLX hold weights in wired,
  non-pageable memory. MiniMax M3 (178 GiB) sits within ~8 GiB of the 248 GiB
  wired limit, so a growing prompt cache or a second model load crosses the
  Apple Silicon AMCC threshold and kernel-panics the host, not just the process.
  It took down faepmac1 in production while it served other work. llama.cpp
  mmaps the GGUF, so the OS reclaims clean pages under pressure instead.
- **It cannot drive an agent on DeepSeek V4-Flash.** The model emits tool calls
  in its own DSML format. Neither mlx-lm nor Rapid-MLX parses it, so the server
  drops the tools array and the coding agent makes zero edits. Only vLLM and
  SGLang ship the `deepseek_v4` parser, and both need CUDA. On Apple silicon no
  backend does DeepSeek V4-Flash tool calls today.

Serve these flagships with llama.cpp, one model per host. The MLX engines,
launchd services, and weights were removed from the leader.

## Reproduction gotchas

- DeepSeek V4-Flash on the antirez llama.cpp fork needs `-fa` **off** (flash
  attention garbles its compressed attention) and `--jinja`.
- `minimax_m3` must be copied into each MLX engine's bundled `mlx_lm/models/`
  (works for mlx-lm and Rapid-MLX; impossible for the signed vMLX app).
- M3 GGUF runs on the PR #24523 llama.cpp build, not mainline.
- DeepSeek V4-Flash MLX: only `mlx-community/DeepSeek-V4-Flash-4bit` loads
  cleanly on Rapid-MLX. The `Deviad/...Q4Q8` build is broken on current engines.
