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

## Measured: Qwen3.6-27B, MLX vs llama.cpp (single faepmac1 GPU, cold)

From `scripts/bench_mlx_llamacpp.sh`. MLX uses mlx_lm 0.31.3 (one minor below
exo's pinned mlx, since 0.32.0 does not install here); llama.cpp uses UD-Q4_K_XL
with flash attention and q8_0 KV, no MTP.

| Engine | Prefill | Decode |
| --- | --- | --- |
| MLX (mlx_lm 0.31.3, 4-bit, f16 KV) | 242 tok/s | 39 tok/s |
| llama.cpp (UD-Q4_K_XL, q8_0 KV) | 300 tok/s | 24 tok/s |

For a 27B dense model on one GPU, llama.cpp prefill leads and MLX decode leads.
The production llama.cpp profile adds MTP, which roughly doubles its decode to
~42 tok/s and erases the MLX decode lead. The large MLX prefill advantage seen
elsewhere belongs to the big sparse-MoE models (GLM-5.2), not a 27B dense model
run single-node.
