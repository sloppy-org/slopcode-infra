@echo off
REM Vulkan GPU fallback: Q4_K_XL, no MTP, Vulkan stability vars, auto-restart.
REM Use if SYCL crashes or for non-Intel GPUs (AMD, NVIDIA without CUDA toolkit).
if not defined DEST set "DEST=%USERPROFILE%\slopcode"
set "GGML_VK_DISABLE_COOPMAT=1"
set "GGML_VK_DISABLE_COOPMAT2=1"
set "GGML_VK_DISABLE_F16=1"
set "PATH=%DEST%\llama.cpp;%PATH%"
:start
"%DEST%\llama.cpp\llama-server.exe" -m "%DEST%\models\Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" --mmproj "%DEST%\models\mmproj-BF16.gguf" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 2048 -ngl 99 -fa off -np 1 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --reasoning on --no-context-shift --no-mmap --host 127.0.0.1 --port 8080
echo llama-server exited, restarting in 5 seconds...
timeout /t 5 /nobreak >nul
goto start
