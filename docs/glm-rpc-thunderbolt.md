# GLM-5.2 across two Mac Studios via llama.cpp RPC over Thunderbolt 5

GLM-5.2 (zai-org, 754B-A40B MoE, MIT, 1M context) does not fit one 256 GB Mac
Studio at Q4. Two M3 Ultra 256 GB machines (faepmac1, faepmac2) run it as one
model with llama.cpp RPC: the main node reads the GGUF, keeps half the weights
in local Metal memory, and streams the other half to a worker over a direct
Thunderbolt-5 link.

This is a manual, on-demand profile, not a service. It is not in the USB
bundle. It coexists with, but cannot run at the same time as, the Qwen
llama-servers on these hosts: GLM-5.2 needs nearly all wired memory on both
nodes.

## Roles

| Node     | Role   | Bridge IP   | Process                                  |
| -------- | ------ | ----------- | ---------------------------------------- |
| faepmac1 | main   | 10.78.5.1   | `llama-server` (owns the GGUF, serves :8080) |
| faepmac2 | worker | 10.78.5.2   | `rpc-server` on :50052                    |

The GGUF lives only on faepmac1, under `/Volumes/AI/llama.cpp`. The worker
never reads the file; it receives its tensor shard over the wire and runs those
layers on its own Metal device.

`10.78.5.0/24` is a dedicated point-to-point segment, distinct from the
WireGuard mesh (`10.77.0.0/24`). The two Macs already share `/Volumes/AI` over
10 GbE and WG; the Thunderbolt bridge is a separate, faster, isolated path for
the RPC traffic only.

## Quant choice: UD-Q4_K_S

The runtime budget is 2 x 248 GiB wired (see "Wired memory limit"). The disk
budget is the shared `/Volumes/AI` APFS container (~537 GB free, shared with the
boot volume).

| Unsloth quant | Size   | Fits disk | Fits 2x248 GiB + 128K KV |
| ------------- | ------ | --------- | ------------------------ |
| UD-IQ4_XS     | 365 GB | yes       | yes (more headroom)      |
| **UD-Q4_K_S** | 436 GB | yes (~100 GB left) | yes              |
| UD-Q4_K_M     | 466 GB | tight     | no (KV overruns budget)  |
| UD-Q4_K_XL    | 467 GB | tight     | no                       |

UD-Q4_K_S is the largest true Q4_K quant that fits both budgets. An even
`0.5,0.5` split lands ~218 GB of weights plus half of one 128K q8_0 KV slot on
each node, inside the 248 GiB wired limit. Q4_K_M and larger overrun it once the
KV cache is added. The registry alias is `glm-5.2`.

Download (faepmac1, ~436 GB, several hours):

```bash
LLAMACPP_CACHE_ROOT=/Volumes/AI/llama.cpp \
  python3 scripts/llamacpp_models.py prefetch glm-5.2
```

## Wired memory limit ("VRAM fraction")

macOS caps how much unified memory the GPU/Metal may wire, far below physical
RAM. llama.cpp (and MLX) allocate model weights as wired GPU memory, so the cap
is the real ceiling on model size. A 256 GB host serving half of GLM-5.2 needs
~228 GB wired; the default cap is too low.

faepmac1 already runs the raise. Install the same on faepmac2:

```bash
scripts/install_mac_wired_limit.sh        # 253952 MiB (248 GiB), leaves ~8 GiB for macOS
sysctl iogpu.wired_limit_mb               # verify: 253952
```

The script writes `/Library/LaunchDaemons/com.slopcode.iogpu-wired-limit.plist`
(RunAtLoad), which re-applies `sysctl iogpu.wired_limit_mb=253952` at every
boot, and applies it immediately so no reboot is needed. This is the one part
of the stack that needs root. It is the same LaunchDaemon the MLX host uses
(see CLAUDE.md, "Wired-memory limit").

## Bring-up

1. Connect a Thunderbolt-5 cable directly between the two Macs. macOS creates
   the "Thunderbolt Bridge" service automatically.

2. Wired limit on both hosts (once):

   ```bash
   scripts/install_mac_wired_limit.sh       # on faepmac1 (already done) and faepmac2
   ```

3. Bridge address on each host:

   ```bash
   scripts/tb5_bridge_setup.sh main         # faepmac1 -> 10.78.5.1
   scripts/tb5_bridge_setup.sh worker       # faepmac2 -> 10.78.5.2
   ```

   The script pings the peer to confirm the link. For higher bulk throughput,
   `TB5_MTU=9000 scripts/tb5_bridge_setup.sh ...` sets a jumbo MTU on bridge0
   (non-persistent; re-run after reboot).

4. Worker on faepmac2:

   ```bash
   scripts/server_start_rpc_worker.sh       # binds 10.78.5.2:50052, tensor cache on
   ```

5. Stop the Qwen llama-servers on faepmac1 (they hold the wired memory GLM
   needs), then start the main node:

   ```bash
   scripts/server_start_glm_rpc.sh          # serves GLM-5.2 as `glm` on 127.0.0.1:8080
   ```

   The launcher refuses to start while another `llama-server` is resident
   (set `GLM_RPC_FORCE=true` to override) and fails fast if the worker is
   unreachable. First token is slow: it loads 436 GB and streams the worker's
   shard before serving.

Override the worker endpoint with `GLM_RPC_WORKER=<host:port>`, the split with
`LLAMACPP_TENSOR_SPLIT`, and the bind with `LLAMACPP_HOST` / `LLAMACPP_PORT`.

## Performance and limits

llama.cpp RPC splits layers across nodes; it does not parallelize compute.
Across many nodes the per-node TCP overhead grows and throughput drops. With
two nodes on a direct Thunderbolt-5 link the overhead is small and the point is
capacity, not speed: it runs a model that fits on neither Mac alone. Apple's
RDMA-over-Thunderbolt (macOS 26.2) is used by exo/MLX, not by llama.cpp RPC,
which rides plain TCP over the bridge.

The RPC protocol is unauthenticated. The worker binds the point-to-point bridge
address only, never `0.0.0.0` and never the LAN IP. The cable is the trust
boundary.

## Scripts

| Script                              | Node   | Purpose                                  |
| ----------------------------------- | ------ | ---------------------------------------- |
| `install_mac_wired_limit.sh`        | both   | raise + persist `iogpu.wired_limit_mb`   |
| `tb5_bridge_setup.sh`               | both   | static IP on the Thunderbolt Bridge      |
| `server_start_rpc_worker.sh`        | worker | run `rpc-server` bound to the bridge     |
| `server_start_glm_rpc.sh`           | main   | serve GLM-5.2 split over RPC             |
| `llamacpp_models.py` (`glm-5.2`)    | main   | resolve/prefetch the UD-Q4_K_S GGUF      |

`server_start_glm_rpc.sh` is a thin profile over `server_start_llamacpp.sh`,
which gained an `LLAMACPP_RPC` passthrough (`--rpc`). All four scripts have
dry-run modes exercised by `ci/test_glm_rpc_profile.sh`.
