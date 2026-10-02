# ====================================================================
# write_sd_music.ps1 —— 把裸 PCM 音乐写入 TF 卡固定物理扇区(需管理员)
#
# 背景: FPGA 端 sd_card_sec_read_write.v 直接下发 CMD17(扇区号) —— 读的是
#   【物理扇区】。音乐区固定 WAV_START_LBA(=300000) 起连续 N 个扇区。
#
# 为什么不能直接 FileStream 写:
#   目标扇区位于【已挂载的 exFAT 卷】内部, Windows 会拒绝原始写
#   (Python 报 Errno 9 Bad file descriptor / FlushFileBuffers 失败)。
#   必须先对卷做 FSCTL_LOCK_VOLUME + FSCTL_DISMOUNT_VOLUME, 再写, 最后解锁。
#
# 安全措施:
#   1) 只按"整盘物理扇区偏移"写入, 不碰文件系统元数据;
#   2) 写前校验源文件长度 == 扇区数 x 512, 且 sha256 与期望一致;
#   3) 写后回读整段并比对 sha256, 不一致即报错;
#   4) 结束时释放锁并重新挂载卷。
#
# 用法(管理员 PowerShell):
#   powershell -ExecutionPolicy Bypass -File tools\write_sd_music.ps1 `
#       -Disk 1 -Drive F -Lba 300000 -Sectors 38464 `
#       -Raw audio_final\assets\wel_music_48k_mono.raw `
#       -ExpectedSha256 0d463ec052a46c5d16e125d348aa64301ec9c394b8b5810b75ef02712d1d5222 `
#       -LogFile audio_final\build\sd_write.log -Write
# ====================================================================
param(
  [int]    $Disk = 1,
  [string] $Drive = 'F',
  [int]    $Lba = 300000,
  [int]    $Sectors = 38464,
  [Parameter(Mandatory=$true)][string] $Raw,
  [string] $ExpectedSha256 = '',
  [string] $LogFile = '',
  [switch] $Write
)

$ErrorActionPreference = 'Stop'

if ($LogFile) {
  $logDir = Split-Path -Parent $LogFile
  if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  }
  Remove-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue
}
function Say($msg) {
  Write-Host $msg
  if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $msg -Encoding ASCII }
}

