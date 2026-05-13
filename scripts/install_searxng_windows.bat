@echo off
REM SearXNG on Windows as a user-level scheduled task.
REM
REM Keeps everything inside the user profile, binds only 127.0.0.1:8888,
REM uses Task Scheduler so the service comes back after reboot. Tries the
REM passwordless S4U principal first; falls back to an interactive logon
REM trigger if local policy blocks it.
setlocal EnableExtensions EnableDelayedExpansion

where git >nul 2>&1
if errorlevel 1 (
  echo missing required command: git 1>&2
  exit /b 1
)

set "PYEXE="
where py >nul 2>&1 && set "PYEXE=py -3"
if not defined PYEXE (
  where python >nul 2>&1 && set "PYEXE=python"
)
if not defined PYEXE (
  echo python or py is required 1>&2
  exit /b 1
)

if not defined SEARXNG_HOME set "SEARXNG_HOME=%LOCALAPPDATA%\slopcode\searxng"
if not defined SEARXNG_SRC set "SEARXNG_SRC=%SEARXNG_HOME%\src"
if not defined SEARXNG_VENV set "SEARXNG_VENV=%SEARXNG_HOME%\.venv"
if not defined SEARXNG_SETTINGS_DIR set "SEARXNG_SETTINGS_DIR=%APPDATA%\searxng"
if not defined SEARXNG_SETTINGS_PATH set "SEARXNG_SETTINGS_PATH=%SEARXNG_SETTINGS_DIR%\settings.yml"
if not defined SEARXNG_BIND_ADDRESS set "SEARXNG_BIND_ADDRESS=127.0.0.1"
if not defined SEARXNG_PORT set "SEARXNG_PORT=8888"
if not defined SEARXNG_BASE_URL set "SEARXNG_BASE_URL=http://127.0.0.1:%SEARXNG_PORT%"
if not defined SERVICE_NAME set "SERVICE_NAME=slopcode-searxng"
if not defined SEARXNG_REF set "SEARXNG_REF=master"
set "RUNNER_PATH=%SEARXNG_HOME%\run-searxng.bat"
if defined USERDOMAIN (set "USER_ID=%USERDOMAIN%\%USERNAME%") else (set "USER_ID=%USERNAME%")

mkdir "%SEARXNG_HOME%" 2>nul
mkdir "%SEARXNG_SETTINGS_DIR%" 2>nul

if not exist "%SEARXNG_SRC%\.git" (
  for %%I in ("%SEARXNG_SRC%") do mkdir "%%~dpI" 2>nul
  git clone https://github.com/searxng/searxng.git "%SEARXNG_SRC%"
  if errorlevel 1 exit /b 1
)

pushd "%SEARXNG_SRC%"
git fetch --all --tags --prune --quiet
git checkout %SEARXNG_REF%
if errorlevel 1 (popd & exit /b 1)
git pull --ff-only --quiet 2>nul
popd

%PYEXE% -m venv "%SEARXNG_VENV%"
if errorlevel 1 exit /b 1
set "VENV_PY=%SEARXNG_VENV%\Scripts\python.exe"
set "VENV_PIP=%SEARXNG_VENV%\Scripts\pip.exe"
if not exist "%VENV_PY%" (
  echo virtualenv python missing: %VENV_PY% 1>&2
  exit /b 1
)

"%VENV_PIP%" install -U pip setuptools wheel pyyaml msgspec typing-extensions pybind11 granian >nul
if errorlevel 1 exit /b 1
"%VENV_PIP%" install --use-pep517 --no-build-isolation -e "%SEARXNG_SRC%" >nul
if errorlevel 1 exit /b 1

