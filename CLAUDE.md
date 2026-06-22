# CLAUDE.md

Guidance for Claude Code working inside this repository. Deep rationale lives
in `docs/`; this file is the operational reference. Keep it short.

## What this repo is

One blessed local coding stack, nothing else:

- **Runtime**: `llama-server` from the latest ggml-org/llama.cpp release
  (b9180+ for MTP). `setup_llamacpp.sh` defaults to the latest tag for
  prebuilt, `master` for source builds. On Linux + NVIDIA with the CUDA
  toolkit on PATH (`nvcc`, `cmake`, `ninja`, `git`) it builds from source at
  the matching tag with `-DGGML_CUDA=ON`: upstream ships CUDA binaries for
  Windows only, and the Vulkan release stalls badly enough on NVIDIA to trip
  `ECONNRESET` mid-stream in opencode. `LLAMACPP_BACKEND=prebuilt` forces the
  Vulkan path.
- **Model**: `unsloth/Qwen3.6-35B-A3B-MTP-GGUF` at `UD-Q4_K_XL`, alias
  `qwen3.6-35b-a3b-mtp-q4`, served as `qwen`. The MTP head + draft-mtp
  speculative decoding gives 1.4-2.2x decode at ~1 GB extra VRAM. The 27B
  dense profile (`qwen3.6-27b-q4`) is a slopgate-only mode for stronger
  hardware, run via `scripts/server_start_qwen27b.sh`.
- **Harness**: `opencode` CLI, title generation off, reasoning on.
- **Optional load balancer**: `sloppy-org/slopgate` (fork of
  distantmagic/paddler v1.x). See "Multi-host" below.
- **Alternative runtime (MLX, Apple silicon)**: on a Mac dedicated to one large
  model, `mlx_lm.server` (`ml-explore/mlx-lm`) is an accepted substitute for
  `llama-server`. MLX serves MoE builds llama.cpp cannot yet run well (MiniMax
  M3, DeepSeek V4-Flash) and fronts slopgate as a static-slot peer, so the
  proxy and followers are unchanged. Set up with `setup_mlx.sh`, launch with
  `server_start_mlx.sh`, models in `mlx_models.py`. Single exclusive model per
  host, not part of the USB bundle. See "MLX runtime" below.

| OS      | Backend | Instances | Model + alias        | User service       |
| ------- | ------- | --------- | -------------------- | ------------------ |
| Linux   | CUDA    | 1         | 35B-A3B `qwen` :8080 | `systemd --user`   |
| Windows | Vulkan  | 1         | 35B-A3B `qwen` :8080 | `schtasks ONLOGON` |
| macOS   | Metal   | on demand | 35B-A3B `qwen` :8080 | none by default    |

No root or admin anywhere. The only automatic downloads are the single GGUF
and the llama-server binary. The launcher binds `0.0.0.0:8080`; with a local
slopgate balancer/agent it flips to `127.0.0.1:8081` so the proxy takes :8080.

`scripts/install_linux_systemd.sh` writes
`~/.config/systemd/user/slopcode-llamacpp.service` (ExecStart runs the
launcher with `LLAMACPP_EXEC=true`) and runs `loginctl enable-linger` for
boot autostart. The unit only references the launcher path, so re-run the
installer after any launcher change and nothing else regenerates.

## Telemetry lockdown

All install paths pin these user-level env vars (HKCU on Windows,
`~/.profile` + `environment.d` on Linux/macOS) so opencode makes no outbound
call beyond the configured LLM endpoint:

| Var                                  | Blocks                                       |
| ------------------------------------ | -------------------------------------------- |
| `OPENCODE_DISABLE_AUTOUPDATE=1`      | GitHub release / brew / choco version probes |
| `OPENCODE_DISABLE_SHARE=1`           | session upload to opencode.ai                |
| `OPENCODE_DISABLE_MODELS_FETCH=1`    | `https://models.dev/api.json`                |
| `OPENCODE_DISABLE_LSP_DOWNLOAD=1`    | clangd/texlab/zls autofetch from GitHub      |
| `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` | built-in github-copilot / llmgateway probes  |
| `OPENCODE_DISABLE_EMBEDDED_WEB_UI=1` | bundled web-ui code path                     |

