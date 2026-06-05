# USB bundle

Build a localhost-only offline bundle for colleagues:

```
scripts/build_bundle.sh all --out /mnt/usb
```

The bundle includes:

- llama.cpp (latest release): Vulkan on Linux and Windows, Metal on
  macOS. Upstream paused win-sycl-x64 builds (PR #23705); the bundle
  ships Vulkan, which tracks the latest release.
- opencode (latest), whisper.cpp.
- Qwen3.6-35B-A3B **UD-Q4_K_XL** (~22.9 GB) from
  `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`, the default chat GGUF. MTP head
  enables `--spec-type draft-mtp` for 1.4-2.2x decode; sampler is Qwen's
  "thinking + precise coding" preset.
- Optional alternatives (soft-fail, only shipped if prefetched):
  - **UD-Q4_K_S** (~21.4 GB): smaller K-quant for tighter VRAM. Ship with
    `scripts/llamacpp_models.py prefetch qwen3.6-35b-a3b-mtp-q4ks`.
  - **gpt-oss-20b-mxfp4** (~11.3 GB): chat-only for 16 GB machines.
    See [gpt-oss-20b.md](gpt-oss-20b.md). Ship with
    `scripts/llamacpp_models.py prefetch gpt-oss-20b`.
- The Qwen mmproj and `ggml-large-v3-turbo.bin`.
- The `local-luna` tutorial and two VS Code VSIX files with settings
  helpers: llama.vscode and hackl (built from `HACKL_SOURCE`).

Bundle size is roughly 26 GB on disk (~23 GGUF + ~0.9 mmproj + ~1.6
whisper + binaries / opencode / docs), plus ~21.4 GB for the optional
Q4_K_S and ~11.3 GB for gpt-oss. A 64 GB USB stick is the sane minimum.

It does not include Pi, Node, or an npm cache.

Linux and macOS ship a single `install.sh`. Windows ships composable
bat files:

| Script              | Purpose                                    | Called by install.bat |
| ------------------- | ------------------------------------------ | --------------------- |
| `install.bat`       | Orchestrator: checksum, cleanup, llama, oc | yes (entry point)     |
| `install-cleanup.bat` | Kill processes, remove old install        | yes                   |
| `install-llama.bat`   | llama.cpp binaries, models, launchers    | yes                   |
| `install-opencode.bat` | opencode binary, env vars, PATH         | yes                   |
| `install-whisper.bat`  | whisper.cpp transcription (optional)     | **no**                |

Whisper is not installed by default. Run `install-whisper.bat` manually
for meeting transcription on `127.0.0.1:8427`.

All generated Windows launchers pass `--no-mmap` to avoid mmap
double-counting on UMA systems. GPU launchers set
`GGML_VK_DISABLE_COOPMAT=1`, `GGML_VK_DISABLE_COOPMAT2=1`, and
`GGML_VK_DISABLE_F16=1` for Intel driver stability; use `-b 512` to
keep prefill dispatches under the TDR threshold. Flash attention stays
on (needed for 128K context memory). Every launcher auto-restarts
llama-server after 5 seconds if it exits.

A `fix-tdr.reg` file ships on the USB. It raises the Windows TDR timeout
to 60 seconds (requires admin + reboot). Intel's oneAPI documentation
recommends this for GPU compute workloads.

Generated installers:

- bind llama.cpp to `127.0.0.1:8080`,
- put the meeting scripts on PATH,
- configure opencode against the local endpoint with telemetry, share,
  update, and model-fetch paths disabled,
- enable MTP speculative decoding (`--spec-type draft-mtp
  --spec-draft-n-max 2`) for the ~1.4-2.2x decode speedup.

## windows-arc

Target hardware: Intel Arc 140V iGPU (Lunar Lake, Xe2) on Windows 11,
64 GB unified RAM shared with the iGPU. Other Arc generations (MTL, ARL-H,
dGPU B-series) should also work but are not validated end-to-end.

The bundle ships the Vulkan prebuilt (`win-vulkan-x64`), which tracks the
latest llama.cpp release. Upstream paused win-sycl-x64 builds (PR #23705);
Vulkan is universally available and works on Intel Arc, AMD, and NVIDIA.

Upstream paused the `win-sycl-x64` prebuilt on 2026-05-26 (PR #23705: SYCL
and CANN builds alone ate over a third of the 10 GB CI cache). The pause is
temporary, to return once dedicated runners land. Until then
`build_bundle.sh`'s `llama_asset` walks the release list newest-first and
pins windows-arc to the newest release still shipping the asset (b9334, the
2026-05-26 build); mac-m1 and linux-cuda stay on the absolute latest. When
upstream re-enables SYCL the same walk picks the latest again with no edit.
Force a specific build with `LLAMACPP_TAG` if a later SYCL release
regresses on Arc.

### Prerequisites before install.bat

Two manual steps the installer cannot do. Skip either on a 140V and the
bundle OOMs.

1. **Intel graphics driver 32.0.101.8629 WHQL or newer** (2026-04-02).
   Older drivers (101.8331 and earlier) have memory-accounting bugs on
   Lunar Lake UMA that surface as
   `vk::Device::createComputePipeline: ErrorOutOfDeviceMemory` and
   `compute buffer size ... does not match expectation`
   (ggml-org/llama.cpp#18946). Windows Update -> "View optional updates"
   -> Graphics, or <https://www.intel.com/content/www/us/en/download/785597/>.
2. **Raise "Shared GPU Memory Override" to 32 GB** (Intel Graphics
   Software / Arc Control -> Performance). The 140V driver exposes only
   ~16 GB to applications by default even on a 64 GB host; the working set
   peaks at 17-20 GB and OOMs partway through warmup otherwise.

All three are in the bundle's `windows-arc/README.md` under "PREREQUISITES".

### Launchers

| Launcher                   | Backend | Model   | Notes                          |
| -------------------------- | ------- | ------- | ------------------------------ |
| `run-llamacpp.bat`         | Vulkan  | Q4_K_XL | Default, auto-restart          |
| `run-llamacpp-q4ks.bat`    | Vulkan  | Q4_K_S  | Smaller quant (~21.4 GB)       |
| `run-llamacpp-cpu.bat`     | CPU     | Q4_K_XL | Guaranteed correct, ~10 t/s    |
| `run-gpt-oss.bat`          | Vulkan  | gpt-oss | 16 GB machines                 |
| `keepalive.bat`            | --      | --      | Pings server every 30 s        |
| `fix-tdr.reg`              | --      | --      | TDR timeout 60 s (admin)       |

All GPU launchers auto-restart after 5 seconds if llama-server exits.
If the GPU path produces garbage or instability, fall back to
`run-llamacpp-cpu.bat` and update the Startup shortcut.

### Historical: Vulkan profile (no longer used)

The pre-SYCL bundle ran Vulkan with all 40 MoE expert layers on the Arc
iGPU plus three upstream-documented stability env vars:

```bat
set "GGML_VK_DISABLE_COOPMAT=1"
set "GGML_VK_DISABLE_COOPMAT2=1"
set "GGML_VK_DISABLE_F16=1"
```

- **COOPMAT/COOPMAT2** (ggml-org/llama.cpp#20554, closed-as-workaround,
  exact match Arc 140V/Win11): the Vulkan `VK_KHR_cooperative_matrix` path
  on Intel's XMX engines produces deterministic GPU hangs that trip Windows
  TDR, and a failed TDR recovery BSODs the host (`VIDEO_TDR_FAILURE`,
  `DPC_WATCHDOG_VIOLATION`). Raising `TdrDelay` only delays the symptom.
  With the vars set, llama-server's banner reports `matrix cores: none`
  and falls back to the FP16 matmul path. A second 140V owner (#19957)
  confirmed Qwen3-30B-A3B at ~27 t/s after the same fix.
- **F16** (ggml-org/llama.cpp#18969): Intel iGPU F16 accumulators overflow
  and emit NaN/garbage on large batches (non-slash-storm gibberish that
  survives a reboot). Costs ~15 % decode; correctness on Xe2 (140V) and
  Xe-LPG (155H Meteor Lake) is worth it.

A sibling MoE timeout (#19327: the Intel `xe` driver enforces a hard 10 s
per-submission limit, and `MUL_MAT_ID` over 128 experts can exceed it) was
the reason the Vulkan bundle kept `--n-cpu-moe 35` rather than all experts
on the iGPU. If a Vulkan path ever TDRs again, escalate in order: confirm
the env vars reach the launcher (`matrix cores: none`); confirm the shared-
memory override; drop `-ub 512 -> 384 -> 256`; raise `--n-cpu-moe 20 -> 30
-> 40`; raise `TdrDelay`/`TdrDdiDelay` to 60 in
`HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers`; fall back to
`run-llamacpp-cpu.bat`.

Model file: `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` (~22.4 GB), Unsloth's
recommended quant. `UD-Q4_K_M` produced slash-storm on a 155H Meteor Lake
Xe-LPG iGPU even after coopmat was disabled; Bartowski's `Q4_K_M` is
available as `qwen3.6-35b-a3b-bartowski-q4` if a third variant is needed.

`install.bat` calls `install-cleanup.bat` first: `taskkill` running
processes, remove old Startup shortcuts, launchers, `opencode.json`,
the `llama.cpp` / `opencode` dirs, all old
`*.gguf`, and the `%LOCALAPPDATA%\Intel\ShaderCache`. Re-running
always produces a clean state.

#### Slash-storm history (May 2026)

The bundle briefly ran the Linux profile on Arc (commits ac47a6d->bbfcf9e).
Two genuine output-quality regressions: `--reasoning-format deepseek` was
missing (so the Qwen `<think>` template never split into `reasoning_content`
and opencode saw broken thinking streams), and the sampler block was missing
(degenerate thinking tails undamped). Both are passed now. A third change in
that window, `q8_0` KV -> `f16` KV citing #19957/#19276/#21888/#22275, was a
misdiagnosis (resolved on master, SYCL-not-Vulkan, retracted, or unrelated
`prompt_save` crashes); f16 KV doubled per-token KV bandwidth on UMA for no
real bug. Reverted.