set "SECRET=%SEARXNG_SECRET%"
if not defined SECRET if exist "%SEARXNG_SETTINGS_PATH%" (
  for /f "tokens=*" %%S in ('%PYEXE% -c "import re,sys;m=re.search(r'secret_key:\s*\"([^\"]+)\"',open(sys.argv[1],encoding=\"utf-8\").read());print(m.group(1) if m else \"\")" "%SEARXNG_SETTINGS_PATH%"') do set "SECRET=%%S"
)
if not defined SECRET (
  for /f "tokens=*" %%S in ('"%VENV_PY%" -c "import secrets;print(secrets.token_urlsafe(32))"') do set "SECRET=%%S"
)

REM Generate settings.yml. cmd's "echo" emits a trailing CRLF; SearXNG accepts that.
(
  echo use_default_settings:
  echo   engines:
  echo     keep_only:
  echo       - aol
  echo       - wikipedia
  echo       - bing
  echo       - mojeek
  echo       - searchmysite
  echo       - wiby
  echo       - presearch
  echo.
  echo general:
  echo   debug: false
  echo   instance_name: "SearXNG (local)"
  echo.
  echo search:
  echo   safe_search: 0
  echo   autocomplete: ''
  echo   ban_time_on_fail: 60
  echo   max_ban_time_on_fail: 3600
  echo   suspended_times:
  echo     SearxEngineAccessDenied: 3600
  echo     SearxEngineCaptcha: 21600
  echo     SearxEngineTooManyRequests: 3600
  echo   formats:
  echo     - html
  echo     - json
  echo     - rss
  echo.
  echo server:
  echo   base_url: %SEARXNG_BASE_URL%
  echo   bind_address: "%SEARXNG_BIND_ADDRESS%"
  echo   port: %SEARXNG_PORT%
  echo   secret_key: "!SECRET!"
  echo   limiter: false
  echo   public_instance: false
  echo   image_proxy: true
  echo   method: "GET"
  echo.
  echo outgoing:
  echo   retries: 0
  echo   pool_connections: 10
  echo   pool_maxsize: 2
  echo.
  echo engines:
  echo   - name: bing
  echo     disabled: false
  echo   - name: mojeek
  echo     disabled: false
  echo   - name: searchmysite
  echo     disabled: false
  echo   - name: wiby
  echo     disabled: false
  echo   - name: presearch
  echo     disabled: false
) > "%SEARXNG_SETTINGS_PATH%"

REM Generate the runner. The scheduled task invokes this .bat directly.
(
  echo @echo off
  echo setlocal
  echo cd /d "%SEARXNG_SRC%"
  echo set "SEARXNG_SETTINGS_PATH=%SEARXNG_SETTINGS_PATH%"
  echo set "SEARXNG_BIND_ADDRESS=%SEARXNG_BIND_ADDRESS%"
  echo set "SEARXNG_PORT=%SEARXNG_PORT%"
  echo set "SEARXNG_BASE_URL=%SEARXNG_BASE_URL%"
  echo set "GRANIAN_INTERFACE=wsgi"
  echo set "GRANIAN_HOST=%SEARXNG_BIND_ADDRESS%"
  echo set "GRANIAN_PORT=%SEARXNG_PORT%"
  echo set "GRANIAN_WEBSOCKETS=false"
  echo set "GRANIAN_WORKERS=1"
  echo set "GRANIAN_BLOCKING_THREADS=4"
  echo "%VENV_PY%" -m granian searx.webapp:app
) > "%RUNNER_PATH%"

REM Register the scheduled task. Try S4U (passwordless, runs whether logged
REM on or not) first; fall back to an interactive logon trigger if local
REM policy blocks the S4U registration.
schtasks /Delete /TN "%SERVICE_NAME%" /F >nul 2>&1
set "FALLBACK="
schtasks /Create /TN "%SERVICE_NAME%" /SC ONSTART ^
  /TR "\"%RUNNER_PATH%\"" /RU "%USER_ID%" /RL LIMITED /F >nul 2>&1
if errorlevel 1 (
  schtasks /Create /TN "%SERVICE_NAME%" /SC ONLOGON ^
    /TR "\"%RUNNER_PATH%\"" /RU "%USER_ID%" /RL LIMITED /F >nul
  if errorlevel 1 (
    echo failed to register scheduled task 1>&2
    exit /b 1
  )
  set "FALLBACK=1"
)

schtasks /Run /TN "%SERVICE_NAME%" >nul 2>&1

echo SearXNG ready
echo - source:   %SEARXNG_SRC%
echo - venv:     %SEARXNG_VENV%
echo - config:   %SEARXNG_SETTINGS_PATH%
echo - task:     %SERVICE_NAME%
echo - endpoint: %SEARXNG_BASE_URL%
if defined FALLBACK (
  echo WARNING: Windows blocked the passwordless S4U task. Fallback is 1>&2
  echo user-logon only: the task runs when you sign in but may stop after 1>&2
  echo full sign-out. 1>&2
)
endlocal
