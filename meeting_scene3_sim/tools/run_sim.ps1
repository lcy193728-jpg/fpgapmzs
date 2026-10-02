param([string]$ModelSim='D:/altera/14.1/modelsim_ase/win32aloem/vsim.exe')
$ErrorActionPreference='Stop'
$meetingRoot=Split-Path $PSScriptRoot -Parent
Push-Location $meetingRoot
try {
 $tests=@(
  @{Top='tb_meeting_scene3';Script='run.do';Name='full'},
  @{Top='tb_meeting_edges';Script='run_checks.do';Name='edges'},
  @{Top='tb_meeting_io';Script='run_checks.do';Name='io'},
  @{Top='tb_meeting_display';Script='run_display.do';Name='display'}
 )
 foreach($test in $tests) {
  $env:MEETING_RUN='runs/'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff')+'_'+$test.Name
  $env:MEETING_TB=$test.Top
  New-Item -ItemType Directory -Force $env:MEETING_RUN | Out-Null
  Write-Host "Running $($test.Top): $env:MEETING_RUN"
  & $ModelSim -c -l "$env:MEETING_RUN/transcript.log" -do $test.Script
  $simulationExit=$LASTEXITCODE
  $wavePath=Join-Path $env:MEETING_RUN 'meeting.wlf'
  if(Test-Path -LiteralPath $wavePath) { & "$PSScriptRoot/save_wave.ps1" -RunPath $env:MEETING_RUN -Top $test.Top -ModelSim $ModelSim }
  $transcriptText=Get-Content -LiteralPath "$env:MEETING_RUN/transcript.log" -Raw
  if($simulationExit -ne 0 -or $transcriptText -notmatch 'ALL TESTS PASSED' -or $transcriptText -match '# FAIL') { throw "Simulation failed; evidence retained in $env:MEETING_RUN" }
 }
} finally { Pop-Location }
