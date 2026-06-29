# exo across two Mac Studios (MLX tensor-parallel)

exo runs one model split across both Mac Studios with MLX. We run our fork
github.com/krystophny/exo (latest upstream main plus the GLM-5.2 pipeline fix
below), checked out at `~/code/exo` on both nodes and started by the
`com.slopcode.exo` LaunchAgent. It wraps a pinned mlx-lm fork over mlx 0.32.0:
mlx-lm holds the model implementations, including GLM-5.2 (`glm_moe_dsa`), and
exo adds node discovery, sharding, the Ring or RDMA collective, and an
OpenAI-compatible API. Each node loads its shard from local disk, so the model
must be present on every node, unlike the llama.cpp RPC path where only the main
node holds the GGUF.

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

## Adding a second node without Xcode

mlx compiles only on the primary (the node with the Metal toolchain). A second
Apple-silicon node on the same macOS major and Python 3.13 needs neither Xcode
nor a working Homebrew: copy the prebuilt mlx wheel uv cached during the
primary's build, plus the uv binary and the exo repo, then install the wheel.
From the primary:

    scripts/provision_exo_peer.sh <peer-ssh-host>

Verified faepmac1 -> faepmac2: faepmac2 ran the exact mlx 0.32 fork with no
Xcode, no Homebrew writes, and no compiling. The peer still builds the small
`exo-rs` Rust extension during `uv sync`, so it needs a Rust toolchain.

## Cluster discovery over the LAN

On one /24 subnet the two nodes discovered each other on startup over zenoh, with
no `--bootstrap-peers` and no macOS Local Network permission prompt: each ran
`exo --api-port 52415`, and both `/state` topologies showed two nodes with a
bidirectional connection and `MlxMetal` backends. The Local Network caveat above
did not bite on this LAN; keep `--bootstrap-peers <primary-ip>` as the fallback
where a switch drops multicast.

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
stack's mlx 0.32 fork prefills ~35% faster at 2K.

## MTP (multi-token prediction) in MLX

mlx-lm does not use a model's built-in MTP/nextn head: its converter strips
those weights, so a stock quant such as `mlx-community/Qwen3.6-27B-4bit` carries
no MTP head and decode runs without self-speculation. Native MTP is an open,
stalled PR (ml-explore/mlx-lm #990, Qwen3.5/3.6, ~1.57x decode on a 27B at
temp 0). A standalone runtime, youssofal/MTPLX, ships it today (Homebrew
installable, claims up to ~2.2x on Qwen3.6-27B). mlx-lm's only built-in
speculation is a separate draft model (`--draft-model`). For MoE models like
GLM-5.2 a single MTP layer helps little either way.

## GLM-5.2 (Alis 3.5bpw) across both Macs

GLM-5.2 (754B-A40B) runs as one model split across faepmac1 and faepmac2: a
Tensor / MLX-Ring instance over the Thunderbolt-3 bridge. RDMA (Jaccl) needs
TB5, so the Jaccl placements report no RDMA cycle and Ring (TCP) carries the
collective. Load it with `scripts/exo_glm_instance.sh` once exo is up on both
nodes.

