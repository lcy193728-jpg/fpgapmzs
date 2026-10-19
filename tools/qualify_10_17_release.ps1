[CmdletBinding()]
param(
    [string]$Iverilog = '',
    [string]$Vvp = '',
    [switch]$SkipSimulation
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root 'sim\_release_10_17'
$bit = 'artifacts/ONLY_PROGRAM_10_17_ARCH_LP_RELEASE.bit'
$expectedHash = '318747763FB4682EF21923C4DC95A4D1D48BBB40291D83A1246DF97F6C891B3D'

if (-not $SkipSimulation) {
    if (-not $Iverilog) { $Iverilog = (Get-Command iverilog -ErrorAction Stop).Source }
    if (-not $Vvp) { $Vvp = (Get-Command vvp -ErrorAction Stop).Source }
    if (-not (Test-Path -LiteralPath $Iverilog -PathType Leaf)) {
        throw "iverilog not found: $Iverilog"
    }
    if (-not (Test-Path -LiteralPath $Vvp -PathType Leaf)) {
        throw "vvp not found: $Vvp"
    }
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    function Run-Icarus([string]$Name, [string]$Top, [string[]]$Sources) {
        $outFile = Join-Path $logDir "$Name.vvp"
        $sourcePaths = @($Sources | ForEach-Object { Join-Path $root $_ })
        $compile = (& $Iverilog -g2012 -s $Top -o $outFile $sourcePaths 2>&1 | Out-String)
        # The bundled Windows iverilog may raise 0xc0000005 while exiting even
        # after it has emitted a complete vvp image.  Qualify the image itself;
        # vvp execution below remains authoritative for the regression.
        if (-not (Test-Path -LiteralPath $outFile -PathType Leaf) -or
            (Get-Item -LiteralPath $outFile).Length -eq 0) {
            Set-Content -LiteralPath (Join-Path $logDir "$Name.log") -Value $compile -Encoding utf8
            throw "Compile failed: $Name"
        }
        $run = (& $Vvp $outFile 2>&1 | Out-String)
        $text = $compile + $run
        Set-Content -LiteralPath (Join-Path $logDir "$Name.log") -Value $text -Encoding utf8
        $failCount = ([regex]::Matches($text, '\[FAIL\]|RESULT:\s*FAIL|\*\*\s*Error|FATAL')).Count
        if ($LASTEXITCODE -ne 0 -or $failCount -ne 0) {
            throw "Simulation failed: $Name (exit=$LASTEXITCODE, markers=$failCount)"
        }
        Write-Host "[PASS] $Name"
    }

    Run-Icarus 'first_frame' 'tb_video_first_frame_gate' @('src/video_first_frame_gate.v', 'sim/tb/tb_video_first_frame_gate.v')
    Run-Icarus 'menu' 'tb_osd_menu' @('src/osd_font_rom.v', 'src/osd_menu_aa_rom.v', 'src/osd_menu.v', 'tb/tb_osd_menu.v')
    Run-Icarus 'welcome' 'tb_osd_welcome' @('src/osd_font_rom.v', 'src/osd_welcome.v', 'tb/tb_osd_welcome.v')
    Run-Icarus 'welcome_uart' 'tb_welcome_uart' @('src/uart_rx_byte.v', 'src/uart_tx_byte.v', 'src/welcome_uart_controller.v', 'src/welcome_cfg_frame_commit.v', 'src/emergency_cfg_frame_commit.v', 'tb/tb_welcome_uart.v')
    Run-Icarus 'meeting_osd' 'tb_meeting_osd' @('src/meeting_osd.v', 'tb/tb_meeting_osd.v')
    Run-Icarus 'quiz' 'tb_quiz_ctrl' @('src/scene_control.v', 'src/quiz_ctrl.v', 'sim/tb/tb_quiz_ctrl.v')
    Run-Icarus 'viz_gate' 'tb_audio_viz_gate' @('audio_final/tb/EG_LOGIC_BRAM_sim.v', 'audio_final/rtl/audio_viz_overlay.v', 'audio_final/tb/tb_audio_viz_gate.v')
    Run-Icarus 'bmp_scale' 'tb_bmp_scale' @('audio_final/tb/EG_LOGIC_BRAM_sim.v', 'src/bmp_scale.v', 'tb/tb_bmp_scale.v')
}

& (Join-Path $PSScriptRoot 'check_qor_gate.ps1') `
    -BuildDir '_build_opt_uart_payload_seed59' `
    -BitPath $bit `
    -MaxLut 17381 -MaxLe 18196 -MaxSlices 9395 `
    -MaxBram9k 52 -MaxBram32k 13 -MaxDsp 14 `
    -MinSetupWnsNs 0.0 -MinHoldWnsNs 0.0 `
    -ExpectedSha256 $expectedHash
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host 'RELEASE_10_17_PASS'
Write-Host "Only program: $root\$bit"

