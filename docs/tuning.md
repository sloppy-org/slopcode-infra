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

## Dual-GPU CUDA (~32 GB): GPU-only

Drop `--n-cpu-moe` entirely (`LLAMACPP_N_CPU_MOE=0`). All 40 expert layers
split across the two cards by layer (MoE has no tensor-parallel / `-sm row`
path in llama.cpp, so this is pipeline-parallel). Qwen3.6-35B-A3B is hybrid
(full attention every 4th layer + SSM), so its KV is tiny (~1.4 GB at
131072 q8_0) and the whole VRAM budget goes to weights. UD-Q4_K_XL MTP
(~23 GB) + KV + compute fit with room for the co-resident whisper-server.
Measured on 2x RTX 5060 Ti 16 GB: ~108 t/s decode / ~3545 t/s prefill,
~3x decode and ~6x prefill over single-GPU CPU-MoE.

## Thread reservation on Linux / Windows

Both pass `--threads <physical_cores - 2> --threads-http 4` (floor 2). MoE
decode on Qwen3-Next is memory-bandwidth-bound, and by default llama-server
grabs every core. That starves userspace: Claude Code's HTTP/2 keepalive
and opencode's Bun HTTP pool miss their scheduling windows long enough that
the server sends idle-timeout RSTs. Reserving 2 physical cores removes the
host-side stall. Mac is untouched (Metal schedules on its own in
unified-memory mode). Override with `LLAMACPP_THREADS` /
`LLAMACPP_THREADS_HTTP`.
