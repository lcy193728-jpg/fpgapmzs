param(
    [Parameter(Mandatory=$true)][string]$TdRoot,
    [Parameter(Mandatory=$true)][string]$BitFile,
    [ValidateSet('jtag','program_spi')][string]$Mode='jtag',
    [int]$Cable=0
)
$ErrorActionPreference='Stop'
$taskDownloadExe=Join-Path $TdRoot 'bin\bw_commands_prompt.exe'
if(!(Test-Path -LiteralPath $taskDownloadExe)){throw "Downloader missing: $taskDownloadExe"}
$taskBitPath=(Resolve-Path -LiteralPath $BitFile).Path.Replace('\','/')
if($taskBitPath.Contains('{') -or $taskBitPath.Contains('}')){throw 'Bit path must not contain braces.'}
if($Cable -lt 0){throw 'Cable must be nonnegative.'}
$taskOutDir=Join-Path (Split-Path -Parent $PSScriptRoot) 'build\download'
New-Item -ItemType Directory -Path $taskOutDir -Force | Out-Null
$taskCommand="download -bit {$taskBitPath} -mode jtag -spd 7 -sec 64 -cable $Cable"
if($Mode -eq 'program_spi'){
    $taskCommand="download -bit {$taskBitPath} -mode program_spi -v -spd 7 -cable $Cable -flashsize 128"
}
$taskTcl=Join-Path $taskOutDir 'download_audio.tcl'
[System.IO.File]::WriteAllText($taskTcl,$taskCommand+[Environment]::NewLine,(New-Object System.Text.UTF8Encoding($false)))
$taskLog=Join-Path $taskOutDir 'download-output.txt'
& $taskDownloadExe $taskTcl.Replace('\','/') *> $taskLog
$taskExit=$LASTEXITCODE
Get-Content -LiteralPath $taskLog -Tail 25
if($taskExit -ne 0 -or (Select-String -LiteralPath $taskLog -Pattern 'ERROR:|Chip validation fail')){
    throw "Download failed. Inspect $taskLog"
}
Write-Output "Downloader returned exit code 0; verify device success messages and actual picture/sound. Log: $taskLog"
