# CLAUDE.md

Guidance for Claude Code working inside this repository.

## What this repo is

One blessed local coding stack, nothing else:

- **Runtime**: `llama-server` from the latest upstream ggml-org/llama.cpp release.
- **Model**: `unsloth/Qwen3.6-35B-A3B-GGUF` at `UD-Q4_K_M` — alias
  `qwen3.6-35b-a3b-q4`. The same model on every platform.
- **Harness**: `opencode` CLI, title generation disabled, reasoning on.
- **Optional load balancer**: `sloppy-org/slopgate` (fork of distantmagic/
  paddler v1.x) for multi-host deployments. See "Multi-host (slopgate)" below.

The launcher binds `0.0.0.0:8080` by default. When a slopgate balancer or
agent unit is locally installed, the launcher flips to `127.0.0.1:8081` so the
proxy can take `:8080`.

| OS      | Backend | Instances | Model + alias              | User service        |
| ------- | ------- | --------- | -------------------------- | ------------------- |
| Linux   | CUDA    | 1         | 35B-A3B `qwen` :8080       | `systemd --user`    |
| Windows | Vulkan  | 1         | 35B-A3B `qwen` :8080       | `schtasks ONLOGON`  |
| macOS   | Metal   | 1         | 35B-A3B `qwen` :8080       | launchd user agent  |

No root or admin is required anywhere. The only automatic downloads are the
single GGUF and the llama-server binary.

The Linux service is installed by `scripts/install_linux_systemd.sh`: it writes
`~/.config/systemd/user/slopcode-llamacpp.service`, whose ExecStart invokes
`server_start_llamacpp.sh` with `LLAMACPP_EXEC=true` so llama-server runs in
the foreground under systemd. The installer runs `loginctl enable-linger`
(no sudo in the common case) so the service survives logout and starts at
boot. Re-run the installer any time the launcher changes — the unit only
references the launcher path, so nothing else has to be regenerated.

On Linux with an NVIDIA GPU and the CUDA toolkit present (`nvcc`, `cmake`,
`ninja`, `git` on PATH), `setup_llamacpp.sh` builds llama.cpp from source at
the matching release tag with `-DGGML_CUDA=ON` instead of downloading the
Vulkan release. Rationale: upstream ggml-org only ships CUDA binaries for
Windows, and the portable Vulkan release underperforms on NVIDIA hardware
badly enough that the inter-token stalls trigger `ECONNRESET` in the opencode
client mid-stream. Set `LLAMACPP_BACKEND=prebuilt` to force the Vulkan path
on a box that has the toolkit but shouldn't build from source.

## Telemetry lockdown

All three install paths pin the following user-level environment variables
(HKCU on Windows, `~/.profile` + `environment.d` on Linux/macOS) so opencode
makes no outbound call beyond the configured LLM endpoint:

| Var                                | Blocks                                    |
| ---------------------------------- | ----------------------------------------- |
| `OPENCODE_DISABLE_AUTOUPDATE=1`    | GitHub release / brew / choco version probes |
| `OPENCODE_DISABLE_SHARE=1`         | session upload to opencode.ai              |
| `OPENCODE_DISABLE_MODELS_FETCH=1`  | `https://models.dev/api.json`              |
| `OPENCODE_DISABLE_LSP_DOWNLOAD=1`  | clangd/texlab/zls autofetch from GitHub    |
| `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` | built-in github-copilot / llmgateway probes |
| `OPENCODE_DISABLE_EMBEDDED_WEB_UI=1` | bundled web-ui code path                  |

`opencode.json` on every platform also sets `share: "disabled"`,
`autoupdate: false`, `tools.websearch: false`, `experimental.openTelemetry: false`,
and extends `disabled_providers` with `opencode`, `llmgateway`, `github-copilot`,
`copilot` alongside the already-excluded cloud providers.