The build is `avlp12/GLM-5.2-Alis-MLX-Dynamic-3.5bpw` (~306 GB, 3.5 bpw mixed:
experts 3-bit, attention/shared 4-bit, embed/head 6-bit, router bf16, DSA
indexer fp16; int8 MLA-KV for 1M context). It replaces `mlx-community/GLM-5.2-mxfp4`,
which has unoptimized Apple-Silicon mxfp4 MoE kernels (~0.27 tok/s distributed,
mlx#3402) and Metal-OOMs on long-context prefill.

Measured (mxfp4, historical, 2-node, Ring/TCP over TB3, 64 output tokens):

| prompt tokens | prefill tok/s | decode tok/s |
| --- | --- | --- |
| 153 | 104 | 16.6 |
| 563 | 181 | 16.3 |
| 2213 | 199 | 12.9 |

Decode is bound by the per-token all-reduce over TB3 TCP; TB5 + RDMA is the
lever there. Prefill reaches ~200 tok/s.

Three traps cost the most time:

- **Local Network permission.** exo's discovery is IPv6 multicast, which macOS
  gates per app behind Local Network privacy. The grant is keyed on the
  interpreter binary and persists once given, so it survives reboot and applies
  to the `com.slopcode.exo` LaunchAgent in the auto-login GUI session -- a
  Terminal left open is not required. The catch is binary identity: the venv
  must use the Homebrew python3.13 that holds the grant. A venv built against a
  uv-managed CPython (a bare `uv venv --python 3.13` may pick one) is a
  different binary with no grant, so that node only ever sees itself even under
  launchd. Build the venv with `uv venv --python /opt/homebrew/bin/python3.13`
  and verify with `readlink -f ~/code/exo/.venv/bin/python3.13`.
- **Model directory layout.** exo resolves a model under each search dir
  (`EXO_MODELS_READ_ONLY_DIRS` plus the writable dirs) as
  `<dir>/<id.normalize()>`, and `normalize()` replaces `/` with `--`. The
  read-only root is `/Volumes/AI/mlx`, but the weights sit at
  `avlp12/GLM-5.2-Alis-MLX-Dynamic-3.5bpw` (org-subdir layout), so exo looks for
  `avlp12--GLM-5.2-Alis-MLX-Dynamic-3.5bpw`, does not find it, treats the model
  as missing, and tries to download. Symlink the normalized name (under
  `~/.exo/models`) to the real directory on every node:
  `avlp12--GLM-5.2-Alis-MLX-Dynamic-3.5bpw -> /Volumes/AI/mlx/avlp12/GLM-5.2-Alis-MLX-Dynamic-3.5bpw`.
  Register the custom card first with `POST /models/add {"model_id": "..."}`, then
  place a Tensor/MlxRing instance from `GET /instance/previews` (what
  `exo_glm_instance.sh` does).
- **Shard integrity after a parallel rsync.** A multi-stream rsync can leave a
  shard with the right size but corrupt bytes; the load then dies with
  `[load_safetensors] Invalid json header length`. Verify each shard header (the
  first 8 bytes are the header length, which must satisfy `0 < n < filesize`)
  and re-copy any that fail.

The model persists across reboot and the `com.slopcode.exo` LaunchAgent brings
exo back up hands-off on both nodes (RunAtLoad, auto-login GUI session, the
Local Network grant persisted on the Homebrew python3.13). Only the GLM instance
must be recreated after boot -- POST `/place_instance` with Pipeline / MlxRing /
`min_nodes` 2; the runners reload their shard from disk. TB5 + RDMA is the route
to faster decode.

**Long context was gibberish until the DSA indexer fix.** exo pins mlx-lm to
rltakashige/mlx-lm (branch leo/deepseek-v4), whose `glm_moe_dsa.py` is a stub
that runs GLM-5.2 as plain DeepSeek-V3.2. The GLM sparse-attention indexer is
then wrong past ~2K tokens: short prompts stay clean, but long context (agentic
coding) degrades to random tokens. The fix is pcuenca's open PR
ml-explore/mlx-lm#1410 (DSA cross-layer indexer sharing), ported onto the exo
base in krystophny/mlx-lm @ glm-5.2-dsa-indexer. The fork's pyproject already
pins it, so a fresh `setup_exo.sh` needs no extra step; on an upstream checkout
apply it with `scripts/exo_repoint_mlx_lm.sh` on every node and recreate the
instance (runners re-import from disk, no exo restart or Local Network re-grant).
Generation then stays coherent at 11K context.

**The Alis build needs three more fork patches (now on glm-5.2-dsa-indexer).**
#1410 is a draft that leaves the DSA indexer RoPE interleaved (`traditional=True`)
and has acknowledged quality bugs; GLM-5.2's indexer is actually non-interleaved
with LayerNorm eps 1e-6, which the Alis author validated to ~1e-7 vs the HF
reference. (1) The indexer now reads `indexer_rope_traditional` / `indexer_norm_eps`
from config (Alis bakes `false` / `1e-6`), so output past index_topk=2048 is
correct -- verified by a 3268-token needle recall. (2) int8 MLA-KV: `CacheList`
gains `to_quantized` (quantize only the latent cache, keep the indexer cache
fp16) plus dequant-on-read, so `--kv-bits 8` engages instead of being a silent
no-op. (3) `CacheList.offset` is settable, which exo's prefill snapshot-restore
requires (`c.offset = restore_pos`) -- otherwise long prompts that hit the
trim/restore path crash the runner with `AttributeError: property 'offset' ... has
no setter`. All three are green in the fork's tests.

**Direct exo reasoning and OpenCode tool use need separate settings.** GLM-5.2
ships `temperature 1.0, top_p 0.95` (generation_config.json; Z.ai/Unsloth
concur), and direct exo calls with default thinking work. OpenCode tool loops
are more sensitive: with Alis at temperature 1.0 and `reasoning_content`
interleaved into the provider stream, GLM emitted a malformed tool call
(`<tool_call>bash<arg_key>command`) and OpenCode aborted. The prompts repo now
keeps reasoning enabled but hides `reasoning_content` from the OpenCode tool
stream and uses temperature 0.6, top_p 0.95, top_k 40, and repetition penalty
1.05 for the GLM OpenCode lane. Without that penalty, a local 2026-06-29 Alis
run repeated the same `head -1 src/ffc_test_support.f90; cat fpm.toml` command
20 times. The local 2026-06-29 direct exo smoke passed through the two-node
Tensor/MlxRing instance. Default thinking returned visible content `GLM_OK` plus
`reasoning_content` and nonzero reasoning tokens. Use
`enable_thinking:false` only for short marker smokes where reasoning cost would
hide the marker. Long Alis OpenCode tool loops still need per-task smoke tests.

**Reboot recovery (one node or both).** Three things must hold for hands-off
recovery; the first is automated, the rest are per-node prerequisites:

- *GLM instance re-placement.* exo brings the model weights back but does not
  re-place the instance. `com.slopcode.exo-glm` (LaunchAgent, RunAtLoad +
  StartInterval 120) runs `scripts/exo_glm_autoload.sh` on the leader: it waits
  for both nodes, then places a Tensor/MlxRing instance only if none exists, and
  no-ops on a healthy cluster. Install on faepmac1 with
  `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.slopcode.exo-glm.plist`.
- *exo process restart.* `~/Library/LaunchAgents/com.slopcode.exo.plist`
  (RunAtLoad + KeepAlive) auto-loads at GUI login, so exo restarts on reboot --
  but only if the node has **auto-login** enabled (the LaunchAgent loads in the
  auto-login GUI session). faepmac1 has it; **faepmac2 does not** (no
  `autoLoginUser`, no `/etc/kcpassword`), which is why the original outage
  happened -- faepmac2 rebooted, never logged in, the agent never loaded. Fix on
  faepmac2: System Settings -> Users & Groups -> "Automatically log in as: ert"
  (needs the login password; not scriptable without it). `launchctl bootstrap
  gui/$uid` cannot load the agent over SSH (no GUI audit session).
- *Local Network discovery grant.* keyed on the venv's python binary; both
  nodes now use Homebrew python 3.13.14. A brew python upgrade on either node
  changes the binary path and re-breaks discovery until Local Network is
  re-granted and both LaunchAgents are restarted. Verify with
  `readlink -f ~/code/exo/.venv/bin/python3.13`.

**Multi-node GLM-5.2 also needed an exo pipeline fix.** The DSA indexer-sharing
decoder layer returns `(hidden_states, prev_topk_indices)`, and the model
threads `prev_topk_indices` across consecutive layers. Upstream exo's
`PipelineLastLayer` (`src/exo/worker/engines/mlx/auto_parallel.py`) assumed a
bare `mx.array` and passed the tuple straight to `mx.distributed.send`, which
raised `Invalid type tuple received in array initialization` during warmup, so a
2-node placement never came up. The fork extracts the hidden state for the
send/all_gather and re-attaches the extras on return; bare-array layers are
unaffected. Committed in krystophny/exo (`80d12b4`).

Clients: pi (Pi Coding Agent, pointed at exo `:52415`) renders the reasoning
cleanly. opencode's `@ai-sdk/openai-compatible` provider does not handle
`reasoning_content` for custom endpoints (opencode #24114), so it garbles the
thinking panel and can leak tool-call text. Do not interleave `reasoning_content`
into OpenCode's tool stream; run it against exo with reasoning hidden from
OpenCode as the fallback.
