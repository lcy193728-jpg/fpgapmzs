[CmdletBinding()]
param(
    [string]$Vcd = 'audio_final/tb/scene_audio_lp_activity.vcd'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root $Vcd
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "VCD not found: $path"
}

# IDs are stable because the activity TB dumps only scene_audio_final.dut.
$idState = 's'
$idBurst = 'Y'
$phaseIds = @('e', 'f', 'g')
$values = @{}
$counts = [ordered]@{
    idle_phase_changes       = 0
    alarm_rest_entry_changes = 0
    alarm_rest_steady_changes = 0
    active_phase_changes     = 0
}
$phaseChangesAtTime = 0
$previousWasRest = $false

function Commit-TimeBucket {
    if ($script:phaseChangesAtTime -eq 0) {
        $script:previousWasRest = (($script:values[$script:idState] -eq '11') -and
                                   ($script:values[$script:idBurst] -eq '0'))
        return
    }
    $state = $script:values[$script:idState]
    $burst = $script:values[$script:idBurst]
    $isRest = (($state -eq '11') -and ($burst -eq '0'))
    if ($state -eq '0') {
        $script:counts.idle_phase_changes += $script:phaseChangesAtTime
    }
    elseif ($isRest) {
        if ($script:previousWasRest) {
            $script:counts.alarm_rest_steady_changes += $script:phaseChangesAtTime
        }
        else {
            # One boundary bucket is allowed to drive the three phase
            # accumulators back to zero before the rest interval freezes.
            $script:counts.alarm_rest_entry_changes += $script:phaseChangesAtTime
        }
    }
    else {
        $script:counts.active_phase_changes += $script:phaseChangesAtTime
    }
    $script:phaseChangesAtTime = 0
    $script:previousWasRest = $isRest
}

foreach ($line in [System.IO.File]::ReadLines($path)) {
    if (-not $line -or $line[0] -eq '$') { continue }
    if ($line[0] -eq '#') {
        Commit-TimeBucket
        continue
    }
    $id = $null
    $value = $null
    if ($line[0] -eq 'b') {
        $parts = $line.Split(' ', 2, [System.StringSplitOptions]::RemoveEmptyEntries)
        if ($parts.Count -ne 2) { continue }
        $value = $parts[0].Substring(1)
        $id = $parts[1]
    }
    else {
        $value = $line.Substring(0, 1)
        $id = $line.Substring(1)
    }

    $old = $values[$id]
    $values[$id] = $value
    if ($phaseIds -notcontains $id -or $null -eq $old -or $old -eq $value) { continue }

    $phaseChangesAtTime++
}
Commit-TimeBucket

$result = [pscustomobject]$counts
$result | Format-List
# VCD records the X->0 initialization of each of the three phase vectors and
# the nonblocking state/rest boundary in adjacent timestamp buckets.  Permit
# only those three-vector boundary writes; the RTL regression independently
# proves that all later rest samples remain exactly zero.
if ($counts.idle_phase_changes -gt 3 -or
    $counts.alarm_rest_entry_changes -gt 3 -or
    $counts.alarm_rest_steady_changes -gt 3) {
    throw 'Low-power activity invariant failed: repeated DDS phase activity was observed in an idle/rest window.'
}
if ($counts.active_phase_changes -eq 0) {
    throw 'Activity capture is invalid: no active DDS phase changes were observed.'
}
Write-Host 'SCENE_AUDIO_ACTIVITY_PASS'
