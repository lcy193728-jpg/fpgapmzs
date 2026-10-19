[CmdletBinding()]
param(
    [string]$BuildDir = "_build_showcase_1013",
    [string]$BitPath = "artifacts/pic_sdram_audio_candidate_seed59.bit",
    [int]$MaxLut = 16365,
    [int]$MaxLe = 17084,
    [int]$MaxSlices = 8822,
    [int]$MaxBram9k = 40,
    [int]$MaxBram32k = 8,
    [int]$MaxDsp = 14,
    [double]$MinSetupWnsNs = 0.0,
    [double]$MinHoldWnsNs = 0.0,
    [int]$MaxTimestampSkewMinutes = 10,
    [string]$ExpectedSha256 = ""
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot

function Resolve-ProjectPath([string]$PathValue) {
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $projectRoot $PathValue))
}

function Read-RequiredText([string]$PathValue) {
    if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
        throw "Missing qualification file: $PathValue"
    }
    return [System.IO.File]::ReadAllText($PathValue)
}

function Get-IntegerMetric([string]$Text, [string]$Pattern, [string]$Name) {
    $match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $match.Success) {
        throw "Metric not found in report: $Name"
    }
    return [int]$match.Groups[1].Value
}

function Add-Check(
    [System.Collections.Generic.List[object]]$Rows,
    [string]$Name,
    $Value,
    [string]$Rule,
    [bool]$Passed
) {
    $Rows.Add([pscustomobject]@{
        Check = $Name
        Value = $Value
        Rule = $Rule
        Result = $(if ($Passed) { "PASS" } else { "FAIL" })
    })
}

$buildPath = Resolve-ProjectPath $BuildDir
$bitFullPath = Resolve-ProjectPath $BitPath
$areaPath = Join-Path $buildPath "final.area"
$timingPath = Join-Path $buildPath "final.timing"
$routeQorPath = Join-Path $buildPath "route.qor"

$areaText = Read-RequiredText $areaPath
$timingText = Read-RequiredText $timingPath
$routeQorText = Read-RequiredText $routeQorPath
if (-not (Test-Path -LiteralPath $bitFullPath -PathType Leaf)) {
    throw "Missing candidate BIT: $bitFullPath"
}

$lut = Get-IntegerMetric $areaText '^#lut\s+(\d+)' 'LUT'
$le = Get-IntegerMetric $areaText '^#le\s+(\d+)' 'LE'
$bram9k = Get-IntegerMetric $areaText '^\s*#bram9k\s+(\d+)' 'BRAM9K'
$bram32k = Get-IntegerMetric $areaText '^#bram32k\s+(\d+)' 'BRAM32K'
$dsp = Get-IntegerMetric $areaText '^#dsp\s+(\d+)' 'DSP'
$slices = Get-IntegerMetric $routeQorText '^\|\s*#slices\s*\|\s*(\d+)' 'Slices'

$timingMatch = [regex]::Match(
    $timingText,
    'SWNS:\s*([-+]?\d+(?:\.\d+)?)ns.*?HWNS:\s*([-+]?\d+(?:\.\d+)?)ns',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
if (-not $timingMatch.Success) {
    throw "Global SWNS/HWNS not found in final.timing"
}
$setupWns = [double]::Parse($timingMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
$holdWns = [double]::Parse($timingMatch.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)

$bitItem = Get-Item -LiteralPath $bitFullPath
$reportItems = @(
    Get-Item -LiteralPath $areaPath
    Get-Item -LiteralPath $timingPath
    Get-Item -LiteralPath $routeQorPath
)
$latestStamp = ($reportItems + $bitItem | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
$earliestStamp = ($reportItems + $bitItem | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime
$timestampSkew = ($latestStamp - $earliestStamp).TotalMinutes
$sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $bitFullPath).Hash

$checks = [System.Collections.Generic.List[object]]::new()
Add-Check $checks 'LUT' $lut "<= $MaxLut" ($lut -le $MaxLut)
Add-Check $checks 'LE' $le "<= $MaxLe" ($le -le $MaxLe)
Add-Check $checks 'Slices' $slices "<= $MaxSlices" ($slices -le $MaxSlices)
Add-Check $checks 'BRAM9K' $bram9k "<= $MaxBram9k" ($bram9k -le $MaxBram9k)
Add-Check $checks 'BRAM32K' $bram32k "<= $MaxBram32k" ($bram32k -le $MaxBram32k)
Add-Check $checks 'DSP' $dsp "<= $MaxDsp" ($dsp -le $MaxDsp)
Add-Check $checks 'Setup WNS(ns)' $setupWns ">= $MinSetupWnsNs" ($setupWns -ge $MinSetupWnsNs)
Add-Check $checks 'Hold WNS(ns)' $holdWns ">= $MinHoldWnsNs" ($holdWns -ge $MinHoldWnsNs)
Add-Check $checks 'Report/BIT timestamp skew(min)' ([math]::Round($timestampSkew, 2)) "<= $MaxTimestampSkewMinutes" ($timestampSkew -le $MaxTimestampSkewMinutes)
if ($ExpectedSha256) {
    Add-Check $checks 'BIT SHA256' $sha256 "== $($ExpectedSha256.ToUpperInvariant())" ($sha256 -eq $ExpectedSha256.ToUpperInvariant())
}

$checks | Format-Table -AutoSize
Write-Host "BIT: $bitFullPath"
Write-Host "SHA256: $sha256"

$failed = @($checks | Where-Object Result -eq 'FAIL')
if ($failed.Count -gt 0) {
    Write-Error "QoR gate failed: $($failed.Count) check(s). Do not promote this BIT."
    exit 1
}

Write-Host "QOR_GATE_PASS: promote only after functional regression also passes."
exit 0
