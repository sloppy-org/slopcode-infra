@echo off
setlocal
REM Run one non-editing OpenCode request against local llama.cpp.
REM Startup scripts launch this once in the background; comment that line to disable.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$ArgsList=@($args);" ^
  "$Check=$ArgsList -contains '--check';" ^
  "$Print=$ArgsList -contains '--print-fingerprint';" ^
  "$NoStart=$ArgsList -contains '--no-start';" ^
  "if($ArgsList -contains '-h' -or $ArgsList -contains '--help'){Write-Host 'Usage: llamacpp_prewarm_opencode.bat [--force] [--check] [--no-start] [--print-fingerprint]'; exit 0};" ^
  "$Port=if($env:LLAMACPP_PORT){$env:LLAMACPP_PORT}else{'8080'};" ^
  "$HostName=if($env:LLAMACPP_HOST -and $env:LLAMACPP_HOST -ne '0.0.0.0'){$env:LLAMACPP_HOST}else{'127.0.0.1'};" ^
  "$Base='http://'+$HostName+':'+$Port;" ^
  "$CacheRoot=if($env:LLAMACPP_CACHE_ROOT){$env:LLAMACPP_CACHE_ROOT} elseif(Test-Path (Join-Path $env:USERPROFILE 'slopcode')){Join-Path $env:USERPROFILE 'slopcode\cache'} else {Join-Path $env:LOCALAPPDATA 'llama.cpp'};" ^
  "$Manifest=Join-Path $CacheRoot 'opencode-prewarm.json';" ^
  "New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null;" ^
  "$Opencode=(Get-Command opencode -ErrorAction SilentlyContinue).Source;" ^
  "if(-not $Opencode){$Candidate=Join-Path $env:USERPROFILE 'slopcode\opencode\opencode.exe'; if(Test-Path $Candidate){$Opencode=$Candidate}};" ^
  "if(-not $Opencode){throw 'opencode not found on PATH or under %USERPROFILE%\slopcode\opencode'};" ^
  "$OcVersion=(& $Opencode --version 2>$null);" ^
  "$Watch=@($env:USERPROFILE+'\AGENTS.md',$env:USERPROFILE+'\.config\opencode\AGENTS.md',$env:USERPROFILE+'\.config\opencode\opencode.json',$env:USERPROFILE+'\.config\opencode\plugins',$env:USERPROFILE+'\.config\opencode\plugin',$env:USERPROFILE+'\.config\opencode\mcp',$env:USERPROFILE+'\.config\opencode\mcp.json',$env:APPDATA+'\Code\User\mcp.json');" ^
  "$Sha=[System.Security.Cryptography.SHA256]::Create();" ^
  "$Ms=New-Object System.IO.MemoryStream;" ^
  "$AddText={param($s) $b=[Text.Encoding]::UTF8.GetBytes($s+[char]0); $Ms.Write($b,0,$b.Length)};" ^
  "& $AddText 'slopcode-opencode-prewarm-v2'; & $AddText $OcVersion;" ^
  "foreach($Path in $Watch){if(Test-Path $Path){$Items=if(Test-Path $Path -PathType Leaf){@(Get-Item $Path)}else{Get-ChildItem -Path $Path -File -Recurse -ErrorAction SilentlyContinue | Where-Object {$_.FullName -notmatch '\\.git|node_modules|__pycache__'} | Sort-Object FullName}; foreach($Item in $Items){& $AddText $Item.FullName; $Bytes=[IO.File]::ReadAllBytes($Item.FullName); $Ms.Write($Bytes,0,$Bytes.Length)}}else{& $AddText ('missing '+$Path)}};" ^
  "$Hash=($Sha.ComputeHash($Ms.ToArray()) | ForEach-Object { $_.ToString('x2') }) -join '';" ^
  "if($Print){Write-Host $Hash; exit 0};" ^
  "$Old=''; if(Test-Path $Manifest){try{$Old=(Get-Content $Manifest -Raw | ConvertFrom-Json).fingerprint}catch{}};" ^
  "if($Check){if($Old -eq $Hash){Write-Host ('fresh: '+$Manifest); exit 0}else{Write-Host ('stale: '+$Manifest); exit 1}};" ^
  "$Ready=$false; try{Invoke-RestMethod -Uri ($Base+'/v1/models') -TimeoutSec 5 | Out-Null; $Ready=$true}catch{};" ^
  "if(-not $Ready -and -not $NoStart){$Run=Join-Path $env:USERPROFILE 'slopcode\run-llamacpp.bat'; if(Test-Path $Run){Start-Process -FilePath $Run}};" ^
  "$WaitSeconds=if($env:SLOPCODE_PREWARM_WAIT_TIMEOUT){[int]$env:SLOPCODE_PREWARM_WAIT_TIMEOUT}else{900};" ^
  "$Deadline=(Get-Date).AddSeconds($WaitSeconds);" ^
  "while(-not $Ready -and (Get-Date) -lt $Deadline){Start-Sleep -Seconds 2; try{Invoke-RestMethod -Uri ($Base+'/v1/models') -TimeoutSec 5 | Out-Null; $Ready=$true}catch{}};" ^
  "if(-not $Ready){throw ('llama-server did not become ready at '+$Base)};" ^
  "$Tmp=New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('slopcode-opencode-prewarm-'+[guid]::NewGuid()));" ^
  "Set-Content -Encoding UTF8 -Path (Join-Path $Tmp.FullName 'README.md') -Value 'Temporary project for slopcode OpenCode prompt-cache prewarm.';" ^
  "$Prompt=if($env:SLOPCODE_PREWARM_PROMPT){$env:SLOPCODE_PREWARM_PROMPT}else{'Reply with exactly SLOPCODE_PREWARM_READY. Do not edit files.'};" ^
  "$Model=if($env:SLOPCODE_PREWARM_MODEL){$env:SLOPCODE_PREWARM_MODEL}else{'llamacpp/qwen'};" ^
  "Write-Host ('running OpenCode prewarm ('+$Model+')...'); & $Opencode run --model $Model --dir $Tmp.FullName $Prompt *> (Join-Path $env:TEMP 'slopcode-opencode-prewarm.log');" ^
  "Remove-Item -Recurse -Force $Tmp.FullName;" ^
  "$Data=[ordered]@{fingerprint=$Hash; created_at=(Get-Date).ToUniversalTime().ToString('o'); opencode_version=$OcVersion; watch_paths=$Watch; base_url=$Base};" ^
  "$Data | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $Manifest;" ^
  "Write-Host ('prewarm complete: '+$Manifest)" ^
  %*

exit /b %ERRORLEVEL%
