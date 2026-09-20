param([Parameter(Mandatory=$true)][string]$TdRoot)
$ErrorActionPreference='Stop'
$taskRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$taskExe=Join-Path $TdRoot 'bin\td_commands_prompt.exe'
if(!(Test-Path -LiteralPath $taskExe)){throw "TD executable missing: $taskExe"}
$taskLogDir=Join-Path $taskRoot 'audio_final\build'
New-Item -ItemType Directory -Force -Path $taskLogDir | Out-Null
# TD requires an absolute path for logical-BRAM initialization files.
Copy-Item -LiteralPath (Join-Path $taskRoot 'audio_final\assets\alarm_3k_pcm8.dath') -Destination (Join-Path $taskLogDir 'alarm_3k_pcm8.dath') -Force
$taskAsset=(Resolve-Path (Join-Path $taskRoot 'audio_final\assets\alarm_3k_pcm8.dath')).Path.Replace('\','/')
$taskHeader=Join-Path $taskRoot 'audio_final\rtl\alarm_init_path.vh'
[IO.File]::WriteAllText($taskHeader,('`define ALARM_INIT_FILE "'+$taskAsset+'"'+[Environment]::NewLine),[Text.Encoding]::ASCII)
$taskTcl=(Join-Path $PSScriptRoot 'build_td.tcl').Replace('\','/')
$taskLog=Join-Path $taskLogDir 'build-output.txt'
& $taskExe $taskTcl *> $taskLog
if($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath $taskLog -SimpleMatch 'FINAL_AUDIO_BUILD_COMPLETE:')){
  Get-Content -LiteralPath $taskLog -Tail 50
  throw "TD build failed; inspect $taskLog"
}
$taskTiming=Join-Path $taskLogDir 'pic_sdram_audio_final_pr.timing'
if(!(Test-Path -LiteralPath $taskTiming)){throw "Missing routed timing report: $taskTiming"}
$taskText=[IO.File]::ReadAllText($taskTiming)
foreach($taskMetric in @('SWNS','HWNS')){
  $taskMatch=[regex]::Match($taskText,"$taskMetric`: *(-?[0-9.]+)ns")
  if(!$taskMatch.Success){throw "Cannot read $taskMetric from routed timing report"}
  $taskSlack=[double]::Parse($taskMatch.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
  if($taskSlack -lt 0){throw "$taskMetric=$taskSlack ns; do not download this build"}
  Write-Output "$taskMetric=$taskSlack ns"
}
$taskBit=Join-Path $taskLogDir 'pic_sdram_audio_final.bit'
if(!(Test-Path -LiteralPath $taskBit)){throw "Missing generated bitstream: $taskBit"}
$taskArtifacts=Join-Path $taskRoot 'audio_final\artifacts'
$taskReports=Join-Path $taskRoot 'audio_final\reports'
New-Item -ItemType Directory -Force -Path $taskArtifacts,$taskReports | Out-Null
$taskArtifactBit=Join-Path $taskArtifacts 'pic_sdram_audio_final.bit'
Copy-Item -LiteralPath $taskBit -Destination $taskArtifactBit -Force
Copy-Item -LiteralPath $taskLog -Destination (Join-Path $taskReports 'build-output.txt') -Force
Copy-Item -LiteralPath (Join-Path $taskLogDir 'pic_sdram_audio_final_phy.area') -Destination $taskReports -Force
Copy-Item -LiteralPath $taskTiming -Destination $taskReports -Force
$taskHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $taskArtifactBit).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $taskArtifacts 'SHA256SUMS.txt'),
  "$taskHash  pic_sdram_audio_final.bit`n",[Text.Encoding]::ASCII)
Write-Output "FINAL_AUDIO_BUILD_COMPLETE: $taskArtifactBit"
Write-Output "SHA256=$taskHash"
