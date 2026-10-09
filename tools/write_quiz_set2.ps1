$ErrorActionPreference = 'Stop'
$src = "E:\FPGA\ALST\_quiz_stage"
$vg  = (Get-Volume -DriveLetter G).Path.TrimEnd('\')
$log = "E:\FPGA\ALST\_quiz_write_log.txt"
$out = @()
$out += "VG=$vg"
$names = @('QUIZ1.BMP','QUIZ2.BMP','QUIZ3.BMP','QUIZ4.BMP','QUIZ5.BMP','QUIZ6.BMP','QUIZ7.BMP','QUIZ8.BMP')
foreach ($n in $names) {
    $p = "G:\$n"
    if (Test-Path -LiteralPath $p) {
        try { [System.IO.File]::Delete($p); $out += "DEL  $n  OK" }
        catch { $out += "DEL  $n  FAIL: $($_.Exception.Message)" }
    } else { $out += "DEL  $n  (absent)" }
}
foreach ($n in $names) {
    $s = Join-Path $src $n
    $d = "$vg\$n"
    if (-not (Test-Path -LiteralPath $s)) { $out += "CP   $n  MISSING SRC"; continue }
    try {
        Copy-Item -LiteralPath $s -Destination $d -Force
        $sz = (Get-Item -LiteralPath $d).Length
        $out += "CP   $n  OK  $sz B"
    } catch { $out += "CP   $n  FAIL: $($_.Exception.Message)" }
}
$out += "---- final dir ----"
$out += Get-ChildItem 'G:\' -File | ForEach-Object { "$($_.Name)  $($_.Length)" }
$out | Set-Content -Encoding UTF8 $log
Write-Output "done"
