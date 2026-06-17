@echo off
REM CUDA A2000 profile (8 GB NVIDIA, non-MTP Q4_K_XL, heavy CPU offload), auto-restart.
REM Tune -ngl upward while watching nvidia-smi.
if not defined DEST set "DEST=%USERPROFILE%\slopcode"
set "PATH=%DEST%\llama.cpp-cuda;%PATH%"
:start
"%DEST%\llama.cpp-cuda\llama-server.exe" -m "%DEST%\models\Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" --mmproj "%DEST%\models\mmproj-BF16.gguf" -c 16384 --cache-type-k q4_0 --cache-type-v q4_0 -b 1024 -ub 512 -ngl 20 --n-cpu-moe 35 -fa on -np 1 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --reasoning on --no-context-shift --host 127.0.0.1 --port 8080
echo llama-server exited, restarting in 5 seconds...
timeout /t 5 /nobreak >nul
goto start
