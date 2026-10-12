param(
    [string]$Vsim = 'D:\Quat\modelsim_ase\win32aloem\vsim.exe'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sim = Join-Path $root 'sim'
$out = Join-Path $sim '_regress_1013'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$passed = 0
$failed = 0
$summary = [System.Collections.Generic.List[string]]::new()

Push-Location $sim
try {
    foreach ($doFile in Get-ChildItem -File -Filter 'run_sim*.do' | Sort-Object Name) {
        $name = $doFile.BaseName
        $text = (& $Vsim -c -do "do $($doFile.Name)" 2>&1 | Out-String)
        Set-Content -LiteralPath (Join-Path $out "$name.log") -Value $text -Encoding utf8

        $failCount = ([regex]::Matches($text, '\[FAIL\]')).Count
        $errorCount = ([regex]::Matches($text, '\*\* Error')).Count
        if (($failCount + $errorCount) -eq 0) {
            $passed++
            $line = "[PASS] $name FAIL=0 Error=0"
        } else {
            $failed++
            $line = "[FAIL] $name FAIL=$failCount Error=$errorCount"
        }
        $summary.Add($line)
        Write-Output $line
    }
} finally {
    Pop-Location
}

$summary.Add("TOTAL=$($passed + $failed) PASS=$passed FAIL=$failed")
Set-Content -LiteralPath (Join-Path $out 'summary.txt') -Value $summary -Encoding utf8
Write-Output $summary[$summary.Count - 1]
if ($failed -ne 0) { exit 1 }
