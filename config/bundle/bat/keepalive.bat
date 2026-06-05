@echo off
echo Pinging llama-server every 30 s to keep GPU alive. Ctrl-C to stop.
:loop
curl -s -o nul http://127.0.0.1:8080/health
timeout /t 30 /nobreak >nul
goto loop
