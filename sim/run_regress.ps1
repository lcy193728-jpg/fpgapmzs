#====================================================================
# ModelSim 批量回归脚本(会议链整合后)
#   用法: powershell -ExecutionPolicy Bypass -File run_regress.ps1
#         powershell ... -File run_regress.ps1 -Only tb_scene_control
#   说明: 每个 TB 单独建库/编译/仿真, 日志落在 sim/_regress/<tb>/, 
#         自动扫描 transcript 里的 FAIL/ERROR/致命告警并汇总。
#====================================================================
param(
  [string]$ModelSimDir = 'D:\intelFPGA_lite\17.1\modelsim_ase\win32aloem',
  [string]$Only = ''
)

$ErrorActionPreference = 'Stop'
$vlib = Join-Path $ModelSimDir 'vlib.exe'
$vlog = Join-Path $ModelSimDir 'vlog.exe'
$vsim = Join-Path $ModelSimDir 'vsim.exe'
if (-not (Test-Path $vlog)) { throw "找不到 vlog.exe: $vlog" }
if (-not (Test-Path $vsim)) { throw "找不到 vsim.exe: $vsim" }

$simRoot = $PSScriptRoot
$outRoot = Join-Path $simRoot '_regress'
New-Item -ItemType Directory -Force $outRoot | Out-Null

# TB -> 需要一起编译的 RTL(路径相对 sim/)
$tests = [ordered]@{
  'tb_bmp_read_auto'  = @('../src/bmp_read_auto.v')
  'tb_bmp_scale'      = @('../src/bmp_scale.v')
  'tb_display_adjust' = @('../src/display_adjust.v')
  'tb_osd_engine'     = @('../src/osd_engine.v')
  'tb_osd_menu'       = @('../src/osd_font_rom.v', '../src/osd_menu.v')
  'tb_osd_scene'      = @('../src/osd_font_rom.v', '../src/osd_scene.v')
  'tb_osd_welcome'    = @('../src/osd_font_rom.v', '../src/osd_welcome.v')
  'tb_quiz_ctrl'      = @('../src/scene_control.v', '../src/quiz_ctrl.v')
  'tb_scene_control'  = @('../src/scene_control.v')
  'tb_ui_key_ctrl'    = @('../src/ui_key_ctrl.v')
  # MTG1 解析器(用真实 meeting.bin 字节流; 2026-09-19 上板事故后补)
  'tb_meeting_sd_rd'  = @('../src/meeting_sd_rd.v')
  # meeting_osd.v 内部用 `include 并入 meeting_fmt.v / meeting_glyph_rom.v(与 top.v 一致),
  # 故这里只编译 3 个文件; 重复列出被 include 的模块会"重复定义"。
  'tb_meeting_chain'  = @('../src/meeting_cfg.v', '../src/meeting_ctrl.v',
                          '../src/meeting_osd.v')
}

$summary = @()
foreach ($tb in $tests.Keys) {
  if ($Only -ne '' -and $tb -ne $Only) { continue }

  $runDir = Join-Path $outRoot $tb
  if (Test-Path $runDir) { Remove-Item -Recurse -Force $runDir }
  New-Item -ItemType Directory -Force $runDir | Out-Null

  $srcs = $tests[$tb]
  $srcAbs = @()
  foreach ($s in $srcs) { $srcAbs += (Resolve-Path (Join-Path $simRoot $s)).Path }
  $tbPath = Join-Path $simRoot ('../tb/' + $tb + '.v')
  if (-not (Test-Path $tbPath)) { continue }
  $tbAbs = (Resolve-Path $tbPath).Path

  Write-Host "=== $tb ===" -ForegroundColor Cyan
  Push-Location $runDir
  try {
    & $vlib work | Out-Null
    & $vlog -quiet "+incdir+$((Resolve-Path (Join-Path $simRoot '../src')).Path)" @srcAbs $tbAbs -l 'compile.log' | Out-Null
    $compileOk = ($LASTEXITCODE -eq 0)
    if (-not $compileOk) {
      $summary += [pscustomobject]@{ TB = $tb; Compile = 'FAIL'; Sim = '-'; Result = 'COMPILE FAIL' }
      Write-Host "  编译失败, 见 $runDir\compile.log" -ForegroundColor Red
      continue
    }
    & $vsim -c -t 1ps work.$tb -l 'sim.log' -do 'run -all; quit -f' | Out-Null
    $simOk = ($LASTEXITCODE -eq 0)
  } finally { Pop-Location }

  $log = Get-Content -LiteralPath (Join-Path $runDir 'sim.log') -Raw -ErrorAction SilentlyContinue
  if ($null -eq $log) { $log = '' }
  # 断言统计: 若用 "[PASS]"/"[FAIL]" 风格则只数括号标记(避免把汇总行 "TEST FAILED"
  # 重复计入); 否则退回裸 FAIL/PASS 风格。
  if ($log -match '\[(PASS|FAIL)\]') {
    $failHits = ([regex]::Matches($log, '(?m)\[FAIL\]')).Count
    $passHits = ([regex]::Matches($log, '(?m)\[PASS\]')).Count
  } else {
    $failHits = ([regex]::Matches($log, '(?m)\bFAIL\b|\bFAILED\b')).Count
    $passHits = ([regex]::Matches($log, '(?m)\bPASS\b|\bPASSED\b')).Count
  }
  $errHits = ([regex]::Matches($log, '(?m)\bERROR\b|\*\* Error')).Count

  $result = if (-not $simOk) { 'SIM 异常退出' }
            elseif ($failHits -gt 0 -or $errHits -gt 0) { 'FAIL' }
            elseif ($passHits -gt 0) { 'PASS' }
            else { 'PASS(无断言)' }

  $color = if ($result -like 'PASS*') { 'Green' } else { 'Red' }
  Write-Host ("  {0}  (PASS断言={1} FAIL={2} ERROR={3})" -f $result, $passHits, $failHits, $errHits) -ForegroundColor $color

  $summary += [pscustomobject]@{
    TB      = $tb
    Compile = 'OK'
    Sim     = if ($simOk) { 'OK' } else { "exit=$LASTEXITCODE" }
    Result  = $result
  }
}

Write-Host ''
Write-Host '================ 回归汇总 ================' -ForegroundColor Yellow
$summary | Format-Table -AutoSize
$bad = @($summary | Where-Object { $_.Result -notlike 'PASS*' })
Write-Host ("总数 {0}, 通过 {1}, 未通过 {2}" -f $summary.Count, ($summary.Count - $bad.Count), $bad.Count) -ForegroundColor Yellow
if ($bad.Count -gt 0) { exit 1 }
