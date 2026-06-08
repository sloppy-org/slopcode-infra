# Tuning rationale (benches behind the launcher defaults)

The flags `server_start_llamacpp.sh` passes are summarized in CLAUDE.md.
This file keeps the measurements that justify them, so the operational
reference stays short.

## Sampler is shared by MTP and non-MTP

Both `qwen*` and `*-mtp-*` aliases use Qwen's "thinking + precise coding"
preset. The MTP branch only appends
`--spec-type draft-mtp --spec-draft-n-max 2`; the sampler block is
identical. Jakob's bench (2026-05-22, MTP UD-IQ4_XS on an RTX 5060 Ti
class GPU) gave 205 t/s decode at 0.88 draft acceptance under the
precise-coding preset. The older Unsloth "MTP needs temp 1.0 / pp 1.5"
recipe was a misattribution of the general-thinking preset; it is not
MTP-specific.

## Single-GPU Linux CUDA: `--n-cpu-moe 35`

Partial MoE offload replaces the old blanket `--cpu-moe`. Benchmark on an
RTX 5060 Ti 16 GB with Qwen3.6-35B-A3B UD-Q4_K_XL at c=262144 (the same
relative numbers held with UD-Q4_K_M earlier; the XL bench was not rerun,
but the layer-cost ratios are unchanged):

| Config                                 | llama  | Prefill | Decode | Stack peak | Free |
| -------------------------------------- | ------ | ------- | ------ | ---------- | ---- |
| `--cpu-moe -ub 512` (old baseline)     | ~5.3G  | ~300    | 33.0   | n/a        | n/a  |
| `--n-cpu-moe 30 -ub 1024`              | 11.0G  | 647     | 39.7   | TTS OOM    | n/a  |
| `--n-cpu-moe 33 -ub 1024`              | 9.65G  | 594     | 38.6   | 15.6G      | 0.2G |
| `--n-cpu-moe 35 -ub 1024` (default)    | 8.72G  | 569     | 37.0   | 14.6G      | 1.3G |
| `--n-cpu-moe 35 -ub 512`               | 7.94G  | 335     | 37.0   | 13.8G      | 2.0G |
| `--n-cpu-moe 25 -ub 1024`              | 13.3G  | 748     | 44.1   | TTS OOM    | n/a  |

"Stack peak" is llama + whisper-server (~0.9 G) + Qwen3-TTS loaded and
synthesising (~4.4 G peak). The default delivers 1.9x prefill and 1.12x
decode over the all-CPU-moe baseline while leaving ~1.3 G free for OS
pressure and other GPU callers. `--n-cpu-moe 33` gains ~4 % each way but
shrinks the free margin to 0.2 GB, one TTS spike from OOM.
`LLAMACPP_CPU_MOE=true` is the escape hatch: it forces `--n-cpu-moe 99`
(all experts on CPU) for crowded GPUs.

## Dual-GPU CUDA (~32 GB): GPU-only, 35B MoE

Drop `--n-cpu-moe` entirely (`LLAMACPP_N_CPU_MOE=0`). All 40 MoE expert
layers split across both cards by layer (pipeline-parallel; MoE has no
tensor-parallel / `-sm row` path). Qwen3.6-35B-A3B is a hybrid
attention+SSM model; its KV footprint is tiny (~1.4 GB at 128K q8_0), so
most of the 32 GB VRAM budget goes to weights and compute buffers.

Benchmarked on 2x RTX 5060 Ti 16 GB (llama-bench d403f00ec, 3 runs each,
UD-Q4_K_XL, `-fa on`, `-b 2048`, `-ngl 99`):

| ubatch | pp512    | pp4096   | decode (tg128) |
| ------ | -------- | -------- | -------------- |
|    128 | 2593 t/s | 2875 t/s | 101 t/s        |
|    256 | 2593 t/s | 3390 t/s | 101 t/s        |
|    512 | 2593 t/s | 3743 t/s | 101 t/s        |
|   1024 | 2593 t/s | 4205 t/s | 101 t/s        |

Prefill peaks at ubatch 1024 for long prompts (pp4096: 4205 vs 3743 t/s
at 512). Decode is flat across all ubatch values. Production default is
ubatch 1024 without co-resident whisper (moved to faepmac1).

### MTP on dual-GPU: VRAM instability

