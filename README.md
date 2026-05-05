# slopcode-infra

Single-path local coding stack: **llama.cpp + Qwen3.6 35B A3B (Q4_K_M) +
OpenCode**, plus optional Pi, whisper.cpp, and voxtype install scripts.
Every component lives in the user profile and runs as a user-level service.
No root, no admin.

License: [MIT](LICENSE)

## The one blessed configuration

| Target           | OS      | GPU          | Memory         | Backend | CPU-MoE |
| ---------------- | ------- | ------------ | -------------- | ------- | ------- |
| Local (this box) | Linux   | NVIDIA 16 GB | 96 GB          | CUDA    | on      |
| Intel Arc box    | Windows | Intel Arc    | 32 GB shared   | Vulkan  | on      |
| Apple M1         | macOS   | M1           | 32 GB unified  | Metal   | off     |

- **Model**: `bartowski/Qwen_Qwen3.6-35B-A3B-GGUF` at `Q4_K_M` (~20 GB), served as `qwen`.
- **Runtime**: `llama-server` (upstream release, Q8_0 KV, 128 K context, `-fa on`, `--jinja`).
- **Harnesses**: `opencode` by default; optional Pi through system `npm`; title generation disabled for OpenCode, local llama.cpp provider, telemetry disabled, `reasoning: true`, server-enforced thinking budget (`4096` by default).

Nothing else is downloaded automatically. Optional aliases live in
`scripts/llamacpp_models.py` for manual prefetch only, including the FortBench
MiniMax benchmark profiles.

## Install from this repo

Every script below runs as the unprivileged user and assumes `git`,
`cmake`, `ninja`, and `curl`. Pi is optional and uses the system
`node`/`npm`; install those through the OS package manager before running
`scripts/pi_install.sh`.

```
scripts/setup_llamacpp.sh                     # fetch latest upstream release for this OS
python3 scripts/llamacpp_models.py prefetch   # download the blessed model
scripts/server_start_llamacpp.sh              # foreground run, smoke test
scripts/install_linux_systemd.sh              # systemd --user unit (Linux)
scripts/install_mac_launchagents.sh           # launchd user agents (macOS)
scripts/opencode_install.sh                   # curl|bash the opencode CLI
scripts/pi_install.sh                         # optional: npm install Pi Coding Agent + local config
scripts/opencode_set_llamacpp.sh              # write ~/.config/opencode/opencode.json
opencode                                      # go
```

## Whisper.cpp (STT for voxtype, slopbox, meeting notes)

Whisper.cpp builds from source against the local GPU (CUDA on Linux/NVIDIA,
Metal on Mac, Vulkan on Linux/Windows without CUDA). The same scripts power
the macOS launchd agent (`com.slopcode.whisper-server`) and a Linux
`systemd --user` unit (`whisper-server.service`).

```
scripts/setup_whisper.sh                      # clone + build into ~/code/whisper.cpp
                                              # (falls back to ~/.local/whisper.cpp
                                              #  if ~/code is absent)
scripts/install_linux_whisper_systemd.sh      # systemd --user unit (Linux)
scripts/install_mac_launchagents.sh           # bundles whisper-server agent on macOS
```

The server speaks the OpenAI `/v1/audio/transcriptions` API on
`http://127.0.0.1:8427` so any whisper-1 client (voxtype, slopbox, the
voice-memo classifier) works against it without changes.

If a previous installation left the AUR `whisper.cpp-cuda` package in place
the installer refuses to clobber the system unit and prints the one-time
`sudo pacman -Rns ...` line to remove it. The new user-level unit then takes
the same `:8427` port.

## USB bundle

Build a localhost-only offline bundle for colleagues:

```
scripts/build_bundle.sh all --out /mnt/usb
```

The bundle includes llama.cpp, opencode, whisper.cpp, Qwen3.6 35B A3B
Q4_K_M, the Qwen mmproj, and `ggml-large-v3-turbo.bin`. It does not include
Pi, Node, or an npm cache. Generated installers bind llama.cpp to
`127.0.0.1:8080` and whisper.cpp to `127.0.0.1:8427`; opencode is configured
only against the local llama.cpp endpoint with telemetry/share/update/model
fetch paths disabled.

## Voxtype install (push-to-talk dictation)

`peteonrails/voxtype` is the Linux-native push-to-talk dictation daemon. The
helpers below wrap the upstream release artefacts so the user does not have
to read the upstream README before hitting the F-key.

```
scripts/install_voxtype_linux.sh              # systemd --user, deb/rpm fallback
scripts/install_voxtype_mac.sh                # documented manual path (no Mac binary upstream)
scripts/install_voxtype_windows.ps1           # documented manual path (no Windows binary upstream)
```

The Linux installer detects GPU class (CUDA / Vulkan / CPU-only) and pulls
the matching release binary; it points the daemon at the local whisper
server on `127.0.0.1:8427` by default and registers a `systemd --user`
service. macOS and Windows scripts surface the upstream non-goal of those
platforms instead of pretending support exists.

## Tests

```
bash ci/run_tests.sh
```

Exercises the llama.cpp launcher (dry-run), the OpenCode config generator,
the Pi config generator, USB script syntax/help, and a pure-stdlib
mock-server health check. Real inference is out of scope for CI.
