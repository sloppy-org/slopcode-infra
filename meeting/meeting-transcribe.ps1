param(
  [Parameter(Mandatory=$true, Position=0)][string]$Audio,
  [string]$OutputRoot = $(if ($env:MEETING_OUTPUT_ROOT) { $env:MEETING_OUTPUT_ROOT } else { Join-Path $HOME "Meetings" }),
  [string]$MeetingName = "",
  [string]$Language = $(if ($env:WHISPER_LANGUAGE) { $env:WHISPER_LANGUAGE } else { "auto" }),
  [string]$BaseUrl = $(if ($env:WHISPER_BASE_URL) { $env:WHISPER_BASE_URL } else { "http://127.0.0.1:8427" }),
  [string]$Model = $(if ($env:WHISPER_MODEL) { $env:WHISPER_MODEL } else { "whisper-1" }),
  [int]$ChunkSeconds = $(if ($env:MEETING_CHUNK_SECONDS) { [int]$env:MEETING_CHUNK_SECONDS } else { 300 }),
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

function Read-Ascii([System.IO.BinaryReader]$Reader, [int]$Count) {
  [System.Text.Encoding]::ASCII.GetString($Reader.ReadBytes($Count))
}

function Get-PcmWavInfo([string]$Path) {
  $fs = [System.IO.File]::OpenRead($Path)
  try {
    $br = [System.IO.BinaryReader]::new($fs)
    if ((Read-Ascii $br 4) -ne "RIFF") { throw "not a RIFF WAV file" }
    $null = $br.ReadUInt32()
    if ((Read-Ascii $br 4) -ne "WAVE") { throw "not a WAVE file" }
    $fmtBytes = $null
    $dataStart = 0L
    $dataSize = 0L
    while ($fs.Position -lt $fs.Length) {
      $id = Read-Ascii $br 4
      $size = [int64]$br.ReadUInt32()
      $start = $fs.Position
      if ($id -eq "fmt ") {
        $fmtBytes = $br.ReadBytes([int]$size)
      } elseif ($id -eq "data") {
        $dataStart = $start
        $dataSize = $size
      }
      $fs.Position = $start + $size + ($size % 2)
    }
    if (-not $fmtBytes -or $dataStart -le 0 -or $dataSize -le 0) {
      throw "missing fmt or data chunk"
    }
    $fmtStream = [System.IO.MemoryStream]::new($fmtBytes)
    $fmtReader = [System.IO.BinaryReader]::new($fmtStream)
    $format = $fmtReader.ReadUInt16()
    $channels = $fmtReader.ReadUInt16()
    $sampleRate = $fmtReader.ReadUInt32()
    $byteRate = $fmtReader.ReadUInt32()
    $blockAlign = $fmtReader.ReadUInt16()
    $bits = $fmtReader.ReadUInt16()
    if ($format -ne 1) {
      throw "only PCM WAV can be chunked without extra codecs"
    }
    [pscustomobject]@{
      FormatBytes = $fmtBytes
      Channels = $channels
      SampleRate = [int64]$sampleRate
      ByteRate = [int64]$byteRate
      BlockAlign = [int64]$blockAlign
      BitsPerSample = $bits
      DataStart = [int64]$dataStart
      DataSize = [int64]$dataSize
      Duration = [double]$dataSize / [double]$byteRate
    }
  } finally {
    $fs.Dispose()
  }
}

function Write-WavChunk([string]$Source, [string]$Dest, $Info, [int64]$OffsetBytes, [int64]$CountBytes) {
  $inStream = [System.IO.File]::OpenRead($Source)
  $outStream = [System.IO.File]::Create($Dest)
  try {
    $reader = [System.IO.BinaryReader]::new($inStream)
    $writer = [System.IO.BinaryWriter]::new($outStream)
    $ascii = [System.Text.Encoding]::ASCII
    $riffSize = [uint32](4 + 8 + $Info.FormatBytes.Length + 8 + $CountBytes)
    $writer.Write($ascii.GetBytes("RIFF"))
    $writer.Write($riffSize)
    $writer.Write($ascii.GetBytes("WAVE"))
    $writer.Write($ascii.GetBytes("fmt "))
    $writer.Write([uint32]$Info.FormatBytes.Length)
    $writer.Write([byte[]]$Info.FormatBytes)
    $writer.Write($ascii.GetBytes("data"))
    $writer.Write([uint32]$CountBytes)
    $inStream.Position = $Info.DataStart + $OffsetBytes
    $remaining = $CountBytes
    $buffer = New-Object byte[] 1048576
    while ($remaining -gt 0) {
      $read = $reader.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
      if ($read -le 0) { break }
      $writer.Write($buffer, 0, $read)
      $remaining -= $read
    }
  } finally {
    $inStream.Dispose()
    $outStream.Dispose()
  }
}

function Invoke-Transcribe([string]$Path, [string]$Mime, [string]$OutJson) {
  $curlArgs = @(
    "-fsS", "--max-time", "3600",
    "$BaseUrl/v1/audio/transcriptions",
    "-F", "file=@${Path};type=$Mime",
    "-F", "model=$Model",
    "-F", "response_format=verbose_json"
  )
  if ($Language) {
    $curlArgs += @("-F", "language=$Language")
  }
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    & $curlCommand @curlArgs | Set-Content -Encoding UTF8 -LiteralPath "$OutJson.partial"
    if ($LASTEXITCODE -eq 0) {
      try {
        Get-Content -Raw -LiteralPath "$OutJson.partial" | ConvertFrom-Json | Out-Null
        Move-Item -Force -LiteralPath "$OutJson.partial" -Destination $OutJson
        return
      } catch {
      }
    }
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath "$OutJson.partial"
    Start-Sleep -Seconds ($attempt * 5)
  }
  throw "transcription failed for $Path"
}