# ---------- P/Invoke: 卷锁定 / 卸载 ----------
$cs = @"
using System;
using System.Runtime.InteropServices;
public static class Vol {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateFileW(string name, uint access, uint share,
      IntPtr sec, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool DeviceIoControl(IntPtr h, uint code, IntPtr inBuf,
      uint inSz, IntPtr outBuf, uint outSz, out uint ret, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool CloseHandle(IntPtr h);
  public const uint GENERIC_READ=0x80000000, GENERIC_WRITE=0x40000000;
  public const uint FILE_SHARE_READ=1, FILE_SHARE_WRITE=2;
  public const uint OPEN_EXISTING=3;
  public const uint FSCTL_LOCK_VOLUME=0x00090018, FSCTL_UNLOCK_VOLUME=0x0009001C;
  public const uint FSCTL_DISMOUNT_VOLUME=0x00090020;
  public static string LastErr() { return Marshal.GetLastWin32Error().ToString(); }
}
"@
if (-not ('Vol' -as [type])) { Add-Type -TypeDefinition $cs }

try {
  # ---------- 0) 源文件校验 ----------
  $rawPath = (Resolve-Path -LiteralPath $Raw).Path
  $fi = Get-Item -LiteralPath $rawPath
  $bytes = $Sectors * 512
  Say ("源文件        : {0}" -f $rawPath)
  Say ("源文件长度    : {0} 字节 (期望 {1}; 扇区 {2})" -f $fi.Length, $bytes, $Sectors)
  if ($fi.Length -ne $bytes) { throw "源文件长度与扇区数不符, 拒绝写入" }
  $srcHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawPath).Hash.ToLowerInvariant()
  Say ("源 sha256     : {0}" -f $srcHash)
  if ($ExpectedSha256 -and ($srcHash -ne $ExpectedSha256.ToLowerInvariant())) {
    throw "源文件 sha256 与期望不符, 拒绝写入"
  }

  $offPhys = [int64]$Lba * 512
  Say ("目标物理偏移  : {0} (= {1} 扇区 x 512)" -f $offPhys, $Lba)
  Say ("覆盖范围      : {0} ~ {1} 字节" -f $offPhys, ($offPhys + $bytes - 1))

  if (-not $Write) {
    Say "[预演模式] 未写任何数据(加 -Write 执行)"
    exit 0
  }

  # ---------- 1) 锁定 + 卸载卷 ----------
  $volPath = '\\.\' + $Drive.TrimEnd(':') + ':'
  $hVol = [Vol]::CreateFileW($volPath, [Vol]::GENERIC_READ -bor [Vol]::GENERIC_WRITE,
            [Vol]::FILE_SHARE_READ -bor [Vol]::FILE_SHARE_WRITE, [IntPtr]::Zero,
            [Vol]::OPEN_EXISTING, 0, [IntPtr]::Zero)
  if ($hVol.ToInt64() -eq -1) { throw ("打开卷 {0} 失败, err={1}" -f $volPath, [Vol]::LastErr()) }
  Say ("打开卷        : {0} OK" -f $volPath)
  $r = 0
  if (-not [Vol]::DeviceIoControl($hVol, [Vol]::FSCTL_LOCK_VOLUME, [IntPtr]::Zero, 0,
          [IntPtr]::Zero, 0, [ref]$r, [IntPtr]::Zero)) {
    [Vol]::CloseHandle($hVol) | Out-Null
    throw ("FSCTL_LOCK_VOLUME 失败, err={0}" -f [Vol]::LastErr())
  }
  Say "锁卷          : OK"
  if (-not [Vol]::DeviceIoControl($hVol, [Vol]::FSCTL_DISMOUNT_VOLUME, [IntPtr]::Zero, 0,
          [IntPtr]::Zero, 0, [ref]$r, [IntPtr]::Zero)) {
    [Vol]::CloseHandle($hVol) | Out-Null
    throw ("FSCTL_DISMOUNT_VOLUME 失败, err={0}" -f [Vol]::LastErr())
  }
  Say "卸载卷        : OK"

  try {
    # ---------- 2) 打开物理盘并写入 ----------
    $fs = [IO.File]::Open(('\\.\PhysicalDrive{0}' -f $Disk),
          [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    $fs.Seek($offPhys, 'Begin') | Out-Null
    $src = [IO.File]::OpenRead($rawPath)
    $buf = New-Object byte[] (1MB)
    $done = 0
    while ($done -lt $bytes) {
      $want = [Math]::Min($buf.Length, $bytes - $done)
      $got = $src.Read($buf, 0, $want)
      if ($got -le 0) { break }
      if ($got % 512 -ne 0) { throw ("块长度 {0} 非 512 的整数倍" -f $got) }
      $fs.Write($buf, 0, $got)
      $done += $got
    }
    $src.Close()
    $fs.Flush()
    $fs.Close()
    Say ("写入完成      : {0} 字节" -f $done)
    if ($done -ne $bytes) { throw "写入字节数不足" }

    # ---------- 3) 回读校验 ----------
    $fr = [IO.File]::Open(('\\.\PhysicalDrive{0}' -f $Disk),
          [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $fr.Seek($offPhys, 'Begin') | Out-Null
    $sha = [Security.Cryptography.SHA256]::Create()
    $left = $bytes
    while ($left -gt 0) {
      $want = [Math]::Min($buf.Length, $left)
      $got = $fr.Read($buf, 0, $want)
      if ($got -le 0) { break }
      $null = $sha.TransformBlock($buf, 0, $got, $null, 0)
      $left -= $got
    }
    $null = $sha.TransformFinalBlock(@(), 0, 0)
    $fr.Close()
    $gotHash = ($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join ''
    Say ("回读 sha256   : {0}" -f $gotHash)
    if ($gotHash -ne $srcHash) { throw "回读校验不一致! 写入可能失败" }
    Say "校验一致      : OK"
  } finally {
    $null = [Vol]::DeviceIoControl($hVol, [Vol]::FSCTL_UNLOCK_VOLUME, [IntPtr]::Zero, 0,
              [IntPtr]::Zero, 0, [ref]$r, [IntPtr]::Zero)
    [Vol]::CloseHandle($hVol) | Out-Null
    Say "解锁卷        : 完成"
  }
  Say ("SD_MUSIC_WRITE_DONE: LBA {0}, {1} 扇区" -f $Lba, $Sectors)
  exit 0
} catch {
  Say ("*** 失败: {0}" -f $_.Exception.Message)
  Say ("*** 调用栈: {0}" -f $_.InvocationInfo.PositionMessage)
  exit 1
}