`opencode.json` on every platform also sets `share: "disabled"`,
`autoupdate: false`, `tools.websearch: false`,
`experimental.openTelemetry: false`, and extends `disabled_providers` with
`opencode`, `llmgateway`, `github-copilot`, `copilot`. All idempotent. If a
future opencode release adds a new phone-home path, revisit this list
(upstream air-gapped-mode requests: ggml-org/opencode #16117 / #18492).

## Repo map

```
scripts/
  _common.sh                    shared bash helpers (paths, platform, stop_pid)
  setup_llamacpp.sh             prebuilt download, or CUDA source build on Linux+NVIDIA
  opencode_privacy.sh           pin OPENCODE_DISABLE_* env vars (idempotent)
  llamacpp_models.py            default + optional model aliases; prefetch/resolve
  server_start_llamacpp.sh      single-instance launcher; LLAMACPP_EXEC=true for systemd;
                                LLAMACPP_BIND_LOOPBACK=true forces loopback (followers)
  server_start_qwen27b.sh       27B dense special mode (slopgate / strong hardware)
  server_stop_llamacpp.sh
  serve_switch.sh               dual-GPU 35b<->27b model switch (see below)
  server_start_glm_rpc.sh       GLM-5.2 main node: serve the UD-Q4_K_S split across
                                two Macs via llama.cpp RPC (docs/glm-rpc-thunderbolt.md)
  server_start_rpc_worker.sh    rpc-server worker (faepmac2), binds the TB5 bridge only
  tb5_bridge_setup.sh           static IP on the macOS Thunderbolt Bridge (10.78.5.0/24)
  install_mac_wired_limit.sh    raise+persist iogpu.wired_limit_mb LaunchDaemon (root)
  tts_swap.sh                   stop llama-server to free GPU for ad-hoc Qwen3-TTS, then restore
  install_linux_systemd.sh      write+enable the user service; enable-linger
  install_mac_launchagents.sh   macOS launchd user agent (single 35B-A3B)
  install_slopgate_leader.sh    balancer + co-located agent (sources leader.env)
  install_slopgate_follower.sh  agent only (sources follower.env)
  install_slopgate_edge.sh      agent registering local llama-server with a separate
                                edge balancer, tagged with a privacy tier (Linux only)
  install_slopgate_watchdog.sh  watchdog: primary + weekly summary on leader (launchd),
                                reverse on chat.computor.at (systemd); posts Zulip
                                stream monitoring / topic slopgate. See docs/.
  slopgate_watchdog.sh          primary check loop (5 min); pushes heartbeat to chat via SSH
  slopgate_watchdog_reverse.sh  reverse check (10 min on chat host); pages if stale >15 min
  slopgate_watchdog_summary.sh  weekly ring-state report (Mon 06:00)
  slopgate_watchdog_lib.sh      shared Zulip / state / mail helpers
  opencode_install.sh           curl|bash (online) or OPENCODE_OFFLINE_ARCHIVE
  build_bundle.sh               USB bundle builder (see docs/usb-bundle.md)
  usb_format.sh                 exFAT USB formatter + empty bundle skeleton
  opencode_set_llamacpp.sh      write opencode.json; SLOPGATE_LEADER points at the proxy
  install_mcp_servers.sh        wire helpy/sloptools as stdio MCP into claude/codex/opencode/qwen
  setup_whisper.sh              clone + build whisper.cpp (see docs/whisper.md)
  install_linux_whisper_systemd.sh  whisper-server.service (CUDA, :8427)
  install_voxtype_linux.sh      voxtype release + systemd unit, against local whisper
  install_voxtype_mac.sh        documented manual path (upstream Linux-only)
  install_voxtype_windows.bat   documented manual path (upstream Linux-only)

config/slopcode/llamacpp-dual-gpu.conf.example   systemd drop-in for a 32 GB dual-GPU host
config/slopgate/{leader,follower,edge}.env.example  per-host slopgate templates (real env gitignored)

ci/
  run_tests.sh                  runs the suites below; all dry-run
  test_llamacpp_profile.sh      launcher dry-run + opencode config assertions
  test_slopgate_profile.sh      install_slopgate_{leader,follower} dry-run + gitignore
  test_serve_switch.sh          serve_switch.sh dry-run round-trips 35b<->27b
  test_glm_rpc_profile.sh       glm_rpc / rpc_worker / tb5_bridge / wired_limit dry-runs
  test_server_health.sh         pure-stdlib mock server
  mock_server.py
```

## Load-bearing flags

Every instance through `server_start_llamacpp.sh` always passes:

```
--cache-type-k q8_0 --cache-type-v q8_0 -b 2048 \
-ngl 99 -fa on --alias "${LLAMACPP_SERVED_ALIAS:-qwen}" --jinja \
--reasoning on --metrics --log-timestamps -fit on
```

`--metrics` exposes Prometheus counters at `/metrics` (slopgate watchdog).
`-fit on` runs llama.cpp's VRAM-fit autosizer at startup (free on sized
configs, prevents OOM on `-np > 1` or unfamiliar hosts). The launcher never
passes `--slot-save-path`; slot save/restore stays disabled even when
`LLAMACPP_SLOT_SAVE_PATH` is set.