function Merge-Transcripts($Rows, [string]$OutJson) {
  $segments = @()
  $textParts = @()
  $languageOut = "unknown"
  $durationOut = 0.0
  foreach ($row in $Rows) {
    $data = Get-Content -Raw -LiteralPath $row.Json | ConvertFrom-Json
    if ($data.text) { $textParts += $data.text.Trim() }
    if ($data.language) { $languageOut = $data.language }
    $durationOut = [Math]::Max($durationOut, [double]$row.Offset + [double]($data.duration ?? 0))
    foreach ($seg in @($data.segments)) {
      $copy = [ordered]@{}
      foreach ($prop in $seg.PSObject.Properties) {
        $copy[$prop.Name] = $prop.Value
      }
      $copy["start"] = [double]($copy["start"] ?? 0) + [double]$row.Offset
      $copy["end"] = [double]($copy["end"] ?? 0) + [double]$row.Offset
      $copy["id"] = $segments.Count
      $segments += [pscustomobject]$copy
    }
  }
  $merged = [ordered]@{
    text = ($textParts -join " ").Trim()
    language = $languageOut
    duration = $durationOut
    segments = $segments
  }
  $merged | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath $OutJson
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
$curlCommand = if ($IsWindows) { "curl.exe" } else { "curl" }
try {
  & $curlCommand -sS -m 3 -o $nullDevice -w "%{http_code}" "$BaseUrl/" | Out-Null
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
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
try {
  if ($mime -eq "audio/wav") {
    $info = Get-PcmWavInfo $audioItem.FullName
    $bytesPerChunk = [int64]([Math]::Floor(($ChunkSeconds * $info.ByteRate) / $info.BlockAlign) * $info.BlockAlign)
    if ($bytesPerChunk -le 0) { throw "chunk seconds must be positive" }
    $nChunks = [int][Math]::Ceiling($info.DataSize / [double]$bytesPerChunk)
    $rows = @()
    for ($i = 0; $i -lt $nChunks; $i++) {
      $offset = [int64]($i * $bytesPerChunk)
      $count = [int64][Math]::Min($bytesPerChunk, $info.DataSize - $offset)
      $chunk = Join-Path $tmpDir ("chunk_{0:0000}.wav" -f $i)
      $chunkJson = Join-Path $tmpDir ("chunk_{0:0000}.json" -f $i)
      Write-WavChunk $audioItem.FullName $chunk $info $offset $count
      [Console]::Error.WriteLine(("Transcribing chunk {0}/{1}" -f ($i + 1), $nChunks))
      Invoke-Transcribe $chunk "audio/wav" $chunkJson
      $rows += [pscustomobject]@{ Json = $chunkJson; Offset = [double]$offset / [double]$info.ByteRate }
    }
    Merge-Transcripts $rows $jsonOut
  } else {
    Invoke-Transcribe $audioItem.FullName $mime $jsonOut
  }
} catch {
  throw "transcription failed. For M4A, retry with a WAV file if ffmpeg is not installed for whisper-server."
} finally {
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -LiteralPath $tmpDir
}

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