All of this is idempotent: re-running the install/config scripts rewrites
in place. No admin or sudo required. Upstream still has open feature requests
for a first-class air-gapped mode (ggml-org/opencode issues #16117 / #18492),
so if a future release introduces a new phone-home path this list has to be
revisited.

## Repo map

```
scripts/
  _common.sh                    shared bash helpers (paths, platform detect, stop_pid)
  setup_llamacpp.sh             prebuilt download (default), or CUDA source build on Linux+NVIDIA
  opencode_privacy.sh           pin OPENCODE_DISABLE_* env vars in ~/.profile + environment.d (idempotent)
  llamacpp_models.py            default + optional model aliases; prefetch/resolve
  server_start_llamacpp.sh      single-instance launcher; LLAMACPP_EXEC=true
                                replaces the shell with llama-server for systemd.
                                Flips to 127.0.0.1:8081 when slopgate is locally
                                installed; LLAMACPP_BIND_LOOPBACK=true forces it
                                without slopgate detection (followers).
  server_stop_llamacpp.sh
  install_linux_systemd.sh      write & enable ~/.config/systemd/user/slopcode-
                                llamacpp.service; enable-linger for boot autostart
  install_mac_launchagents.sh   macOS launchd user agent (single 35B-A3B instance)
  install_slopgate_leader.sh    install slopgate balancer + co-located agent
                                (sources ~/.config/slopgate/leader.env)
  install_slopgate_follower.sh  install slopgate agent only (sources
                                ~/.config/slopgate/follower.env)
  opencode_install.sh           curl|bash (online) or OPENCODE_OFFLINE_ARCHIVE
  build_bundle.sh               USB bundle builder for linux-cuda, mac-m1,
                                windows-arc. Includes llama.cpp, opencode,
                                whisper.cpp, Qwen GGUF/mmproj, and
                                ggml-large-v3-turbo. No Pi/Node/npm cache.
  usb_format.sh                 exFAT USB formatter + empty bundle skeleton.
  opencode_set_llamacpp.sh      write ~/.config/opencode/opencode.json. SLOPGATE_LEADER
                                points baseURL at the proxy + emits
                                x-session-affinity header for sticky routing.
  install_mcp_servers.sh        wire `helpy mcp-stdio` and `sloptools mcp-server`
                                into claude/codex/opencode/qwen as stdio MCP
                                servers. Pure stdio: no listening port, no
                                socket, no daemon. Subprocess per session.
  setup_whisper.sh              clone + build whisper.cpp from source. Defaults
                                to ~/code/whisper.cpp when ~/code exists, else
                                ~/.local/whisper.cpp. CUDA/Vulkan/Metal
                                auto-detected.
  install_linux_whisper_systemd.sh  ~/.config/systemd/user/whisper-server.service
                                that execs server_start_whisper.sh (CUDA
                                build, OpenAI-compatible /v1/audio/
                                transcriptions on :8427).
  install_voxtype_linux.sh      install upstream voxtype release artefacts
                                + ~/.config/systemd/user/voxtype.service,
                                pointed at the local whisper-server.
  install_voxtype_mac.sh        documented manual path (upstream is
                                Linux-only).
  install_voxtype_windows.ps1   documented manual path (upstream is
                                Linux-only).

config/slopgate/
  leader.env.example            template for ~/.config/slopgate/leader.env
  follower.env.example          template for ~/.config/slopgate/follower.env

ci/
  run_tests.sh                  runs the three suites below
  test_llamacpp_profile.sh      launcher dry-run + opencode config assertions
  test_slopgate_profile.sh      install_slopgate_{leader,follower} dry-run +
                                gitignore behaviour
  test_server_health.sh         pure-stdlib mock server
  mock_server.py
```

## Flags that are load-bearing

Every instance launched through `server_start_llamacpp.sh` always passes:

```
--cache-type-k q8_0 --cache-type-v q8_0 -b 2048 \
-ngl 99 -fa on --alias "${LLAMACPP_SERVED_ALIAS:-qwen}" --jinja \
--reasoning on
```

`-np`, `-ub`, and MoE placement are caller/platform-dependent. Linux/Windows
default to `-np 1 -ub 1024 --n-cpu-moe 35 -c 262144` (partial MoE offload,
5/40 routed-expert layers on GPU, small compute buffer to coexist with
whisper-server and Qwen3-TTS). Mac defaults to `-np 8 -ub 1024 -c 2097152`
(eight slots × 256K each, no MoE split — Metal handles experts in unified
memory). The 27B dense companion that previously occupied the Mac's second
port is gone; the freed unified-memory budget pays for the eight-slot config.
Per-slot context lands at the model's native `n_ctx_train` (262144) on every
platform, so no YaRN scaling is involved.

Why eight slots on the Mac and not four: Qwen3.6-35B-A3B is a hybrid
architecture (10/40 layers carry full-attention KV, the other 30 are Gated
DeltaNet linear-attention with a constant ~250 MiB recurrent state). At
q8_0 KV that puts each 256K slot at ~2.5 GiB of cache. Eight slots
fit comfortably (~20 GiB KV + 22 GiB UD-Q4_K_M weights + 2 GiB mmproj +
~3 GiB compute = ~46 GiB out of 256 GiB unified memory, leaving ~180 GiB
for whisper / Qwen3-TTS / other apps). The bandwidth-saturated decode
ceiling on M3 Ultra is around 8 concurrent streams; per-slot decode
falls from ~77 t/s (single user, measured) to ~55-65 t/s only when 5+
slots are actually busy at the same time. Slopgate is the v1.2.1
transparent-proxy line — it does not overbook; admission is strict
1-request-per-physical-slot, KV-headroom-filtered.

On Linux/Windows partial MoE offload replaces the old blanket `--cpu-moe`.
Benchmark on RTX 5060 Ti 16 GB with Qwen3.6-35B-A3B UD-Q4_K_M at c=262144:

| Config                                 | llama  | Prefill | Decode | Stack peak | Free |
| -------------------------------------- | ------ | ------- | ------ | ---------- | ---- |
| `--cpu-moe -ub 512` (old baseline)     | ~5.3G  | ~300    | 33.0   | n/a        | n/a  |
| `--n-cpu-moe 30 -ub 1024`              | 11.0G  | 647     | 39.7   | TTS OOM    | —    |
| `--n-cpu-moe 33 -ub 1024`              | 9.65G  | 594     | 38.6   | 15.6G      | 0.2G |
| `--n-cpu-moe 35 -ub 1024` (default)    | 8.72G  | 569     | 37.0   | 14.6G      | 1.3G |
| `--n-cpu-moe 35 -ub 512`               | 7.94G  | 335     | 37.0   | 13.8G      | 2.0G |
| `--n-cpu-moe 25 -ub 1024`              | 13.3G  | 748     | 44.1   | TTS OOM    | —    |

"Stack peak" is llama + whisper-server (~0.9 G) + Qwen3-TTS loaded and
synthesising (~4.4 G peak). The chosen default delivers 1.9x prefill and
1.12x decode vs the old all-CPU-moe baseline while leaving ~1.3 G free
for OS pressure and further GPU callers. Raising to `--n-cpu-moe 33`
gains ~4 % prefill and decode but shrinks the free margin to 0.2 GB —
one TTS spike away from OOM. `LLAMACPP_CPU_MOE=true` remains as an
emergency escape hatch that forces `--n-cpu-moe 99` (all experts on
CPU) for even more crowded GPUs.

Linux and Windows also pass `--threads <physical_cores - 2> --threads-http 4`
(clamped to a minimum of 2). Rationale: MoE decode on Qwen3-Next is
memory-bandwidth-bound and by default llama-server grabs every core. That
starves the rest of userspace — Claude Code's HTTP/2 keepalive and opencode's
Bun HTTP pool both miss their scheduling windows long enough for the server
side to send idle-timeout RSTs. Reserving 2 physical cores for the host
eliminates the host-side stall. Mac is untouched (Metal schedules on its
own, user sees no stalls in unified-memory mode); defaults can be overridden
per invocation via `LLAMACPP_THREADS` / `LLAMACPP_THREADS_HTTP`.

Default deployment per platform:

| Host            | Instances        | `--alias` | `-np` | `-c`     | Per-slot ctx |
| --------------- | ---------------- | --------- | ----- | -------- | ------------ |
| Linux / Windows | 35B-A3B on :8080 | `qwen`    | 1     | 262144   | 262144       |
| macOS           | 35B-A3B on :8080 | `qwen`    | 8     | 2097152  | 262144       |

Every slot on every platform gets 256K — exactly the model's native
`n_ctx_train`. Linux/Windows run one slot because a single local user rarely
needs two concurrent decode streams and halving the window made opencode
auto-compaction fire at ~79K conversation tokens instead of ~210K. With
`-np 1` compaction still blocks the only slot for the duration of the summary
call, but the user gets ~2.6× more working context before that happens and
the session always recovers. macOS runs eight slots because the M3 Ultra has
unified memory to spare and Qwen3-Next's hybrid attention puts the per-slot
KV at only ~2.5 GiB at 256K (q8) — combined opencode + student traffic
through the slopgate proxy benefits from concurrent decode streams.

Override per invocation with `LLAMACPP_PARALLEL` and `LLAMACPP_CONTEXT`.

## Multi-host (slopgate)

For deployments spanning more than one box, `sloppy-org/slopgate` (a private
fork of `distantmagic/paddler` v1.2.1-rc1, MIT-licensed) is a slot-aware
reverse proxy that fronts every node's `llama-server` on a single port.

**Topology.** A leader runs `slopgate balancer` on `0.0.0.0:8080` and a
co-located `slopgate agent`. Each follower runs `slopgate agent` only,
registering its local `llama-server` with the leader's management endpoint
over a private network (WireGuard or LAN). When followers go offline they
drop out of rotation; when they come back they re-register on the next
heartbeat.

**Routing.** Power-of-Two-Choices over the free-slot count, filtered by
KV-cache headroom so a long-context request never lands on a slot that can't
fit it. Optional sticky session affinity via the `x-session-affinity` header;
slopgate also accepts the legacy `X-Slopgate-Session` name and opencode's
native `x-opencode-session` header.

**Configuration.** Per-host capability data and topology live in env files
outside the repo:
- `~/.config/slopgate/leader.env` — leader balancer + local agent
- `~/.config/slopgate/follower.env` — follower agent

Templates at `config/slopgate/{leader,follower}.env.example`. Real env files
are gitignored. Concrete IPs and hostnames never leak into commits, PR
descriptions, or issue bodies.

**Install.** From the leader: `bash scripts/install_slopgate_leader.sh`.
From each follower: `bash scripts/install_slopgate_follower.sh`. Both
scripts link `~/.local/bin/slopgate` to the cargo build at
`~/code/sloppy/slopgate/target/release/slopgate` and write systemd user
units (Linux) or launchd user agents (macOS). No sudo.

**opencode integration.** Set `SLOPGATE_LEADER=<wg-ip>:8080` (or just
`<wg-ip>`) when running `scripts/opencode_set_llamacpp.sh`; baseURL becomes
`http://<wg-ip>:8080/v1` and a stable `x-session-affinity` header is added
for sticky multi-turn routing.

**ARP / neighbour warmup.** The balancer runs an UpstreamProberService that
opens a short-lived TCP connection to each agent's `external_llamacpp_addr`
every 5 s. The leader receives heartbeats from followers (which keep ARP
warm in the follower→leader direction), but never sends packets back until
a real request arrives — so without the prober, a burst of concurrent
requests against a cold-ARP follower hits Darwin's `EHOSTUNREACH` rate
limit and returns 502s. The prober keeps the leader→follower path warm
without affecting routing decisions.

**Network hardening.** Every `llama-server` in the cluster binds to a
WireGuard address only — never `0.0.0.0`, never the host's TUG-LAN IP. The
leader's local llama-server listens on `127.0.0.1:8081`; cluster
communication happens over the WG mesh `10.77.0.0/24`. Followers without
root (Linux + admin-shared Mac) use [`wireproxy`](https://github.com/pufferffish/wireproxy)
as an unprivileged userspace WG client: the static Go binary lives in
`~/.local/bin/wireproxy`, config in `~/.config/wireproxy/slopgate.conf`,
service via systemd-user (Linux) or `~/Library/LaunchAgents/io.slopcode.
wireproxy.plist` (macOS). wireproxy's `[TCPServerTunnel]` blocks expose two
local ports on the WG IP: port `8080` forwards to the local llama-server,
and port `22` forwards to the host's sshd so other peers can reach it as
`ssh <wg-addr>` directly over the mesh — no TUG VPN required for any
intra-cluster ssh. wireproxy's `[TCPClientTunnel]` exposes the leader's
management endpoint as `127.0.0.1:18085`, which the slopgate-agent's
`SLOPGATE_LEADER_MANAGEMENT_ADDR` points at. Net effect: no llama.cpp port
on TUG LAN at all; chat content rides ChaCha20-Poly1305-encrypted UDP
between every node. The slopgate balancer (`:8080` proxy, `:8085`
management and dashboard) deliberately stays open on LAN/WG/loopback because
it exposes only metadata (agent counts, slot counts, addresses) — no request
bodies, no prompts, no chat history. Leader installs always pass
`--management-dashboard-enable`, so `http://<leader>:8085/` serves the
dashboard and `/api/v1/agents` serves the same status data as JSON.

**Web UI off.** Every llama-server invocation includes `--no-webui` to
disable the bundled chat UI. The web UI persists conversation history in
the browser's localStorage and could leak prior sessions if anyone reaches
it. The pure-API path (`/v1/chat/completions`, `/v1/audio/transcriptions`)
is untouched.

**Slots endpoint.** Slopgate's balancer rejects `GET /slots` (the
`--slots-endpoint-enable` flag is *not* passed in `install_slopgate_
leader.sh`). The KV-headroom routing filter keeps working because each
node's local slopgate-agent reads `/slots` from its own loopback/WG-bound
llama-server and reports headroom up via `/status_update` — nothing
content-bearing crosses the wire.

## Whisper transcription server

`whisper.cpp` runs alongside llama-server on the same box, exposing an
OpenAI-compatible STT endpoint at `http://0.0.0.0:8427/v1/audio/transcriptions`.

| Host  | Backend | Model                       | Port | Path                              | Daemon                      |
| ----- | ------- | --------------------------- | ---- | --------------------------------- | --------------------------- |
| macOS | Metal   | `ggml-large-v3-turbo.bin`   | 8427 | `/v1/audio/transcriptions`        | `com.slopcode.whisper-server` |
| Linux | CUDA    | `ggml-large-v3-turbo.bin`   | 8427 | `/v1/audio/transcriptions`        | (systemd unit, future)      |

Every instance launched through `server_start_whisper.sh` always passes:

```
-l auto -fa --inference-path /v1/audio/transcriptions --convert
```

`-l auto` means whisper auto-detects the spoken language (the default `en`
silently produces nonsense on German voice memos). `-fa` enables flash
attention (default-on; explicit so it survives upstream changes). `--convert`
lets clients upload arbitrary container formats (m4a, mp3, mp4) and the server
reaches for ffmpeg to decode — required because iOS Voice Memos are AAC-in-m4a.
GPU usage is on by default; the binary is built with `-DGGML_METAL=1` on Mac,
`-DGGML_CUDA=1` on Linux/NVIDIA, `-DGGML_VULKAN=1` on other GPUs. CPU-only
falls through `setup_whisper.sh`'s safety check unless `WHISPER_ALLOW_CPU=1`
is set.

Clients in this stack:
- `voxtype` macOS push-to-talk (`feature/macos-release`) with
  `--remote-endpoint http://127.0.0.1:8427`
- `~/Nextcloud/plasma/DOCUMENTS/MEETINGS/tools/transcribe-memo`
- `slopbox` voice-memo classifier (uses the first ~60s of audio for the
  is-meeting decision, then hands off to `process-memo` for the full transcribe)

Override with `WHISPER_HOME`, `WHISPER_PORT`, `WHISPER_LANGUAGE`,
`WHISPER_THREADS`, `WHISPER_MODEL`. Foreground-mode for launchd ExecStart with
`WHISPER_EXEC=true` (mirrors `LLAMACPP_EXEC=true`).

## MCP servers (stdio only)

`scripts/install_mcp_servers.sh` registers the local sloppy-org MCP servers
(`helpy mcp-stdio`, `sloptools mcp-server`) with claude, codex, opencode,
and qwen-code. Pure stdio: there is no listening port, no unix socket, and
no daemon — the agent spawns the MCP binary as a subprocess per session.
On a multi-tenant box (university workstations etc.) loopback TCP would be
reachable by every co-tenant; stdio sidesteps that entirely because the
subprocess inherits the agent's UID and only that UID's pipes carry the
JSON-RPC stream.

Run after the binaries are on PATH:

```bash
scripts/install_mcp_servers.sh
```

Idempotent. Skips any agent CLI that isn't installed and any MCP binary
that isn't on PATH.

## Don't reintroduce

Explicitly out of scope — do not add LM Studio, vLLM, vLLM-MLX, MLX-LM, oMLX,
`security_harden.sh`, dual-instance local/fast servers, the macOS Qwen 27B
dense companion as a default-installed model, intentee/paddler v2+ (the
embedded-llama.cpp rewrite — slopgate stays on the v1.x transparent-proxy
line so we keep control of llama-server flags), llama-server bound to
`0.0.0.0` on any cluster node (it must always bind WG-only or loopback),
the bundled llama.cpp web UI on a network-reachable interface (always
launch with `--no-webui`), the slopgate balancer's `--slots-endpoint-
enable` flag (it leaks per-slot prompt content), TCP/HTTP MCP daemons for
helpy or sloptools (they're stdio-only on purpose so no co-tenant can
reach them), bundled Node/Pi/offline-npm-cache distribution (assume system
`npm` and a checkout of this repo on every target — see
`scripts/pi_install.sh`), or anything
that auto-downloads another model family beyond the small manual alias
list in `scripts/llamacpp_models.py`. If one of those becomes useful
again, add it deliberately and update this file.

## Distribution model

Repo-first for our own machines; USB bundles for colleagues. The USB path is
`scripts/build_bundle.sh all --out <mountpoint>` after formatting with
`scripts/usb_format.sh` when needed. USB bundles include llama.cpp,
opencode, whisper.cpp, Qwen GGUF/mmproj, and `ggml-large-v3-turbo.bin`.
Generated services bind only localhost: llama.cpp on `127.0.0.1:8080`,
whisper.cpp on `127.0.0.1:8427`. Opencode points only at localhost and
sets the same privacy env/config as the repo install.

Pi is a developer-only convenience installed through the system `npm` via
`scripts/pi_install.sh`; if Node is missing the script tells the user to
install it from the OS package manager and exits. Do not add bundled Node,
bundled Pi packages, or offline npm caches to any distribution path.

Whisper.cpp clones into `~/code/whisper.cpp` (so the user can hack on it
alongside the rest of `~/code`). The legacy `~/.local/whisper.cpp` install
remains supported — `server_start_whisper.sh` and the launchd / systemd
installers prefer whichever has a built `whisper-server` binary.

## Testing

`bash ci/run_tests.sh` must be green locally before any commit. Tests are
dry-run only — real inference costs too much to run in CI.
