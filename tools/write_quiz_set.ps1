# ====================================================================
# write_quiz_set.ps1 —— 把新口径的 QUIZ1..QUIZ8 写入 TF 卡(G:)根目录
#
# 【为什么用卷 GUID 路径】
#   本机 G: 盘符层存在写过滤: 用 "G:\x.bmp" 覆盖【已存在】文件会被拒
#   (裸卷 \\.\G: 也只读)。经实测, 只有走 \\?\Volume{...}\ 卷句柄路径才能
#   正常覆盖。详见项目记忆「往 TF 卡写文件」一节。
#
# 【为什么要先删后写】
#   bmp_read_auto 顺序扫描要求同一分区图片在卡上【按显示顺序升序排列】。
#   先删掉旧的 QUIZ1..5 让出簇区(226..370), 再按 QUIZ1→QUIZ8 顺序写,
#   Windows 分配器会从最小空闲簇开始顺排 → 8 张图天然连续升序。
#
# 【用法】powershell -ExecutionPolicy Bypass -File tools/write_quiz_set.ps1
# ====================================================================

$ErrorActionPreference = 'Stop'

$src  = "E:\FPGA\ALST\_dev_sim_0b18789\图片\_quiz_team"
$vg   = (Get-Volume -DriveLetter G).Path.TrimEnd('\')   # \\?\Volume{...}
$log  = "E:\FPGA\ALST\_quiz_write_log.txt"

$out = @()
$out += "VG=$vg"
$out += "SRC=$src"

# ---- 1) 删除旧 QUIZ*.BMP ----
foreach ($n in @('QUIZ1.BMP','QUIZ2.BMP','QUIZ3.BMP','QUIZ4.BMP','QUIZ5.BMP',
                 'QUIZ6.BMP','QUIZ7.BMP','QUIZ8.BMP')) {
    $p = "G:\$n"
    if (Test-Path -LiteralPath $p) {
        try { [System.IO.File]::Delete($p); $out += "DEL  $n  OK" }
        catch { $out += "DEL  $n  FAIL: $($_.Exception.Message)" }
    } else {
        $out += "DEL  $n  (absent)"
    }
}

# ---- 2) 按顺序写入 8 张 ----
foreach ($n in @('QUIZ1.BMP','QUIZ2.BMP','QUIZ3.BMP','QUIZ4.BMP',
                 'QUIZ5.BMP','QUIZ6.BMP','QUIZ7.BMP','QUIZ8.BMP')) {
    $s = Join-Path $src $n
    $d = "$vg\$n"
    if (-not (Test-Path -LiteralPath $s)) { $out += "CP   $n  MISSING SRC"; continue }
    try {
        Copy-Item -LiteralPath $s -Destination $d -Force
        $sz = (Get-Item -LiteralPath $d).Length
        $out += "CP   $n  OK  $sz B"
    } catch {
        $out += "CP   $n  FAIL: $($_.Exception.Message)"
    }
}

# ---- 3) 回读目录核对 ----
$out += "---- final dir ----"
$out += Get-ChildItem 'G:\' -File | ForEach-Object { "$($_.Name)  $($_.Length)" }

$out | Set-Content -Encoding UTF8 $log
Write-Output "done -> $log"