Sampler for `qwen*` and `*-mtp-*` (Qwen's "thinking + precise coding"
preset):

```
--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
--presence-penalty 0.0 --repeat-penalty 1.0 \
--reasoning-format deepseek --reasoning-budget 4096 --no-context-shift
```

The MTP branch additionally appends `--spec-type draft-mtp
--spec-draft-n-max 2`; the sampler is identical for both branches (see
`docs/tuning.md` for the bench that retired the old MTP-specific recipe).

Offline default: single-slot 128K (`-np 1 -ub 1024 -c 131072`). Override
with `LLAMACPP_PARALLEL` / `LLAMACPP_CONTEXT`.

Prompt caching is on: the launcher always passes `--cache-reuse 256` (in-slot
prefix reuse) and passes `--cache-ram` when `LLAMACPP_CACHE_RAM` is set. The
binary default is 8192 MiB; our hosts raise it (mailuefterl 16384, faepmac1
24576 per live instance) so idle-slot KV survives slot reassignment and
repeated or shared prefixes restore instead of re-prefilling. `--cache-ram`
uses host RAM, not VRAM, so size it to system memory. macOS note: a launchd
plist edit needs `launchctl bootout` + `bootstrap` to take effect;
`kickstart -k` restarts the old in-memory definition and ignores disk changes.

### Per-platform MoE policy

Qwen3.6 35B-A3B is MoE; the expert-layer split diverges by platform. Benches
in `docs/tuning.md`.

- **Linux CUDA (single GPU)**: `--n-cpu-moe 35` (experts 0-34 on CPU, 35-39
  on GPU). `LLAMACPP_CPU_MOE=true` forces `--n-cpu-moe 99` for crowded GPUs.
- **Dual-GPU CUDA (~32 GB)**: `LLAMACPP_N_CPU_MOE=0`, GPU-only, layers split
  across both cards (pipeline-parallel; MoE has no `-sm row` path).
- **Windows-arc (Intel Arc, Vulkan)**: no `--cpu-moe`, all 40 experts on the
  iGPU; needs Shared GPU Memory Override at 32 GB. Bundle launchers set
  `GGML_VK_DISABLE_COOPMAT=1`, `GGML_VK_DISABLE_COOPMAT2=1`,
  `GGML_VK_DISABLE_F16=1`, use `-b 512` for TDR stability, and
  auto-restart on exit. A `fix-tdr.reg` ships on the USB (admin + reboot).
  See `docs/usb-bundle.md`.
- **macOS**: unified memory, no MoE split.

The `server_start_llamacpp.sh` launcher passes `--threads <physical_cores - 2>
--threads-http 4` (floor 2) to keep the host responsive; bundle installers
let llama.cpp auto-detect. Override with `LLAMACPP_THREADS` /
`LLAMACPP_THREADS_HTTP`.

## Dual-GPU model switch (serve_switch.sh)

A 32 GB-class dual-GPU host serves GPU-only and swaps profiles without
hand-editing units:

| Profile | llama alias              | slopgate alias | canonical                      |
| ------- | ------------------------ | -------------- | ------------------------------ |
| `35b`   | `qwen3.6-35b-a3b-mtp-q4` | `qwen`         | `unsloth/qwen3.6:35b-a3b@128k` |
| `27b`   | `qwen3.6-27b-mtp-q4`     | `qwen27b`      | `unsloth/qwen3.6:27b@128k`     |

