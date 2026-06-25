# exo across two Mac Studios (MLX tensor-parallel)

exo (github.com/exo-explore/exo) runs one model split across both Mac Studios
with MLX. It wraps a pinned mlx-lm fork over mlx 0.32.0: mlx-lm holds the model
implementations, including GLM-5.2 (`glm_moe_dsa`), and exo adds node discovery,
sharding, the Ring or RDMA collective, and an OpenAI-compatible API. Each node
loads its shard from local disk, so the model must be present on every node,
unlike the llama.cpp RPC path where only the main node holds the GGUF.

## Backend: Ethernet now, Thunderbolt later

With no Thunderbolt-5 cable, exo uses the Ring (TCP) backend and discovers peers
over mDNS on the same subnet. Nothing selects this; it is the fallback when RDMA
is unavailable. RDMA is opt-in and needs TB5, macOS 26.2, and a Recovery-mode
`rdma_ctl enable`. It is the fast path for a later step, not this one.

## Per-node setup

Run on each Mac:

    scripts/setup_exo.sh          # brew uv/node/rust, clone exo, build dashboard
    scripts/server_start_exo.sh   # uv run exo; API on :52415

Two prerequisites the script cannot do (console access required):

- Xcode or the Metal toolchain. exo lists it. Command Line Tools alone may lack
  `xcrun metal`. Prebuilt mlx wheels often run without it, so `setup_exo.sh`
  warns rather than fails; install full Xcode if mlx then fails on a host.
- Local Network permission. In System Settings, Privacy & Security, Local
  Network, allow the terminal app, or mDNS discovery fails silently (exo #952).

## Verify and test

    curl http://127.0.0.1:52415/state                 # both nodes listed
    curl -N -X POST http://127.0.0.1:52415/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"mlx-community/Llama-3.2-1B-Instruct-4bit",
           "messages":[{"role":"user","content":"hi"}],"stream":true}'

`mlx-community/Llama-3.2-1B-Instruct-4bit` is exo's own example model (~1 GB),
the safest smoke test. Point exo at already-downloaded models with
`EXO_MODELS_READ_ONLY_DIRS` so a model is not fetched twice.

## Gotchas over plain Ethernet

- Both Macs must share one subnet. Discovery is UDP multicast (mDNS,
  224.0.0.251:5353) and does not cross routed networks. A managed switch that
  drops multicast or isolates clients breaks discovery; a direct wired link
  between the two Macs avoids it.
- Open the API port 52415 and mDNS 5353/UDP in any host firewall.
- Wi-Fi works but is slow. Use wired Ethernet between the Macs.
- A stale Thunderbolt-bridge or VPN interface can confuse discovery; remove it
  for the Ethernet test.

## Install notes

mlx is an optional extra (`exo[mlx]`); a plain `uv sync` installs only exo core,
so the backend is requested with `uv sync --extra mlx`. exo requires Python 3.13
(`requires-python == 3.13.*`).

On macOS, exo builds mlx from a git fork (`rltakashige/mlx-jaccl-fix-small-recv`,
the JACCL/RDMA fork) rather than a PyPI wheel, so the **Metal toolchain must be
installed** or the build fails compiling the Metal kernels with "cannot execute
tool 'metal' due to missing Metal Toolchain". Xcode 26 ships it as an on-demand
component. Install it once, with admin:

    sudo xcodebuild -runFirstLaunch
    sudo xcodebuild -downloadComponent MetalToolchain

`xcrun -f metal` finding the binary is not sufficient; the compiler must run.
`setup_exo.sh` step 1 tests an actual compile and prints these commands if it
fails.

Homebrew's `rustup` formula is keg-only and ships no `rustup-init`, so
`setup_exo.sh` adds `$(brew --prefix rustup)/bin` to PATH before
`rustup toolchain install nightly`.

## Measured: Qwen3.6-27B, exo MLX stack vs llama.cpp (single GPU, cold)

faepmac1, one M3 Ultra GPU. MLX is the exo stack itself (mlx 0.32.0.dev from the
JACCL fork, mlx_lm 0.31.3) on `mlx-community/Qwen3.6-27B-4bit`, f16 KV. llama.cpp
is UD-Q4_K_XL with flash attention and q8_0 KV, no MTP. Prefill (pp) and decode
(tg) in tok/s versus prompt length:

| Context | exo/MLX pp | llama.cpp pp | exo/MLX tg | llama.cpp tg |
| --- | --- | --- | --- | --- |
| ~512 | 235 | 303 | 39.8 | 23.8 |
| ~2K | 326 | 300 | 39.0 | -- |
| ~8K | 320 | 286 | 37.1 | -- |
| ~32K | 290 | 238 | 33.4 | -- |

llama.cpp decode is the near-empty tg128 figure and is roughly flat with depth;
MLX decode is measured at the real KV depth, the harder case, and still leads.

Prefill: llama.cpp leads only at the shortest prompt. From ~2K up MLX leads and
degrades less at long context, dropping ~11% from 2K to 32K against ~21% for
llama.cpp, so at 32K MLX prefill is 290 vs 238. Decode: MLX leads ~40 vs ~24
(~1.65x). The production llama.cpp profile adds MTP, which lifts its decode to
~42 and passes MLX's no-MTP 39. Run it with `scripts/bench_mlx_llamacpp.sh`
(it auto-detects the exo venv).

Earlier drafts of this table used mlx 0.31.2 and reported ~242 prefill; the exo
stack's mlx 0.32 fork prefills ~35% faster, which is why the real version matters.

## MTP (multi-token prediction) in MLX

mlx-lm does not use a model's built-in MTP/nextn head: its converter strips
those weights, so a stock quant such as `mlx-community/Qwen3.6-27B-4bit` carries
no MTP head and decode runs without self-speculation. Native MTP is an open,
stalled PR (ml-explore/mlx-lm #990, Qwen3.5/3.6, ~1.57x decode on a 27B at
temp 0). A standalone runtime, youssofal/MTPLX, ships it today (Homebrew
installable, claims up to ~2.2x on Qwen3.6-27B). mlx-lm's only built-in
speculation is a separate draft model (`--draft-model`). For MoE models like
GLM-5.2 a single MTP layer helps little either way.
