# Whisper.cpp (STT for voxtype, slopbox, meeting notes)

Whisper.cpp builds from source against the local GPU: CUDA on
Linux/NVIDIA, Metal on Mac, Vulkan on Linux or Windows without CUDA.
The same scripts power the macOS launchd agent
(`com.slopcode.whisper-server`) and the Linux `whisper-server.service`
`systemd --user` unit.

```
scripts/setup_whisper.sh                  # clone + build into ~/code/whisper.cpp
                                          # (falls back to ~/.local/whisper.cpp
                                          #  if ~/code is absent)
scripts/install_linux_whisper_systemd.sh  # systemd --user unit (Linux)
scripts/install_mac_launchagents.sh       # bundles whisper-server on macOS
```

The server speaks the OpenAI `/v1/audio/transcriptions` API on
`http://127.0.0.1:8427`. Any whisper-1 client (voxtype, slopbox, the
voice-memo classifier) works against it without changes.

If a previous installation left the AUR `whisper.cpp-cuda` package in
place, the installer refuses to clobber the system unit and prints the
one-time `sudo pacman -Rns ...` line to remove it. The new user-level
unit then takes the same `:8427` port.