Both run the UD-Q4_K_XL MTP GGUF GPU-only. 35B-A3B is the fast MoE default
(~3 B active/token); dense 27B activates all 27 B/token and decodes ~3x
slower on two mid-bandwidth cards, so it is a quality-comparison option, not
the everyday default.

```bash
scripts/serve_switch.sh        # show active profile
scripts/serve_switch.sh 35b    # serve 35B-A3B as qwen
scripts/serve_switch.sh 27b    # serve 27B dense as qwen27b
```

It edits two host-local (untracked) files and restarts both services: the
llama drop-in `slopcode-llamacpp.service.d/wg-only.conf` (seed from
`config/slopcode/llamacpp-dual-gpu.conf.example`) and
`~/.config/slopgate/follower.env` (re-stamps the model identity). WG
addresses, agent name, machine profile, and digest are untouched. It refuses
a GGUF not on disk (`SERVE_SWITCH_FORCE=true` overrides);
`SERVE_SWITCH_DRY_RUN=true` edits without restarting.

### Host: mailuefterl

The dual-GPU CUDA coding box (2x RTX 5060 Ti 16 GB, `10.77.0.10`) runs no
slopgate agent and no whisper; whisper-server lives on faepmac1. It binds
llama-server to `127.0.0.1:8080` through the `local.conf` drop-in, not
`wg-only.conf`, so `serve_switch.sh` does not apply here. It swaps models by
task with the host-local `llama-swap` helper, which copies a profile over
`local.conf` and restarts:

```bash
llama-swap        # show active profile
llama-swap 27b    # Qwen3.6-27B dense, MTP ON (default, ~42 t/s, quality)
llama-swap 35b    # Qwen3.6-35B-A3B MoE, MTP OFF (~101 t/s, throughput)
```

27B is the default profile here: the dense model is the quality choice and
its MTP draft head roughly doubles decode (22 to 42 t/s) where the 35B MoE
gains little. The active `local.conf` persists across reboots, so the box
comes up on 27B. Switch to 35B with `llama-swap 35b` when throughput beats
quality.

35B runs MTP OFF on this host: the draft head leaves GPU1 below 2 GB free and
crashes flash-attention VMM allocs even with whisper gone, so the profile uses
the alias without `-mtp-`. Profiles live in
`~/.config/slopcode/llama-profiles/{35b,27b}.conf` and the script in
`~/.local/bin/llama-swap`; all three are host-local and untracked.

## GLM-5.2 over Thunderbolt RPC (faepmac1 + faepmac2)

GLM-5.2 (754B-A40B MoE, MIT, 1M ctx) does not fit one 256 GB Mac at Q4, so the
two M3 Ultra Studios run it as one model with llama.cpp RPC: faepmac1 (main)
owns the GGUF on `/Volumes/AI`, holds half the weights in Metal, and streams the
other half to faepmac2 (`rpc-server`) over a direct Thunderbolt-5 bridge
(`10.78.5.0/24`, distinct from the WG mesh). UD-Q4_K_S (~436 GB) is the largest
Q4 that fits both the shared APFS container and the 2x248 GiB wired budget with a
single 128K q8_0 KV slot; Q4_K_M/XL overrun it. The RPC protocol is
unauthenticated, so the worker binds the point-to-point bridge address only.

Manual, on-demand profile (alias `glm-5.2`, served as `glm`); not a service, not
in the USB bundle, and mutually exclusive with the host's Qwen llama-servers
(GLM needs nearly all wired memory). The wired-limit raise
(`iogpu.wired_limit_mb=253952`) is the same LaunchDaemon the MLX host uses; it is
the one root-level part of this profile. Bring-up, sizing, and the four scripts
(`install_mac_wired_limit.sh`, `tb5_bridge_setup.sh`, `server_start_rpc_worker.sh`,
`server_start_glm_rpc.sh`) are in `docs/glm-rpc-thunderbolt.md`. The generic
launcher gained an `LLAMACPP_RPC` (`--rpc`) passthrough.

## Multi-host (slopgate)

