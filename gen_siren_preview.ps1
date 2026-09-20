#=====================================================================
# Generate a preview WAV for the on-chip DDS air-raid siren.
#
# It models EXACTLY what the RTL will output, so "PC preview == board":
#   * 48 kHz / 16 bit, mono (board drives L=R with the same sample)
#   * 256-point sine table parsed from audio_sine_init.vh (amplitude 4096)
#   * siren = 4*s1 + 2*s2 + s3           s1/s2/s3 = sine(phase), sine(2*phase),
#                                        sine(3*phase)  -> 1st/2nd/3rd harmonic
#                                        at 0/-6/-12 dB = brassy siren timbre
#   * raw   = (siren * 224) >> 8         == volume_scale() with VOLUME=224
#   * frequency = triangle 400 <-> 1000 Hz, period 3 s (1.5 s up, 1.5 s down)
#   * first 256 samples fade in (gain 1..256 /256) == RAMP_SAMPLES=256
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File gen_siren_preview.ps1
#   powershell ... -File gen_siren_preview.ps1 -FLow 450 -FHigh 800 -SweepMs 3000
#=====================================================================
param(
  [string]$VhFile  = 'e:\FPGA\ALST\_dev_sim_0b18789\audio_final\rtl\audio_sine_init.vh',
  [string]$Out     = 'e:\FPGA\ALST\_dev_sim_0b18789\siren_preview_400-1000Hz.wav',
  [int]$Seconds    = 12,
  [int]$FLow       = 400,
  [int]$FHigh      = 1000,
  [int]$SweepMs    = 3000
)
$ErrorActionPreference = 'Stop'
$SR = 48000
$TWO32 = [int64]4294967296

# ---- 1) parse the 256-point sine table from the RTL include ----
$txt  = [IO.File]::ReadAllText($VhFile)
$vals = [regex]::Matches($txt, "16'h([0-9a-fA-F]{4})") | ForEach-Object { [Convert]::ToInt32($_.Groups[1].Value, 16) }
if ($vals.Count -ne 256) { throw "sine table parse failed: got $($vals.Count) entries, expected 256" }
$sine = New-Object 'int[]' 256
for ($i = 0; $i -lt 256; $i++) {
  $sine[$i] = if ($vals[$i] -ge 32768) { $vals[$i] - 65536 } else { $vals[$i] }
}
Write-Host ("sine table OK: 256 entries, min={0} max={1}" -f ($sine | Measure-Object -Minimum).Minimum, ($sine | Measure-Object -Maximum).Maximum)

# ---- 2) 32-bit phase increments for 48 kHz, and the per-tick step of the sweep ----
$incLow  = [int64][Math]::Round($FLow  * $TWO32 / $SR)
$incHigh = [int64][Math]::Round($FHigh * $TWO32 / $SR)
$half    = ($SweepMs / 1000.0) / 2.0
$step    = [int64][Math]::Round(($incHigh - $incLow) / ($half * $SR))
Write-Host ("inc range {0}..{1} ({2}Hz..{3}Hz), step={4}/tick -> up-phase {5:0.000}s" -f $incLow, $incHigh, $FLow, $FHigh, $step, (($incHigh - $incLow) / $step / $SR))

# ---- 3) render ----
$n = $SR * $Seconds
$ms = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter($ms)
$dataBytes = $n * 2
$bw.Write([char[]]'RIFF'); $bw.Write([int](36 + $dataBytes)); $bw.Write([char[]]'WAVE')
$bw.Write([char[]]'fmt '); $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1)
$bw.Write([int]$SR); $bw.Write([int]($SR * 2)); $bw.Write([int16]2); $bw.Write([int16]16)
$bw.Write([char[]]'data'); $bw.Write([int]$dataBytes)

$phase = [int64]0; $inc = $incLow; $rising = $true
$peak = 0; $sumSq = 0.0; $zc = 0; $prev = 0
$blkLen = $SR / 2      # 0.5 s
$zcInBlk = 0; $blkIdx = 0
Write-Host "--- measured tone (zero-crossings per 0.5s block) ---"
for ($i = 0; $i -lt $n; $i++) {
  if ($rising) { $inc += $step; if ($inc -ge $incHigh) { $inc = $incHigh; $rising = $false } }
  else         { $inc -= $step; if ($inc -le $incLow)  { $inc = $incLow;  $rising = $true  } }

  $phase = ($phase + $inc) % $TWO32
  $i1 = [int](($phase -shr 24) -band 0xFF)
  $i2 = [int]((($phase * 2) % $TWO32) -shr 24 -band 0xFF)
  $i3 = [int]((($phase * 3) % $TWO32) -shr 24 -band 0xFF)

  $siren = 4 * $sine[$i1] + 2 * $sine[$i2] + $sine[$i3]
  $raw   = [int][Math]::Floor(($siren * 224) / 256)
  if ($i -lt 256) { $raw = [int][Math]::Floor(($raw * ($i + 1)) / 256) }   # fade in
  if ($raw -gt 32767)  { $raw = 32767 }
  if ($raw -lt -32768) { $raw = -32768 }

  $bw.Write([int16]$raw)
  if ([Math]::Abs($raw) -gt $peak) { $peak = [Math]::Abs($raw) }
  $sumSq += [double]$raw * $raw
  if ($i -gt 0) {
    if (($raw -ge 0) -ne ($prev -ge 0)) { $zcInBlk++ }
  }
  $prev = $raw
  $blkIdx++
  if ($blkIdx -eq $blkLen) {
    Write-Host ("   t={0,4:0.0}s   约 {1,4} Hz" -f ($i / [double]$SR), [int](($zcInBlk / 2.0) / ($blkLen / [double]$SR)))
    $zcInBlk = 0; $blkIdx = 0
  }
}
$bw.Flush()
[IO.File]::WriteAllBytes($Out, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()

$rms = [Math]::Sqrt($sumSq / $n)
Write-Host ""
Write-Host ("written : {0}" -f $Out)
Write-Host ("length  : {0} s, {1} samples, 48kHz/16bit mono, {2} bytes" -f $Seconds, $n, (Get-Item $Out).Length)
Write-Host ("peak    : {0} ({1:0.0} dBFS)   rms: {2:0.0}" -f $peak, (20 * [Math]::Log10($peak / 32768.0)), $rms)
Write-Host ("note    : on-chip DDS siren preview, peak {0} of 32767 full scale" -f $peak)
