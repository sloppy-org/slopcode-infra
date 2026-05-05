param(
  [Parameter(Mandatory=$true, Position=0)][string]$Audio,
  [string]$OutputRoot = $(if ($env:MEETING_OUTPUT_ROOT) { $env:MEETING_OUTPUT_ROOT } else { Join-Path $HOME "Meetings" }),
  [string]$MeetingName = "",
  [string]$Language = $(if ($env:WHISPER_LANGUAGE) { $env:WHISPER_LANGUAGE } else { "auto" }),
  [string]$BaseUrl = $(if ($env:WHISPER_BASE_URL) { $env:WHISPER_BASE_URL } else { "http://127.0.0.1:8427" }),
  [string]$Model = $(if ($env:WHISPER_MODEL) { $env:WHISPER_MODEL } else { "whisper-1" }),
  [switch]$Force
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $true
}

function Slug([string]$Text) {
  $s = $Text.ToLowerInvariant() -replace '\.[^.]+$', ''
  $s = $s -replace '[^a-z0-9]+', '_'
  $s = $s -replace '^_+', '' -replace '_+$', '' -replace '__+', '_'
  if ($s) { $s } else { "meeting" }
}

$audioItem = Get-Item -LiteralPath $Audio
$ext = $audioItem.Extension.ToLowerInvariant()
if ($ext -eq ".wav") {
  $mime = "audio/wav"
} elseif ($ext -eq ".m4a") {
  $mime = "audio/mp4"
} else {
  throw "unsupported audio type. Use WAV, or M4A when whisper-server conversion is available."
}

$BaseUrl = $BaseUrl.TrimEnd("/")
$nullDevice = if ($IsWindows) { "NUL" } else { "/dev/null" }
try {
  curl.exe -sS -m 3 -o $nullDevice -w "%{http_code}" "$BaseUrl/" | Out-Null
} catch {
  throw "whisper-server unreachable at $BaseUrl"
}
if ($LASTEXITCODE -ne 0) {
  throw "whisper-server unreachable at $BaseUrl"
}

$recorded = $audioItem.LastWriteTime
$recordedDate = $recorded.ToString("yyyy-MM-dd")
$recordedTime = $recorded.ToString("HHmmss")
$stem = [System.IO.Path]::GetFileNameWithoutExtension($audioItem.Name)
$name = if ($MeetingName) { $MeetingName } else { "${recordedTime}_${stem}" }
$meetingDir = Join-Path $OutputRoot ("${recordedDate}_" + (Slug $name))
New-Item -ItemType Directory -Force -Path $meetingDir | Out-Null

$jsonOut = Join-Path $meetingDir "transcript.json"
$txtOut = Join-Path $meetingDir "transcript.txt"
$metadataOut = Join-Path $meetingDir "metadata.json"
if ((Test-Path $jsonOut) -and -not $Force) {
  throw "transcript exists in $meetingDir; use -Force to overwrite"
}

$partial = "$jsonOut.partial"
$curlArgs = @(
  "-fsS", "--max-time", "7200",
  "$BaseUrl/v1/audio/transcriptions",
  "-F", "file=@$($audioItem.FullName);type=$mime",
  "-F", "model=$Model",
  "-F", "response_format=verbose_json"
)
if ($Language) {
  $curlArgs += @("-F", "language=$Language")
}

& curl.exe @curlArgs | Set-Content -Encoding UTF8 -LiteralPath $partial
if ($LASTEXITCODE -ne 0) {
  throw "transcription failed. For M4A, retry with a WAV file if ffmpeg is not installed for whisper-server."
}
Get-Content -Raw -LiteralPath $partial | ConvertFrom-Json | Out-Null
Move-Item -Force -LiteralPath $partial -Destination $jsonOut

$data = Get-Content -Raw -LiteralPath $jsonOut | ConvertFrom-Json
$text = $data.text
if (-not $text -and $data.segments) {
  $text = ($data.segments | ForEach-Object { $_.text.Trim() } | Where-Object { $_ }) -join " "
}
Set-Content -Encoding UTF8 -LiteralPath $txtOut -Value ($text.Trim() + "`n")

$metadata = [ordered]@{
  source_file = $audioItem.FullName
  source_file_name = $audioItem.Name
  recorded_date = $recordedDate
  recorded_time = $recordedTime
  meeting_language_mode = $Language
  detected_language = $data.language
  whisper_request = [ordered]@{
    base_url = $BaseUrl
    model = $Model
    language = $Language
  }
}
$metadata | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -LiteralPath $metadataOut
Write-Output $meetingDir
