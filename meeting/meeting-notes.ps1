param(
  [Parameter(Mandatory=$true, Position=0)][string]$Target,
  [string]$Output = "",
  [string[]]$ContextFile = @(),
  [string[]]$ContextDir = @(),
  [ValidateSet("en", "de", "match")][string]$Language = "match",
  [string]$Model = $(if ($env:OPENCODE_MODEL) { $env:OPENCODE_MODEL } else { "llamacpp/qwen" }),
  [switch]$Force
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $true
}
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (Test-Path -LiteralPath $Target -PathType Container) {
  $meetingDir = (Get-Item -LiteralPath $Target).FullName
  $transcript = Join-Path $meetingDir "transcript.txt"
} else {
  $transcript = (Get-Item -LiteralPath $Target).FullName
  $meetingDir = Split-Path -Parent $transcript
}
if (-not (Test-Path -LiteralPath $transcript)) {
  throw "transcript.txt not found: $transcript"
}
if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
  throw "missing required command: opencode"
}

$metadata = Join-Path $meetingDir "metadata.json"
$transcriptJson = Join-Path $meetingDir "transcript.json"
if (-not $Output) { $Output = Join-Path $meetingDir "MEETING_NOTES.md" }
if ((Test-Path -LiteralPath $Output) -and -not $Force) {
  throw "note exists at $Output; use -Force to overwrite"
}

$instruction = switch ($Language) {
  "en" { "Write the note in English and use the English template labels." }
  "de" { "Write the note in German and use the German template labels." }
  "match" {
    $detected = ""
    if (Test-Path -LiteralPath $transcriptJson) {
      $detected = (Get-Content -Raw -LiteralPath $transcriptJson | ConvertFrom-Json).language
    }
    if ($detected -eq "de") {
      "Write the note in German and use the German template labels."
    } elseif ($detected -eq "en") {
      "Write the note in English and use the English template labels."
    } else {
      "Infer the dominant meeting language from the transcript. Write in that language, using German labels for German and English labels for English."
    }
  }
}

$files = @()
foreach ($file in $ContextFile) {
  $files += (Get-Item -LiteralPath $file).FullName
}
foreach ($dir in $ContextDir) {
  Get-ChildItem -LiteralPath $dir -File |
    Where-Object { $_.Name -notin @("MEETING_NOTES.md", "transcript.txt", "transcript.json", "metadata.json", ".DS_Store") } |
    Sort-Object Name |
    ForEach-Object { $files += $_.FullName }
}
$contextList = if ($files.Count) { $files -join "`n" } else { "none" }
$metadataText = if (Test-Path -LiteralPath $metadata) { Get-Content -Raw -LiteralPath $metadata } else { "{}" }

$prompt = [System.IO.Path]::GetTempFileName()
$response = [System.IO.Path]::GetTempFileName()
@"
Generate concise but complete meeting notes from the supplied transcript.

Constraints:
- $instruction
- Use explicit context files only when they clarify the transcript or meeting outcome. The transcript remains authoritative for what was actually said.
- The transcript may contain Whisper errors, repeated loops, bad punctuation, homophones, and mixed German/English technical terms.
- Correct obvious transcription mistakes only when context strongly supports the correction.
- Infer participants conservatively. A person discussed in the meeting is not automatically present.
- Separate decisions, tasks, open questions, and topic walkthrough.
- Assign tasks to named owners only when the transcript supports ownership.
- Use markdown checkboxes for action items.
- Output only the final markdown note. No preamble, no explanation, no code fence.

Template:
$(Get-Content -Raw -LiteralPath (Join-Path $scriptDir "meeting-notes-template.md"))

Metadata JSON:
$metadataText

Explicit context files:
$contextList

Transcript:
$(Get-Content -Raw -LiteralPath $transcript)
"@ | Set-Content -Encoding UTF8 -LiteralPath $prompt

$opencodeArgs = @("run", "--model", $Model, "--file", $prompt)
foreach ($file in $files) {
  $opencodeArgs += @("--file", $file)
}
$opencodeArgs += "Follow the attached prompt exactly and output only the meeting note markdown."
& opencode @opencodeArgs | Set-Content -Encoding UTF8 -LiteralPath $response
if ($LASTEXITCODE -ne 0) {
  throw "opencode failed while generating meeting notes"
}
if (-not (Test-Path -LiteralPath $response) -or (Get-Item -LiteralPath $response).Length -eq 0) {
  throw "opencode produced no meeting note"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null
Copy-Item -Force -LiteralPath $response -Destination $Output
Write-Output $Output
Remove-Item -Force -LiteralPath $prompt, $response