`sloppy-org/slopgate` (private fork of `distantmagic/paddler` v1.2.1-rc1,
MIT) is a slot-aware reverse proxy fronting every node's `llama-server` on
one port.

- **Topology**: leader runs `slopgate balancer` on `0.0.0.0:8080` + a
  co-located agent; each follower runs an agent only, registering its local
  llama-server with the leader's management endpoint over WG/LAN. Offline
  followers drop out and re-register on the next heartbeat.
- **Routing**: Power-of-Two-Choices over free slots, filtered by KV-cache
  headroom. Optional sticky affinity via `x-session-affinity`.
- **Config**: per-host data in `~/.config/slopgate/{leader,follower}.env`
  (templates in `config/slopgate/`, real env gitignored). Concrete IPs and
  hostnames never enter commits, PRs, or issues.
- **Install**: `scripts/install_slopgate_leader.sh` /
  `install_slopgate_follower.sh` link `~/.local/bin/slopgate` to the cargo
  build and write systemd/launchd user units. No sudo. Leader installs pass
  `--management-dashboard-enable` (`http://<leader>:8085/`, `/api/v1/agents`).
- **opencode**: set `SLOPGATE_LEADER=<wg-ip>:8080` when running
  `opencode_set_llamacpp.sh`; baseURL becomes `http://<wg-ip>:8080/v1` with
  the affinity header.

**Model naming.** Agents advertise a family-level canonical slug plus a short
alias and any routing aliases; each peer reports its quant separately, so
peers serving the same family at the same context under different quants
share an alias without a config-mismatch badge. Full convention:
<https://github.com/sloppy-org/slopgate#model-naming-convention>.

| Canonical                        | Aliases                                         | Quants in service             |
| -------------------------------- | ----------------------------------------------- | ----------------------------- |
| `unsloth/qwen3.6:35b-a3b@128k`   | `qwen`, `35b`, `35b@128k`, `Q4`                 | `UD-Q4_K_XL-MTP`              |
| `bartowski/qwen3.6:27b@128k`     | `qwen27b`, `qwen3.6-27b`, `qwen3.6-27b@128k`    | `Q4_K_M-MTP`                  |
| `unsloth/qwen3.5:122b-a10b@128k` | `qwen122b`, `qwen3.5-122b`, `qwen3.5-122b@128k` | `UD-Q4_K_XL-MTP`              |

The `-MTP` suffix marks peers loading the multi-token-prediction variant; the
launcher branches on `*-mtp-*` only to append the draft-mtp flags. MTP is the
default on the Mac Studio leader, MTP-capable Mac followers, and the USB
bundle. Tight-VRAM followers use non-MTP `UD-Q4_K_XL` or `UD-Q4_K_S`
(no MTP head saves ~1 GB). Reserved aliases (no live peer):
`luna` (future gpt-oss-120b), `tuna` (future short-context chat pool).

**Machine profiles.** `SLOPGATE_MACHINE_PROFILE` is a stable class shared by
identical hosts (faepmac1/faepmac2 both `mac-studio-m3-ultra-256g`), letting
the balancer reuse calibration EMA seeds across them. Each box keeps its own
`machine_id`. Peers also report a `config_digest` from llama-server `/props`;
disagreeing canonical or digest under one alias lights a "config mismatch"
badge.

