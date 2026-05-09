# SearXNG on Windows as a user-level scheduled task.
#
# This script keeps everything inside the user's profile, binds only
# 127.0.0.1:8888, and uses Task Scheduler so the service comes back after
# reboot. The preferred principal is S4U ("run whether logged on or not"
# without admin). If the local policy blocks S4U, the script falls back to an
# interactive logon task and prints the limitation plainly.

$ErrorActionPreference = 'Stop'

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "missing required command: $Name"
    }
}

Require-Command git

$Python = if (Get-Command py -ErrorAction SilentlyContinue) { 'py' } elseif (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { throw 'python or py is required' }
$PythonArgs = if ($Python -eq 'py') { @('-3') } else { @() }

$SearxngHome = if ($env:SEARXNG_HOME) { $env:SEARXNG_HOME } else { Join-Path $env:LOCALAPPDATA 'slopcode\searxng' }
$SearxngSrc = if ($env:SEARXNG_SRC) { $env:SEARXNG_SRC } else { Join-Path $SearxngHome 'src' }
$SearxngVenv = if ($env:SEARXNG_VENV) { $env:SEARXNG_VENV } else { Join-Path $SearxngHome '.venv' }
$SettingsDir = if ($env:SEARXNG_SETTINGS_DIR) { $env:SEARXNG_SETTINGS_DIR } else { Join-Path $env:APPDATA 'searxng' }
$SettingsPath = if ($env:SEARXNG_SETTINGS_PATH) { $env:SEARXNG_SETTINGS_PATH } else { Join-Path $SettingsDir 'settings.yml' }
$BindAddress = if ($env:SEARXNG_BIND_ADDRESS) { $env:SEARXNG_BIND_ADDRESS } else { '127.0.0.1' }
$Port = if ($env:SEARXNG_PORT) { $env:SEARXNG_PORT } else { '8888' }
$BaseUrl = if ($env:SEARXNG_BASE_URL) { $env:SEARXNG_BASE_URL } else { "http://127.0.0.1:$Port" }
$TaskName = if ($env:SERVICE_NAME) { $env:SERVICE_NAME } else { 'slopcode-searxng' }
$RunnerPath = Join-Path $SearxngHome 'run-searxng.ps1'
$UserId = if ($env:USERDOMAIN) { "$($env:USERDOMAIN)\$($env:USERNAME)" } else { $env:USERNAME }
$SearxngRef = if ($env:SEARXNG_REF) { $env:SEARXNG_REF } else { 'master' }

New-Item -ItemType Directory -Force -Path $SearxngHome, $SettingsDir | Out-Null

if (-not (Test-Path (Join-Path $SearxngSrc '.git'))) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SearxngSrc) | Out-Null
    & git clone https://github.com/searxng/searxng.git $SearxngSrc
}

Push-Location $SearxngSrc
& git fetch --all --tags --prune --quiet
& git checkout $SearxngRef
try {
    & git pull --ff-only --quiet
} catch {
}
Pop-Location

& $Python @PythonArgs -m venv $SearxngVenv
$VenvPython = Join-Path $SearxngVenv 'Scripts\python.exe'
$VenvPip = Join-Path $SearxngVenv 'Scripts\pip.exe'
if (-not (Test-Path $VenvPython)) {
    throw "virtualenv python missing: $VenvPython"
}

& $VenvPip install -U pip setuptools wheel pyyaml msgspec typing-extensions pybind11 granian | Out-Null
& $VenvPip install --use-pep517 --no-build-isolation -e $SearxngSrc | Out-Null

$Secret = $env:SEARXNG_SECRET
if (-not $Secret -and (Test-Path $SettingsPath)) {
    $match = Select-String -Path $SettingsPath -Pattern 'secret_key:\s*"([^"]+)"' | Select-Object -First 1
    if ($match) { $Secret = $match.Matches[0].Groups[1].Value }
}
if (-not $Secret) {
    $Secret = & $VenvPython -c 'import secrets; print(secrets.token_urlsafe(32))'
}

@"
use_default_settings: true

general:
  debug: false
  instance_name: "SearXNG (local)"

search:
  safe_search: 0
  autocomplete: 'duckduckgo'
  formats:
    - html
    - json
    - rss

server:
  base_url: $BaseUrl
  bind_address: "$BindAddress"
  port: $Port
  secret_key: "$Secret"
  limiter: false
  public_instance: false
  image_proxy: true
  method: "GET"
"@ | Set-Content -NoNewline -Path $SettingsPath

@"
`$ErrorActionPreference = 'Stop'
Set-Location '$SearxngSrc'
`$env:SEARXNG_SETTINGS_PATH = '$SettingsPath'
`$env:SEARXNG_BIND_ADDRESS = '$BindAddress'
`$env:SEARXNG_PORT = '$Port'
`$env:SEARXNG_BASE_URL = '$BaseUrl'
`$env:GRANIAN_INTERFACE = 'wsgi'
`$env:GRANIAN_HOST = '$BindAddress'
`$env:GRANIAN_PORT = '$Port'
`$env:GRANIAN_WEBSOCKETS = 'false'
`$env:GRANIAN_WORKERS = '1'
`$env:GRANIAN_BLOCKING_THREADS = '4'
& '$VenvPython' -m granian searx.webapp:app
"@ | Set-Content -NoNewline -Path $RunnerPath

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$RunnerPath`""
$Triggers = @(
    New-ScheduledTaskTrigger -AtStartup,
    New-ScheduledTaskTrigger -AtLogOn -User $UserId
)
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

$FallbackNote = $null
try {
    $Principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType S4U -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Triggers -Principal $Principal -Settings $Settings -Force | Out-Null
} catch {
    $Principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType InteractiveToken -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Triggers[1] -Principal $Principal -Settings $Settings -Force | Out-Null
    $FallbackNote = 'Windows blocked the passwordless S4U task. Fallback is user-logon only: it restarts on login, but Windows may stop it after full sign-out.'
}

Start-ScheduledTask -TaskName $TaskName

Write-Output "SearXNG ready"
Write-Output "- source:   $SearxngSrc"
Write-Output "- venv:     $SearxngVenv"
Write-Output "- config:   $SettingsPath"
Write-Output "- task:     $TaskName"
Write-Output "- endpoint: $BaseUrl"
if ($FallbackNote) {
    Write-Warning $FallbackNote
}
