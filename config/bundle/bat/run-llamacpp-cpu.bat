@echo off
REM CPU fallback (-ngl 0); always correct but ~10 tok/s, auto-restart.
if not defined DEST set "DEST=%USERPROFILE%\slopcode"
set "PATH=%DEST%\llama.cpp;%PATH%"
:start
"%DEST%\llama.cpp\llama-server.exe" -m "%DEST%\models\Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -ngl 0 -np 1 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --reasoning on --no-context-shift --no-mmap --host 127.0.0.1 --port 8080
echo llama-server exited, restarting in 5 seconds...
timeout /t 5 /nobreak >nul
goto start
