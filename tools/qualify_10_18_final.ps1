[CmdletBinding()]
param(
    [string]$Iverilog = '',
    [string]$Vvp = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root 'sim\_release_10_18'
$finalBit = Join-Path $root 'artifacts\ONLY_PROGRAM_10_18_FINAL_ARCH_LP.bit'
$expectedHash = '318747763FB4682EF21923C4DC95A4D1D48BBB40291D83A1246DF97F6C891B3D'

if (-not $Iverilog) { $Iverilog = (Get-Command iverilog -ErrorAction Stop).Source }
if (-not $Vvp) { $Vvp = (Get-Command vvp -ErrorAction Stop).Source }
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# First execute the complete functional/QoR/hash gate of the proven release.
& (Join-Path $PSScriptRoot 'qualify_10_17_release.ps1') -Iverilog $Iverilog -Vvp $Vvp
if ($LASTEXITCODE -ne 0) { throw 'Base release qualification failed.' }

function Run-Icarus([string]$Name, [string]$Top, [string[]]$Sources,
                     [string[]]$Defines = @(), [string]$RunDirectory = $root) {
    $outFile = Join-Path $logDir "$Name.vvp"
    $sourcePaths = @($Sources | ForEach-Object { Join-Path $root $_ })
    $defineArgs = @($Defines | ForEach-Object { "-D$_" })
    # scene_audio_final keeps its generated sine table relative to
    # audio_final/tb (../rtl/audio_sine_init.vh).  Supply both project include
    # roots so this release gate works regardless of the caller's cwd.
    # Keep compiler warnings in the log without letting Windows PowerShell
    # promote native stderr warnings to terminating NativeCommandError records.
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $compile = (& $Iverilog -g2012 @defineArgs `
                    -I (Join-Path $root 'src') `
                    -I (Join-Path $root 'audio_final\tb') `
                    -s $Top -o $outFile @sourcePaths 2>&1 | Out-String)
    }
    finally {
        $ErrorActionPreference = $savedErrorAction
    }
    if (-not (Test-Path -LiteralPath $outFile -PathType Leaf) -or
        (Get-Item -LiteralPath $outFile).Length -eq 0) {
        throw "Compile failed: $Name`n$compile"
    }
    Push-Location $RunDirectory
    try { $run = (& $Vvp $outFile 2>&1 | Out-String) }
    finally { Pop-Location }
    $text = $compile + $run
    Set-Content -LiteralPath (Join-Path $logDir "$Name.log") -Value $text -Encoding utf8
    if ($LASTEXITCODE -ne 0 -or $text -match '\[FAIL\]|RESULT:\s*FAIL|TEST FAILED|FATAL') {
        throw "Simulation failed: $Name"
    }
    Write-Host "[PASS] $Name"
}

Run-Icarus 'low_power_activity' 'tb_low_power_gating' @(
    'audio_final/rtl/scene_audio_final.v',
    'audio_final/tb/tb_low_power_gating.v'
) @('POWER_ACTIVITY') (Join-Path $root 'audio_final\tb')
& (Join-Path $PSScriptRoot 'analyze_scene_audio_vcd.ps1')

Run-Icarus 'welcome_mosaic' 'tb_welcome_mosaic' @(
    'audio_final/tb/EG_LOGIC_BRAM_sim.v',
    'src/welcome_mosaic.v',
    'sim/tb/tb_welcome_mosaic.v'
)

Run-Icarus 'bmp_scale_bram_gate' 'tb_bmp_scale_bram_gate' @(
    'audio_final/tb/EG_LOGIC_BRAM_sim.v',
    'src/bmp_scale.v',
    'sim/tb/tb_bmp_scale_bram_gate.v'
)

Run-Icarus 'emergency_arrows' 'tb_emergency_arrows' @(
    'audio_final/tb/EG_LOGIC_BRAM_sim.v',
    'src/emergency_font_rom.v',
    'src/emergency_big_font_rom.v',
    'src/emergency_title_font_rom.v',
    'src/emergency_multi_overlay.v',
    'sim/tb/tb_emergency_arrows.v'
) @() (Join-Path $root 'audio_final\tb')

if (-not (Test-Path -LiteralPath $finalBit -PathType Leaf)) {
    throw "Final BIT missing: $finalBit"
}
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $finalBit).Hash
if ($hash -ne $expectedHash) {
    throw "Final BIT hash mismatch: $hash"
}

Write-Host 'FINAL_10_18_PASS'
Write-Host "Only program: $finalBit"
Write-Host "SHA256: $hash"