**Network hardening.** Every llama-server binds WG-only or loopback, never
`0.0.0.0` and never the TUG-LAN IP. The leader's local llama-server is on
`127.0.0.1:8081`; cluster traffic rides the WG mesh `10.77.0.0/24`. Rootless
followers use [`wireproxy`](https://github.com/pufferffish/wireproxy)
(userspace WG): TCP server tunnels expose llama-server on WG `:8080` and sshd
on `:22`; a client tunnel maps the leader's management endpoint to
`127.0.0.1:18085` for `SLOPGATE_LEADER_MANAGEMENT_ADDR`. Net effect: no
llama.cpp port on TUG LAN; chat content rides encrypted UDP. The balancer
(`:8080` proxy, `:8085` management/dashboard) stays open on LAN/WG/loopback
because it exposes only metadata. A leader-side UpstreamProberService opens a
short TCP connection to each agent every 5 s to keep the leader->follower ARP
warm (without it a concurrent burst against a cold-ARP follower hits Darwin's
`EHOSTUNREACH` limit and 502s). `GET /slots` is rejected at the balancer
(`--slots-endpoint-enable` not passed); each agent reads `/slots` from its
own llama-server and reports headroom via `/status_update`, so nothing
content-bearing crosses the wire.

## MLX runtime

llama.cpp on Metal cannot yet run the newest sparse-MoE flagships (MiniMax M3,
DeepSeek V4-Flash) well, so a Mac dedicated to one of them serves it through
`mlx_lm.server` instead of `llama-server`. This is a single-model host: one
large MLX model, one slot, fronted by slopgate. It replaces the multi-model
Qwen layout on that one box; every other host stays on llama.cpp.

**Why MLX, not GGUF.** These models either have no usable Metal GGUF or run far
below their MLX speed there. mlx-lm carries the `minimax_m3` / DeepSeek model
classes and runs them as native MLX. The cost is a Python venv and a model
format that only Apple silicon uses — acceptable on a host whose whole job is
this one model.

**Topology.** `mlx_lm.server` binds `127.0.0.1:8090` with prompt and decode
concurrency 1 (one active request). A slopgate agent with `--slots 1` fronts it
as a static-slot peer — the same path that fronts the OpenAI-compatible
academic-ai / duck.ai daemons (`TestEndToEnd_StaticSlotFrontsOpenAIDaemon`), so
the balancer forwards completions to `--external-llamacpp-addr` without probing
`/slots`. No slopgate code change, no balancer change, no follower change: the
MLX box is just another peer advertising its alias.

**Scripts (macOS, host-local — not in the USB bundle).**

```
scripts/
  setup_mlx.sh                    uv venv ~/.venvs/mlx-lm + mlx-lm (git main) +
                                  hf CLI; copies the minimax_m3 model class out
                                  of the model snapshot if mlx-lm lacks it.
  mlx_models.py                   MLX model registry (default minimax-m3-mixed,
                                  optional minimax-m3-4bit, deepseek-v4-flash).
                                  prefetch/resolve/inventory + agent-env/sampler
                                  for the launcher and installer.
  server_start_mlx.sh             single-slot mlx_lm.server launcher; MLX_EXEC=
                                  true execs it in the foreground for launchd.
  install_mac_mlx_launchagent.sh  writes com.slopcode.mlx (server) +
                                  com.slopcode.slopgate-agent-mlx (static-slot
                                  agent). MLX_EXCLUSIVE=true also boots out the
                                  local llama.cpp + qwen agents (the cutover).
  mlx_switch.sh                   flip the active model: minimax | deepseek.
```

**Default model: `pipenetwork/MiniMax-M3-MLX-mixed-3_6bit` (~178 GiB).** Experts
at 3-bit, attention/router/embeddings higher — the best quality-per-GiB M3
build. With a 128K KV cache (~15 GiB at one slot) and ~8-15 GiB MLX/Metal
overhead the working set lands near 200-215 GiB, inside the 248 GiB wired
limit. The plain 4-bit build (`minimax-m3-4bit`, ~240 GiB) does not leave that
headroom and is kept only as a fallback alias. `deepseek-v4-flash`
(`Deviad/DeepSeek-V4-Flash-MLX-Q4Q8`, ~173 GiB) is the switchable alternate;
exactly one model is active at a time.

**Wired-memory limit.** MLX holds weights in wired GPU memory, so the host
raises `iogpu.wired_limit_mb` to `253952` (248 GiB, leaving ~8 GiB for macOS).
That is a system-level (root) setting made permanent by the LaunchDaemon
`/Library/LaunchDaemons/com.slopcode.iogpu-wired-limit.plist`, which re-applies
it at every boot. It is separate from the user launchd agents above and is the
only part of this stack that needs root.

**KV cap caveat.** This mlx-lm has no `--max-kv-size`; the KV cache grows with
context. One slot plus the wired limit keeps a 128K session in budget, but an
unbounded session is the documented `mlx_lm.server` OOM/panic risk
(ml-explore/mlx-lm#883). The launcher caps per-request output with
`MLX_MAX_TOKENS` (default 32768); keep the agent harness context bounded.

**Operate.**

```bash
scripts/setup_mlx.sh                       # venv + mlx-lm
python3 scripts/mlx_models.py prefetch     # download the default model (~178 GiB)
scripts/server_start_mlx.sh                # foreground smoke test
scripts/install_mac_mlx_launchagent.sh     # install server + static-slot agent
MLX_EXCLUSIVE=true scripts/install_mac_mlx_launchagent.sh   # cutover off Qwen
scripts/mlx_switch.sh deepseek             # swap the active model
```

## Whisper transcription server

`whisper.cpp` runs alongside llama-server, OpenAI-compatible STT at
`http://0.0.0.0:8427/v1/audio/transcriptions` (`ggml-large-v3-turbo.bin`,
launchd `com.slopcode.whisper-server` on macOS, systemd unit on Linux).
Every launch through `server_start_whisper.sh` passes
`-l auto -fa --inference-path /v1/audio/transcriptions --convert` (auto
language; `--convert` lets ffmpeg decode m4a/mp3/mp4). GPU is on by default;
CPU-only needs `WHISPER_ALLOW_CPU=1`. Clients: voxtype, `transcribe-memo`,
slopbox. Setup and overrides in `docs/whisper.md`.

## MCP servers (stdio only)

`scripts/install_mcp_servers.sh` registers `helpy mcp-stdio` and
`sloptools mcp-server` with claude/codex/opencode/qwen-code as stdio MCP: no
port, no socket, no daemon; the agent spawns a subprocess per session under
its own UID. That is deliberate on multi-tenant boxes, where loopback TCP
would be reachable by every co-tenant. Idempotent; skips any missing CLI or
binary.

## Don't reintroduce

Never add: LM Studio, vLLM,
`security_harden.sh`, dual local/fast instances, a separate FIM sidecar on a
second port, the Qwen3-Coder swap profile (removed 2026-05-22; chat is the
only model served), the macOS Qwen 27B dense companion as a default install,
intentee/paddler v2+ (the embedded-llama.cpp rewrite; slopgate stays on the
v1.x transparent-proxy line so we keep control of llama-server flags),
llama-server bound to `0.0.0.0` on any cluster node, the balancer's
`--slots-endpoint-enable` (leaks per-slot prompt content), TCP/HTTP MCP
daemons for helpy or sloptools (stdio-only on purpose), bundled
Node/Pi/offline-npm-cache distribution (assume system `npm` plus a checkout;
see `scripts/pi_install.sh`), or anything that auto-downloads a model family
beyond the manual alias list in `scripts/llamacpp_models.py`. If one becomes
useful again, add it deliberately and update this file.

MLX-LM is no longer on this list: `mlx_lm.server` is an accepted alternative
runtime for the single-model Mac. See "MLX runtime".

## Distribution model

Repo-first for our own machines; USB bundles for colleagues via
`scripts/build_bundle.sh all --out <mountpoint>` (format with
`scripts/usb_format.sh` first). The bundle ships llama.cpp (Vulkan on Windows), opencode, whisper.cpp,
the meeting scripts, the Qwen
UD-Q4_K_XL-MTP GGUF/mmproj, `ggml-large-v3-turbo.bin`, and the VSIX pair
(llama.vscode + hackl from `HACKL_SOURCE`); optionally UD-Q4_K_S (~21.4 GB,
smaller quant) and `gpt-oss-20b-mxfp4.gguf` (chat-only for 16 GB machines)
when prefetched. Full detail, prerequisites, and the windows-arc / gpt-oss
profiles in `docs/usb-bundle.md` and `docs/gpt-oss-20b.md`.

The Windows installer is split into composable bat files (`install.bat`
calls `install-cleanup.bat`, `install-llama.bat`, `install-opencode.bat`).
Whisper (`install-whisper.bat`) is not installed by default. Linux/macOS
use a single `install.sh`. All paths bind llama.cpp to `127.0.0.1:8080`;
Windows launchers pass `--no-mmap`. Voxtype is not bundled. Meeting
transcription is PCM WAV only (no ffmpeg dependency); `meeting-process`
calls `opencode run` once after transcription. Pi is a developer-only
convenience via system `npm` (`scripts/pi_install.sh`); no bundled Node or
npm cache on any path.

## Testing

`bash ci/run_tests.sh` must be green before any commit. Tests are dry-run
only; real inference costs too much for CI.
