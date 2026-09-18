param(
    [Parameter(Mandatory=$true)][string]$TdRoot,
    [ValidateSet('tone','integrated')][string]$Target='tone'
)
$ErrorActionPreference='Stop'
$taskBoardRoot=Split-Path -Parent $PSScriptRoot
$taskTdExe=Join-Path $TdRoot 'bin\td_commands_prompt.exe'
if(!(Test-Path -LiteralPath $taskTdExe)){throw "TD executable missing: $taskTdExe"}
$taskLogDir=Join-Path $taskBoardRoot "build\$Target"
New-Item -ItemType Directory -Path $taskLogDir -Force | Out-Null
$taskScript=(Join-Path $PSScriptRoot 'build_td.tcl').Replace('\','/')
$env:AUDIO_TARGET=$Target
$taskLog=Join-Path $taskLogDir 'build-output.txt'
& $taskTdExe $taskScript *> $taskLog
$taskExit=$LASTEXITCODE
$taskMarker=Select-String -LiteralPath $taskLog -SimpleMatch 'AUDIO_BUILD_COMPLETE:'
if($taskExit -ne 0 -or !$taskMarker){
    Get-Content -LiteralPath $taskLog -Tail 35
    throw "TD did not complete bitgen. Inspect $taskLog"
}
$taskMarker.Line
$taskReportName=if($Target -eq 'tone'){'hdmi_tone_pr.timing'}else{'pic_sdram_audio_pr.timing'}
$taskTiming=[System.IO.File]::ReadAllText((Join-Path $taskLogDir $taskReportName))
foreach($taskTimingMetric in @('SWNS','HWNS')){
    $taskMatch=[regex]::Match($taskTiming,"$taskTimingMetric`: *(-?[0-9.]+)ns")
    if(!$taskMatch.Success){throw "Cannot read $taskTimingMetric from routed timing report."}
    $taskSlack=[double]::Parse($taskMatch.Groups[1].Value,[System.Globalization.CultureInfo]::InvariantCulture)
    if($taskSlack -lt 0){throw "Bitgen finished, but $taskTimingMetric=$taskSlack ns. Do not download this build."}
    Write-Output "$taskTimingMetric=$taskSlack ns"
}
Write-Output "Log: $taskLog"
