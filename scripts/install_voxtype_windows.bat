@echo off
REM Voxtype on Windows — documented manual path.
REM
REM Upstream peteonrails/voxtype is Linux-native (Wayland + evdev) and does
REM not ship a Windows binary. Trying to build from source on Windows is a
REM non-goal for the upstream project. This script exists so users who run
REM install_voxtype_windows.bat by reflex get a clear answer instead of
REM silence.

echo voxtype is Linux-only upstream.
echo.
echo   - Source:  https://github.com/peteonrails/voxtype
echo   - Reason:  Wayland + evdev keyboard hooks; Windows support is a
echo              non-goal upstream (see voxtype/CLAUDE.md "Non-Goals").
echo.
echo If you need local push-to-talk dictation on Windows pointed at the
echo slopcode-infra whisper-server, options that work today:
echo.
echo   1. WSL2: install Ubuntu and run
echo        scripts/install_voxtype_linux.sh
echo      inside the WSL distro. Hotkeys reach the Linux daemon via the
echo      WSL keyboard pipe; output goes to the WSL terminal or via
echo      wl-clipboard if you bridge it.
echo   2. PowerToys "Voice Typing" or Win+H pointed at a custom STT
echo      endpoint (third-party tools required; native Win+H talks only
echo      to Microsoft).
echo   3. SuperWhisper, Wispr Flow, or any Windows dictation app that
echo      accepts a custom OpenAI-compatible transcription URL pointed at
echo      http://127.0.0.1:8427/v1/audio/transcriptions (with the slopcode-
echo      infra whisper-server reachable from Windows; if Windows hosts the
echo      llama / whisper stack already, the URL is loopback).
echo.
echo The slopcode-infra Windows install path for the LLM stack runs through
echo a checkout of this repo on the target host:
echo.
echo   scripts/setup_llamacpp.sh
echo   python3 scripts/llamacpp_models.py prefetch
echo   scripts/server_start_llamacpp.sh
echo.
echo There is currently no Windows-native voxtype client until upstream
echo gains Windows support.
