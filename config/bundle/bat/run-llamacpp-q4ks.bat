@echo off
REM SYCL GPU: Q4_K_S (~21.4 GB), smaller non-MTP quant, auto-restart.
if not defined DEST set "DEST=%USERPROFILE%\slopcode"
set "PATH=%DEST%\llama.cpp-sycl;%PATH%"
:start
"%DEST%\llama.cpp-sycl\llama-server.exe" -m "%DEST%\models\Qwen3.6-35B-A3B-UD-Q4_K_S.gguf" --mmproj "%DEST%\models\mmproj-BF16.gguf" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 2048 -ngl 99 -np 1 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --reasoning on --no-context-shift --no-mmap --host 127.0.0.1 --port 8080
echo llama-server exited, restarting in 5 seconds...
timeout /t 5 /nobreak >nul
goto start
