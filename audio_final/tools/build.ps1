param([Parameter(Mandatory=$true)][string]$TdRoot)
$ErrorActionPreference='Stop'
$taskRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$taskExe=Join-Path $TdRoot 'bin\td_commands_prompt.exe'
if(!(Test-Path -LiteralPath $taskExe)){throw "TD executable missing: $taskExe"}
$taskLogDir=Join-Path $taskRoot 'audio_final\build'
New-Item -ItemType Directory -Force -Path $taskLogDir | Out-Null
# TD resolves logical-BRAM initialization files from its run directory.
Copy-Item -LiteralPath (Join-Path $taskRoot 'audio_final\assets\alarm_4k_adpcm.dath') -Destination (Join-Path $taskLogDir 'alarm_4k_adpcm.dath') -Force
$taskAsset=(Resolve-Path (Join-Path $taskRoot 'audio_final\assets\alarm_4k_adpcm.dath')).Path.Replace('\','/')
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
Write-Output (Select-String -LiteralPath $taskLog -SimpleMatch 'FINAL_AUDIO_BUILD_COMPLETE:').Line
