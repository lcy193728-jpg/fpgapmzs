param([Parameter(Mandatory=$true)][string]$RunPath,
 [string]$Top='tb_meeting_scene3',
 [string]$ModelSim='D:/altera/14.1/modelsim_ase/win32aloem/vsim.exe')
$ErrorActionPreference='Stop'
$meetingRoot=Split-Path $PSScriptRoot -Parent
$absoluteRun=(Resolve-Path -LiteralPath $RunPath).Path
$waveFile=Join-Path $absoluteRun 'meeting.wlf'
if(!(Test-Path -LiteralPath $waveFile)) { throw "No waveform: $waveFile" }
$env:MEETING_TOP=$Top
$env:MEETING_READY=Join-Path $absoluteRun 'gui.ready'
if(Test-Path -LiteralPath $env:MEETING_READY) { Remove-Item -LiteralPath $env:MEETING_READY }
$existingVish=@(Get-Process vish -ErrorAction SilentlyContinue | ForEach-Object Id)
$guiProcess=Start-Process -FilePath $ModelSim -ArgumentList '-view',('"'+$waveFile+'"'),'-do','tools/open_wave.do' -WorkingDirectory $meetingRoot -WindowStyle Hidden -PassThru
try {
 $deadline=(Get-Date).AddSeconds(55)
 while(!(Test-Path -LiteralPath $env:MEETING_READY) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
 if(!(Test-Path -LiteralPath $env:MEETING_READY)) { throw 'GUI did not finish loading the wave script; WLF retained.' }
 Start-Sleep -Milliseconds 1000
 & "$PSScriptRoot/capture_wave.ps1" -OutputPath (Join-Path $absoluteRun 'wave_full.png')
} finally {
 Stop-Process -Id $guiProcess.Id -ErrorAction SilentlyContinue
 Get-Process vish -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $existingVish } | Stop-Process -ErrorAction SilentlyContinue
}