MTP (`--spec-type draft-mtp`) costs ~1.9 GB extra on GPU1 (the heavier
card in the pipeline-parallel split). Benchmarked on 2x RTX 5060 Ti 16 GB:

| config               | GPU0 free | GPU1 free | decode  | stable? |
| -------------------- | --------- | --------- | ------- | ------- |
| MTP on,  whisper on  | 2749 MiB  | 921 MiB   | 133 t/s | no      |
| MTP on,  whisper off | 4257 MiB  | 1433 MiB  | 133 t/s | no      |
| MTP off, whisper off | 4765 MiB  | 2159 MiB  | 101 t/s | yes     |

Crashes are `ggml_cuda_pool_vmm::alloc` failures during flash attention
CUDA graph capture. With GPU1 below ~2 GB free, the FA VMM temporary
buffers cannot allocate. MTP gives +32% decode (133 vs 101 t/s) but is
not stable on this hardware. Use the alias without `-mtp-` in the name to
skip the `--spec-type` block (see `config/slopcode/llamacpp-dual-gpu.conf.example`).

## Dual-GPU CUDA (~32 GB): 27B dense

`serve_switch.sh 27b` loads Qwen3.6-27B UD-Q4_K_XL (~17 GiB) GPU-only,
pipeline-parallel across both cards. Dense model; no `--n-cpu-moe`.

Benchmarked on 2x RTX 5060 Ti 16 GB (llama-bench d403f00ec, 3 runs each,
`-fa on`, `-b 2048`, `-ngl 99`):

| ubatch | pp512      | pp4096   | decode (tg128) |
| ------ | ---------- | -------- | -------------- |
|    128 | 1030 t/s * | 1178 t/s | 22 t/s         |
|    256 | 1149 t/s   | 1486 t/s | 22 t/s         |
|    512 |  918 t/s   | 1441 t/s | 22 t/s         |
|   1024 |  917 t/s   | 1380 t/s | 22 t/s         |

\* ubatch 128 pp512 had high variance (±188 t/s). Optimal is ubatch 256.

Flash attention makes no meaningful difference; pipeline-parallel
inter-GPU handoffs dominate. Optimal ubatch is 256.

### MTP + tensor-split on 27B

Without `--tensor-split`, the MTP draft context piles onto GPU1 (end of the
pipeline-parallel split), leaving only 1775 MiB free: same FA VMM crash
pattern as the 35B. `--tensor-split 0.55,0.45` shifts base weight pressure
to GPU0, freeing GPU1 for the draft context.

VRAM at 128K context, ubatch 256:

| config                  | GPU0 free | GPU1 free | stable? |
| ----------------------- | --------- | --------- | ------- |
| MTP on,  no ts          | 3884 MiB  | 1775 MiB  | no      |
| MTP on,  ts 0.55,0.45   | 3225 MiB  | 4349 MiB  | yes     |
| MTP on,  ts 0.60,0.40   | 1575 MiB  | 3991 MiB  | no      |
| MTP off, no ts          | 4042 MiB  | 3807 MiB  | yes     |

Throughput cost of ts 0.55,0.45: pp512 0%, pp4096 -0.3%, decode -0.3%.

Actual decode speed via API (5 requests, 300 tokens each, coding prompt):

| config       | decode    |
| ------------ | --------- |
| MTP on       | 42.4 t/s  |
| MTP off      | 21.8 t/s  |

+94% from MTP. The dense model's draft head has high acceptance; the gain
is roughly 2x versus the 32% seen on the 35B MoE. `server_start_qwen27b.sh`
defaults to MTP on + ts 0.55,0.45 + ubatch 256.

Compared to 35B no-MTP: decode 42 vs 101 t/s (2.4x slower with MTP),
pp4096 1486 vs 4205 t/s (2.8x slower). Use 27B for quality; use 35B for
throughput.

## Thread reservation on Linux / Windows

Both pass `--threads <physical_cores - 2> --threads-http 4` (floor 2). MoE
decode on Qwen3-Next is memory-bandwidth-bound, and by default llama-server
grabs every core. That starves userspace: Claude Code's HTTP/2 keepalive
and opencode's Bun HTTP pool miss their scheduling windows long enough that
the server sends idle-timeout RSTs. Reserving 2 physical cores removes the
host-side stall. Mac is untouched (Metal schedules on its own in
unified-memory mode). Override with `LLAMACPP_THREADS` /
`LLAMACPP_THREADS_HTTP`.
