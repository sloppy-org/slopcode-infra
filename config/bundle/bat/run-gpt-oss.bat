@echo off
REM SYCL GPU: gpt-oss-20b chat-only (~11.3 GB) for 16 GB machines, auto-restart.
if not defined DEST set "DEST=%USERPROFILE%\slopcode"
set "PATH=%DEST%\llama.cpp-sycl;%PATH%"
:start
"%DEST%\llama.cpp-sycl\llama-server.exe" -m "%DEST%\models\gpt-oss-20b-mxfp4.gguf" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 2048 -ngl 99 -np 1 --alias qwen --jinja --temp 1.0 --top-p 1.0 --top-k 40 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format none --no-context-shift --no-mmap --host 127.0.0.1 --port 8080
echo llama-server exited, restarting in 5 seconds...
timeout /t 5 /nobreak >nul
goto start
