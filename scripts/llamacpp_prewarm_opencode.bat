@echo off
setlocal
REM Build or refresh the llama-server slot cache for OpenCode on Windows.
REM Re-run with --force after AGENTS.md, OpenCode, or MCP plugin changes.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$ArgsList=@($args);" ^
  "$Force=$ArgsList -contains '--force';" ^
  "$Check=$ArgsList -contains '--check';" ^
  "$Print=$ArgsList -contains '--print-fingerprint';" ^
  "$NoStart=$ArgsList -contains '--no-start';" ^
  "if($ArgsList -contains '-h' -or $ArgsList -contains '--help'){Write-Host 'Usage: llamacpp_prewarm_opencode.bat [--force] [--check] [--no-start] [--print-fingerprint]'; exit 0};" ^
  "$Port=if($env:LLAMACPP_PORT){$env:LLAMACPP_PORT}else{'8080'};" ^
  "$HostName=if($env:LLAMACPP_HOST -and $env:LLAMACPP_HOST -ne '0.0.0.0'){$env:LLAMACPP_HOST}else{'127.0.0.1'};" ^
  "$Base='http://'+$HostName+':'+$Port;" ^
  "$SlotId=if($env:LLAMACPP_RESTORE_SLOT_ID){$env:LLAMACPP_RESTORE_SLOT_ID}else{'0'};" ^
  "$SlotFile=if($env:LLAMACPP_RESTORE_SLOT_FILE){$env:LLAMACPP_RESTORE_SLOT_FILE}else{'opencode-prewarm-slot.bin'};" ^
  "$DefaultSlotDir=Join-Path $env:USERPROFILE 'slopcode\cache\slots';" ^
  "if(-not (Test-Path (Split-Path -Parent $DefaultSlotDir))){$DefaultSlotDir=Join-Path $env:LOCALAPPDATA 'llama.cpp\slots'};" ^
  "$SlotDir=if($env:LLAMACPP_SLOT_SAVE_PATH){$env:LLAMACPP_SLOT_SAVE_PATH}else{$DefaultSlotDir};" ^
  "$Manifest=Join-Path $SlotDir ($SlotFile+'.manifest.json');" ^
  "New-Item -ItemType Directory -Force -Path $SlotDir | Out-Null;" ^
  "$Opencode=(Get-Command opencode -ErrorAction SilentlyContinue).Source;" ^
  "if(-not $Opencode){$Candidate=Join-Path $env:USERPROFILE 'slopcode\opencode\opencode.exe'; if(Test-Path $Candidate){$Opencode=$Candidate}};" ^
  "if(-not $Opencode){throw 'opencode not found on PATH or under %USERPROFILE%\slopcode\opencode'};" ^
  "$OcVersion=(& $Opencode --version 2>$null);" ^
  "$Watch=@($env:USERPROFILE+'\AGENTS.md',$env:USERPROFILE+'\.config\opencode\AGENTS.md',$env:USERPROFILE+'\.config\opencode\opencode.json',$env:USERPROFILE+'\.config\opencode\plugins',$env:USERPROFILE+'\.config\opencode\plugin',$env:USERPROFILE+'\.config\opencode\mcp',$env:USERPROFILE+'\.config\opencode\mcp.json',$env:APPDATA+'\Code\User\mcp.json');" ^
  "$Sha=[System.Security.Cryptography.SHA256]::Create();" ^
  "$Ms=New-Object System.IO.MemoryStream;" ^
  "$AddText={param($s) $b=[Text.Encoding]::UTF8.GetBytes($s+[char]0); $Ms.Write($b,0,$b.Length)};" ^
  "& $AddText 'slopcode-opencode-prewarm-v1'; & $AddText $OcVersion;" ^
  "foreach($Path in $Watch){if(Test-Path $Path){$Items=if(Test-Path $Path -PathType Leaf){@(Get-Item $Path)}else{Get-ChildItem -Path $Path -File -Recurse -ErrorAction SilentlyContinue | Where-Object {$_.FullName -notmatch '\\.git|node_modules|__pycache__'} | Sort-Object FullName}; foreach($Item in $Items){& $AddText $Item.FullName; $Bytes=[IO.File]::ReadAllBytes($Item.FullName); $Ms.Write($Bytes,0,$Bytes.Length)}}else{& $AddText ('missing '+$Path)}};" ^
  "$Hash=($Sha.ComputeHash($Ms.ToArray()) | ForEach-Object { $_.ToString('x2') }) -join '';" ^
  "if($Print){Write-Host $Hash; exit 0};" ^
  "$Old=''; if(Test-Path $Manifest){try{$Old=(Get-Content $Manifest -Raw | ConvertFrom-Json).fingerprint}catch{}};" ^
  "$SlotPath=Join-Path $SlotDir $SlotFile;" ^
  "if($Check){if((Test-Path $SlotPath) -and $Old -eq $Hash){Write-Host ('fresh: '+$SlotPath); exit 0}else{Write-Host ('stale: '+$SlotPath); exit 1}};" ^
  "if((Test-Path $SlotPath) -and $Old -eq $Hash -and -not $Force){Write-Host ('prewarm cache already fresh: '+$SlotPath); exit 0};" ^
  "$Ready=$false; try{Invoke-RestMethod -Uri ($Base+'/v1/models') -TimeoutSec 5 | Out-Null; $Ready=$true}catch{};" ^
  "if(-not $Ready){if($NoStart){throw ('llama-server is not ready at '+$Base)}; $Run=Join-Path $env:USERPROFILE 'slopcode\run-llamacpp.bat'; if(Test-Path $Run){Start-Process -FilePath $Run}else{throw ('llama-server is not ready at '+$Base)}};" ^
  "for($i=0;$i -lt 180 -and -not $Ready;$i++){Start-Sleep -Seconds 2; try{Invoke-RestMethod -Uri ($Base+'/v1/models') -TimeoutSec 5 | Out-Null; $Ready=$true}catch{}};" ^
  "if(-not $Ready){throw ('llama-server did not become ready at '+$Base)};" ^
  "$Tmp=New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('slopcode-opencode-prewarm-'+[guid]::NewGuid()));" ^
  "Set-Content -Encoding UTF8 -Path (Join-Path $Tmp.FullName 'README.md') -Value 'Temporary project for slopcode OpenCode prompt-cache prewarm.';" ^
  "$Prompt=if($env:SLOPCODE_PREWARM_PROMPT){$env:SLOPCODE_PREWARM_PROMPT}else{'Reply with exactly SLOPCODE_PREWARM_READY. Do not edit files.'};" ^
  "$Model=if($env:SLOPCODE_PREWARM_MODEL){$env:SLOPCODE_PREWARM_MODEL}else{'llamacpp/qwen'};" ^
  "Write-Host ('running OpenCode prewarm ('+$Model+')...'); & $Opencode run --model $Model --dir $Tmp.FullName $Prompt *> (Join-Path $env:TEMP 'slopcode-opencode-prewarm.log');" ^
  "Remove-Item -Recurse -Force $Tmp.FullName;" ^
  "Write-Host ('saving slot '+$SlotId+' to '+$SlotPath+'...');" ^
  "$Body=@{filename=$SlotFile}|ConvertTo-Json -Compress;" ^
  "$Resp=Invoke-RestMethod -Method Post -Uri ($Base+'/slots/'+$SlotId+'?action=save') -ContentType 'application/json' -Body $Body -TimeoutSec 120;" ^
  "$Data=[ordered]@{fingerprint=$Hash; created_at=(Get-Date).ToUniversalTime().ToString('o'); opencode_version=$OcVersion; watch_paths=$Watch};" ^
  "$Data | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $Manifest;" ^
  "Write-Host ('prewarm cache saved: '+$SlotPath)" ^
  %*

exit /b %ERRORLEVEL%
