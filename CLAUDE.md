# CLAUDE.md

Guidance for Claude Code working inside this repository.

## What this repo is

One blessed local coding stack, nothing else:

- **Runtime**: `llama-server` from the latest upstream ggml-org/llama.cpp
  release (b9180+ for MTP support). `setup_llamacpp.sh` defaults to the
  latest tag for prebuilt installs and `master` for source builds.
- **Model**: `unsloth/Qwen3.6-35B-A3B-MTP-GGUF` at `UD-Q4_K_XL` — alias
  `qwen3.6-35b-a3b-mtp-q4`, served as `qwen`. The MTP head + llama.cpp
  draft-mtp speculative decoding gives 1.4-2.2x decode speedup at ~1 GB
  extra VRAM. The 27B dense profile (`qwen3.6-27b-q4`) is a special mode
  for slopgate deployments on more powerful hardware.
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
| macOS   | Metal   | on demand | 35B-A3B `qwen` :8080       | none by default     |

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
  server_start_qwen_coder.sh    swap to Qwen3-Coder-30B-A3B-Instruct (FIM).
                                Stops any running llama-server, then re-launches
                                with the qwen3-coder-30b-a3b-q4 alias, Best
                                Practices sampler block, --cache-reuse 256 (from
                                the upstream --fim-qwen-30b-default preset).
                                For llama.vscode autocomplete; swap back to chat
                                with stop + server_start_llamacpp.sh.
  server_start_qwen27b.sh       slopgate/powerful-machine special mode:
                                Qwen3.6 27B Q4_K_M, Q8 KV, 128K context,
                                loopback :8080. Not the standard local default.
  server_stop_llamacpp.sh
  install_linux_systemd.sh      write & enable ~/.config/systemd/user/slopcode-
                                llamacpp.service; enable-linger for boot autostart
  install_mac_launchagents.sh   macOS launchd user agent (single 35B-A3B instance)
  install_slopgate_leader.sh    install slopgate balancer + co-located agent
                                (sources ~/.config/slopgate/leader.env)
  install_slopgate_follower.sh  install slopgate agent only (sources
                                ~/.config/slopgate/follower.env)
  install_slopgate_watchdog.sh  install slopgate watchdog (primary +
                                weekly summary on leader via launchd,
                                reverse on chat.computor.at via systemd).
                                Posts to Zulip stream `monitoring`,
                                single topic `slopgate`; resolves +
                                marks-read for all users when fully
                                green (server-side ORM update on chat
                                host via locked-down SSH dispatcher).
                                Sources
                                ~/infra/computor-infra/env for SMTP and
                                chat.computor.at SSH parameters. Generates
                                a dedicated passphraseless ed25519 key on
                                the leader (~/.ssh/slopgate_watchdog_ed25519)
                                and installs it in chat's
                                /root/.ssh/authorized_keys with a
                                forced-command lock that only updates
                                /var/lib/slopgate-watchdog/primary-heartbeat.
                                The launchd SSH agent socket is empty for
                                background jobs (Touch ID never fires), so
                                an agent-dependent key would fail silently
                                — hence the dedicated key + IdentitiesOnly.
  slopgate_watchdog.sh          primary check loop (5 min). Verifies
                                balancer :8080/v1/models, management
                                :8085/healthz, usable_agents > 0,
                                launchd services, and leader disk. On
                                all-OK, pushes heartbeat via SSH to the
                                chat host using the dedicated key above.
  slopgate_watchdog_reverse.sh  reverse check (10 min on chat host) —
                                pages if /var/lib/slopgate-watchdog/
                                primary-heartbeat is older than 15 min.
  slopgate_watchdog_summary.sh  weekly Markdown ring-state report
                                (Mon 06:00).
  slopgate_watchdog_lib.sh      shared Zulip / state / mail helpers.
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
  install_voxtype_windows.bat   documented manual path (upstream is
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

The local offline default is single-slot 180K: `-np 1 -ub 1024 -c 180000`.
Qwen3.6 35B-A3B is MoE. **Per-platform MoE policy diverges**:

- **Linux CUDA** uses `--n-cpu-moe 35` (expert layers 0–34 on CPU, 35–39
  on GPU) — bench-driven on a 16 GB RTX 5060 Ti below.
- **Windows-arc (Intel Arc)** runs with **no** `--cpu-moe` /
  `--n-cpu-moe` (all 40 MoE expert layers on the iGPU). Bench-validated
  on a Core Ultra 7 with 64 GB unified RAM and "Shared GPU Memory
  Override" raised to 32 GB — meaningfully faster than the old
  `--cpu-moe` default. Requires the two Vulkan stability env vars
  (`GGML_VK_DISABLE_COOPMAT[2]=1`) and the F16 workaround
  (`GGML_VK_DISABLE_F16=1`); see the "Windows-arc USB bundle" section
  for the upstream Intel TDR/F16 bugs that force the env vars. Hosts
  with less unified VRAM should fall back to `--n-cpu-moe 20` and
  upward (40 ≡ `--cpu-moe`).
- **macOS** uses unified memory — no MoE split.

On Linux CUDA partial MoE offload replaces the old blanket `--cpu-moe`.
Benchmark on RTX 5060 Ti 16 GB with Qwen3.6-35B-A3B UD-Q4_K_XL at c=262144
(same relative numbers held with UD-Q4_K_M earlier; the XL bench was not
rerun but the layer-cost ratios are unchanged):

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

| Host            | Instances        | `--alias` | `-np` | `-c`   | Per-slot ctx |
| --------------- | ---------------- | --------- | ----- | ------ | ------------ |
| Linux / Windows | 35B-A3B on :8080 | `qwen`    | 1     | 180000 | 180000       |
| macOS           | 35B-A3B on :8080 | `qwen`    | 1     | 180000 | 180000       |

The 27B dense profile (`qwen3.6-27b-q4`) remains in `scripts/llamacpp_models.py`
for manual prefetch and explicit runs via `scripts/server_start_qwen27b.sh`. It
is not the default opencode path — use it only on slopgate deployments backed
by more powerful hardware.

Override per invocation with `LLAMACPP_PARALLEL` and `LLAMACPP_CONTEXT`.

## Windows-arc USB bundle (Intel Arc iGPU, SYCL / oneAPI)

**As of 2026-05-22 the windows-arc bundle ships the upstream Windows
SYCL prebuilt (`llama-bN-bin-win-sycl-x64.zip`) instead of the older
Vulkan prebuilt.** The Vulkan-coopmat / F16 workarounds and the
`GGML_VK_DISABLE_*` env vars below no longer apply — they were
Vulkan-specific. SYCL gives ~2x prefill on Lunar Lake / Arc 140V and
sidesteps the active Vulkan-Arc bugs (#18808 agentic-use, #22275 silent
exits, #20554 coopmat TDR). The historical Vulkan notes are kept for
context but the live bundle is SYCL.

### Historical: Vulkan profile (no longer used)

Target hardware: Intel Arc 140V iGPU (Lunar Lake, Xe2) on Windows 11,
64 GB unified system RAM shared with the iGPU. Other Arc generations
(MTL, ARL-H, dGPU B-series) should also work with the same flags but
have not been validated end-to-end.

The `windows-arc` bundle uses the era-1 "qwenstack" safe profile plus
the three upstream-documented Intel Arc Vulkan stability env vars and
Unsloth's recommended `UD-Q4_K_XL` quant. **All 40 MoE expert layers
stay on the Arc iGPU** (no `--cpu-moe` / `--n-cpu-moe`); validated on
Core Ultra 7 + 64 GB unified RAM with Shared GPU Memory Override at
32 GB:

```
GGML_VK_DISABLE_COOPMAT=1 \
GGML_VK_DISABLE_COOPMAT2=1 \
GGML_VK_DISABLE_F16=1 \
llama-server.exe -m Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf --mmproj mmproj-BF16.gguf \
  -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 512 \
  -ngl 99 -fa on \
  -np 1 --threads <physical_cores - 2> --threads-http 4 \
  --alias qwen --jinja \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
  --presence-penalty 0 --repeat-penalty 1 \
  --reasoning-format deepseek --reasoning on --reasoning-budget 4096 \
  --no-context-shift --host 127.0.0.1 --port 8080
```

`install.bat` detects physical cores via PowerShell `Get-CimInstance
Win32_Processor` and emits the literal value into `run-llamacpp.bat`
(140V: 4P + 4LP = 8 → `--threads 6`).

The model file is `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` (Unsloth's
recommended variant, ~22.4 GB), not `UD-Q4_K_M` (which Unsloth's docs
treat as a smaller-but-not-recommended quant and which produced
slash-storm on a 155H Meteor Lake Xe-LPG iGPU even after coopmat was
disabled). Bartowski's standard `Q4_K_M` is also available as
`qwen3.6-35b-a3b-bartowski-q4` if a third variant is needed.

`install.bat` is aggressive: it `taskkill`s any running
`llama-server.exe` / `opencode.exe`, removes old Startup shortcuts,
old launchers, old `opencode.json`, the entire `%DEST%\llama.cpp`
and `%DEST%\opencode` directories, all old `*.gguf` in
`%DEST%\models`, and the `%LOCALAPPDATA%\Intel\ShaderCache` before
writing the new install. Re-running it always produces a clean
state.

### Required prerequisites before running install.bat

Two manual setup steps the bundle install can't do for the user. If
either is skipped on a 140V the bundle will OOM (without these the
flags above are correct but unreachable).

1. **Update Intel graphics driver to 32.0.101.8629 WHQL or newer**
   (released 2026-04-02). Older drivers — notably 101.8331 and earlier
   — have memory-accounting bugs on Lunar Lake UMA that surface as
   `vk::Device::createComputePipeline: ErrorOutOfDeviceMemory` and
   discrepancies like `compute buffer size of 160 MiB, does not match
   expectation of 2.3 MiB` (ggml-org/llama.cpp#18946). Driver via
   Windows Update → "View optional updates" → Graphics, or
   <https://www.intel.com/content/www/us/en/download/785597/>.
   The same release stream also contains the coopmat regression that
   `GGML_VK_DISABLE_COOPMAT=1` works around; staying on a newer driver
   doesn't bring back coopmat, but it does fix the unrelated memory
   bugs.

2. **Raise "Shared GPU Memory Override" to 32 GB** in Intel Graphics
   Software / Intel Arc Control → Performance tab. The 140V Vulkan
   driver only exposes ~16 GB to applications by default, even on a
   64 GB host. The bundle's working set at `-c 262144 q8_0 KV --n-cpu-moe
   35 -ub 1024` peaks around 17–20 GB on the GPU side, so the default
   cap will OOM partway through warmup despite ample system RAM.

These two steps are documented in the bundle's
`windows-arc/README.md` under "PREREQUISITES" so colleagues see them
before running `install.bat`.

### Why the GGML_VK_DISABLE_COOPMAT env vars are mandatory on Arc

Tracked upstream as **ggml-org/llama.cpp#20554** (closed-as-workaround,
Mar 2026, exact hardware match: Arc 140V on Windows 11). The Vulkan
`VK_KHR_cooperative_matrix` path uses Intel's XMX matrix engines; on
Intel Arc drivers 101.8509 / 101.8531 and later it produces deterministic
GPU hangs that trip Windows TDR. When TDR fails to recover the driver
cleanly the host BSODs with `VIDEO_TDR_FAILURE` or `DPC_WATCHDOG_VIOLATION`
("your device ran into a problem and needs to restart"). The reporter
tried raising Windows `TdrDelay` to 60 s and the laptop simply froze
for 60 s before the driver was reset — the timeout knob doesn't fix
anything, only delays the symptom.

The documented fix is to set the two env vars *before* invoking
`llama-server.exe`, which switches Vulkan back to the regular FP16
matmul path:

```bat
set "GGML_VK_DISABLE_COOPMAT=1"
set "GGML_VK_DISABLE_COOPMAT2=1"
```

After this, `llama-server`'s startup banner reports `matrix cores: none`
(instead of `KHR_coopmat`). A separate Arc 140V owner in #19957 confirmed
Qwen3-30B-A3B working at ~27 t/s after the same env-var workaround.

### Sibling concern: MUL_MAT_ID 10 s job timeout (#19327)

A second class of Arc-Vulkan-MoE TDR is tracked separately as
**ggml-org/llama.cpp#19327**: the Intel `xe` kernel driver enforces a
hard 10 s timeout per GPU submission, and `MUL_MAT_ID` over 128 Qwen3
experts can exceed it when many MoE layers are on the iGPU. That issue's
reporter did **not** test with `GGML_VK_DISABLE_COOPMAT=1` set, so it's
unclear whether the same workaround also covers it. The bundle leaves
`--n-cpu-moe 35` (5 of 40 MoE layers on iGPU) as a calculated bet:
small enough that single-shader runtime stays well under 10 s on 140V,
big enough to get back the ~2× prefill and 1.2× decode the
RTX-5060-Ti-on-CUDA bench measured.

If the bundle TDRs anyway, the recovery sequence (in order, escalating):
1. Confirm the env vars are actually in `run-llamacpp.bat` (check
   `matrix cores: none` in llama-server startup output).
2. Confirm Shared GPU Memory Override is raised (Intel Graphics
   Software → Performance, 32 GB on a 64 GB host).
3. Drop `-ub 512 → 384 → 256` (shorter per-shader dispatch).
4. Add `--n-cpu-moe 20 → 30 → 40` (push expert layers back to CPU;
   40 ≡ `--cpu-moe`, all experts on CPU).
5. Raise Windows `TdrDelay` / `TdrDdiDelay` to 60 in registry as a
   defensive net (HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers).
6. Switch the Startup shortcut to `run-llamacpp-cpu.bat` (pure CPU,
   guaranteed-correct, ~10 t/s).

The bundle's run-llamacpp.bat already sets `GGML_VK_DISABLE_F16=1` by
default — this is the documented fix for ggml-org/llama.cpp#18969
(Intel iGPU F16 accumulator overflows and emits NaN/garbage on large
batches; symptom is non-slash-storm gibberish that survives a reboot).
Costs ~15 % decode throughput; the trade is worth it for correctness
across both Xe2 (140V) and Xe-LPG (155H Meteor Lake) hardware.

### Slash-storm history (May 2026)

The bundle briefly ran the Linux profile on Arc (commits ac47a6d→bbfcf9e).
Two of the regressions were genuine output-quality issues:

1. `--reasoning-format deepseek` was missing in the Windows bat, so the Qwen
   `<think>…</think>` template wasn't being split into `reasoning_content` and
   opencode saw broken thinking streams.
2. The Qwen sampler block (`--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0`)
   was missing, so degenerate tails on the thinking stream weren't dampened.

Both are now passed. A third change in that period — switching `q8_0` KV →
`f16` KV citing #19957, #19276, #21888, #22275 — was a misdiagnosis: those
issues either resolved on master, were about SYCL not Vulkan, were retracted
by the reporter as non-reproducible, or were unrelated `prompt_save` crashes.
f16 KV doubled per-token KV bandwidth on UMA and made the bundle slower
without addressing any real bug. Reverted.

### Release pin

The Windows Vulkan release is no longer pinned. Re-pin via `LLAMACPP_TAG`
if a future upstream release introduces an Arc-specific regression.

### CPU fallback

`run-llamacpp-cpu.bat` (`-ngl 0`, no mmproj, `--threads 8`) ships as a
guaranteed-correct fallback. If the Vulkan path produces garbage or any sign
of GPU instability, kill the running service and start `run-llamacpp-cpu.bat`
instead; update the Startup shortcut accordingly.

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
fit it. Optional sticky session affinity via the `x-session-affinity` header.

**Configuration.** Per-host capability data and topology live in env files
outside the repo:
- `~/.config/slopgate/leader.env` — leader balancer + local agent
- `~/.config/slopgate/follower.env` — follower agent

Templates at `config/slopgate/{leader,follower}.env.example`. Real env files
are gitignored. Concrete IPs and hostnames never leak into commits, PR
descriptions, or issue bodies.

**Model naming.** Every agent advertises a canonical model slug, a short
alias (legacy `--model-alias`), and any number of additional routing
aliases. The full convention plus the alias table for the three current
Qwen variants on faepmac1 lives in the slopgate repo:
<https://github.com/sloppy-org/slopgate#model-naming-convention>.

Current canonical → alias mapping in the env templates. Canonical names are
family-level (no quant suffix); each peer also reports its quant in a
separate `quant` field, so two peers serving the same family at the same
context under different quants share alias `qwen` without raising a config
mismatch:

| Canonical                              | Aliases                                       | Quants in service                |
|----------------------------------------|-----------------------------------------------|----------------------------------|
| `unsloth/qwen3.6:35b-a3b@180k`         | `qwen`, `35b`, `35b@180k`, `Q4`               | `UD-Q4_K_XL-MTP`, `UD-IQ4_XS`    |
| `bartowski/qwen3.6:27b@180k`           | `qwen27b`, `qwen3.6-27b`, `qwen3.6-27b@180k`  | `Q4_K_M-MTP`                     |
| `unsloth/qwen3.5:122b-a10b@180k`       | `qwen122b`, `qwen3.5-122b`, `qwen3.5-122b@180k` | `UD-Q4_K_XL-MTP`               |

Two peers under the same alias share the family-level canonical and
differ only via the per-peer `quant` field. The `-MTP` suffix in the
quant label marks peers loading the multi-token-prediction variant from
`unsloth/Qwen3.x-...-MTP-GGUF`; llama.cpp >= b9180 drafts tokens via the
MTP head (`--spec-type draft-mtp --spec-draft-n-max 2`) for a 1.4-2.2x
decode speedup at ~1 GB extra resident memory. MTP is the right default
on the Mac Studio cluster leader and MTP-capable Mac followers. Linux /
Windows / tight-VRAM followers and the USB bundle stay on the non-MTP
GGUFs: the MTP head would eat the VRAM safety margin and bring no
benefit. The launcher branches on `*-mtp-*` aliases for the MTP sampler
recipe (`--temp 1.0 --presence-penalty 1.5`); non-MTP aliases keep the
standard Qwen sampler (`--temp 0.6 --presence-penalty 0`).

Reserved aliases (no live peer yet): `luna` for a future gpt-oss-120b
instance, `tuna` for a future short-context Qwen 35B chat pool.

**Machine profiles.** `SLOPGATE_LOCAL_MACHINE_PROFILE` /
`SLOPGATE_MACHINE_PROFILE` is a stable class name shared by physically
identical hosts. faepmac1 and faepmac2 both set
`mac-studio-m3-ultra-256g`, which lets the balancer apply faepmac1's
pre-calibration EMA seeds to faepmac2 immediately on first heartbeat —
no cold-start exploration. Each box still keeps its own `machine_id`;
the profile is purely a calibration-reuse key. The slopgate-agent also
reports a `config_digest` derived from llama-server `/props`; two peers
serving the same alias with disagreeing canonical or digest light up a
"config mismatch" badge on the dashboard.

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
`security_harden.sh`, dual-instance local/fast servers, a separate FIM
autocomplete sidecar on a second port (chat and coder share `:8080` and the
user swaps the loaded model; see "Chat vs autocomplete" in `README.md`), the
macOS Qwen 27B dense companion as a default-installed model, intentee/paddler
v2+ (the
embedded-llama.cpp rewrite — slopgate stays on the v1.x transparent-proxy
line so we keep control of llama-server flags), llama-server bound to
`0.0.0.0` on any cluster node (it must always bind WG-only or loopback),
the slopgate balancer's `--slots-endpoint-enable` flag (it leaks per-slot
prompt content), TCP/HTTP MCP daemons for
helpy or sloptools (they're stdio-only on purpose so no co-tenant can
reach them), bundled Node/Pi/offline-npm-cache distribution (assume system
`npm` and a checkout of this repo on every target — see
`scripts/pi_install.sh`), the Vulkan KHR_coopmat path on `windows-arc`
(set `GGML_VK_DISABLE_COOPMAT=1` and `GGML_VK_DISABLE_COOPMAT2=1` before
every llama-server invocation; ggml-org/llama.cpp#20554 documents the
Arc 140V TDR/BSOD bug), or anything that auto-downloads another model
family beyond the small manual alias list in
`scripts/llamacpp_models.py`. If one of those becomes useful again,
add it deliberately and update this file.

## Distribution model

Repo-first for our own machines; USB bundles for colleagues. The USB path is
`scripts/build_bundle.sh all --out <mountpoint>` after formatting with
`scripts/usb_format.sh` when needed. USB bundles include llama.cpp,
opencode, whisper.cpp, the meeting workflow scripts, the Qwen GGUF/mmproj,
and `ggml-large-v3-turbo.bin`.

**Automatic install scope.** The bundled `install.sh` / `install.bat`
auto-installs and autostarts llama.cpp on `127.0.0.1:8080`, opencode,
whisper.cpp on `127.0.0.1:8427`, and the meeting workflow scripts. Voxtype is
not part of the USB installer. Meeting transcription is PCM WAV only so the
installed whisper launcher does not depend on ffmpeg; `meeting-process` calls
`opencode run` once after transcription rather than relying on an agent skill
or nested OpenCode session. Opencode points only at localhost and sets the
same privacy env/config as the repo install.

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
