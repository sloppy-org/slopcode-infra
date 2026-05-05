param(
  [Parameter(Mandatory=$true, Position=0)][string]$Audio,
  [string]$OutputRoot = $(if ($env:MEETING_OUTPUT_ROOT) { $env:MEETING_OUTPUT_ROOT } else { Join-Path $HOME "Meetings" }),
  [string]$MeetingName = "",
  [string]$Language = $(if ($env:WHISPER_LANGUAGE) { $env:WHISPER_LANGUAGE } else { "auto" }),
  [string]$NotesLanguage = "match",
  [string[]]$ContextFile = @(),
  [string[]]$ContextDir = @(),
  [string]$Model = $(if ($env:OPENCODE_MODEL) { $env:OPENCODE_MODEL } else { "llamacpp/qwen" }),
  [switch]$Force
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $true
}
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$transcribeArgs = @{
  Audio = $Audio
  OutputRoot = $OutputRoot
  MeetingName = $MeetingName
  Language = $Language
  Force = $Force
}
$meetingDir = & (Join-Path $scriptDir "meeting-transcribe.ps1") @transcribeArgs

$notesArgs = @{
  Target = $meetingDir
  Language = $NotesLanguage
  ContextFile = $ContextFile
  ContextDir = $ContextDir
  Model = $Model
  Force = $Force
}
& (Join-Path $scriptDir "meeting-notes.ps1") @notesArgs
