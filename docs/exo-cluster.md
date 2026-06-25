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
