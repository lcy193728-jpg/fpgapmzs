<#
------------------------------------------------------------------------------
 write_meeting_card.ps1 -- 把会议议程配置 meeting.bin(MTG1 字节流)写入 TF 卡
                          的固定扇区, 供 FPGA 上板后 meeting_sd_rd 直接按扇区号读取。

 为什么用"裸扇区写"而不是拷文件:
   板上 meeting_sd_rd.v 不做 FAT 文件系统解析, 它只认 **LBA 绝对扇区号**;
   top.v 里给出的起始扇区是 32'd200000(见 src/top.v 的 .mtg_start_sector)。
   所以必须把 meeting.bin 的原始字节写到卡的 LBA 200000 处, 与文件系统无关。
   素材区(BMP)最大只用到 135704, 200000 起 3 个扇区不会与其冲突。

 扇区布局(可调 -StartSector):
   LBA 200000 : 字节   0..511   (MTG1 头 + 前 512 字节, 扇区 0)
   LBA 200001 : 字节 512..1023  (扇区 1)
   LBA 200002 : 字节1024..1535  (扇区 2, 仅在配置 >1024B 时用; 当前 6 项 = 657B)

 MTG1 格式(与 src/meeting_sd_rd.v 的解析规则严格一致):
   [0..3]  魔数 'M''T''G''1'
   [4]     议程项数 1..16
   [5..]   配置体, 落 RAM 偏移 = 文件偏移 - 5:
             +0   .. +39    会议名称        (40B)
             +40  .. +79    主办单位        (40B)
             +80  .. +119   报到地点        (40B)
             +120 .. +279   注意事项 4 页   (每页 40B)
             +280 + i*62 .. 第 i 项: +0/+1 时长秒(大端, 1..5999)
                                      +2..+41 名称 (40B)
                                      +42..+61 发言人(20B)
   配置体总长 = 项数 * 62, 文件总长需 >= 5 + 项数*62
   (当前 meeting.json 6 项 -> 5 + 372 = 377B <= 1024B, 合法)

 用法:
   1) 插上读卡器, 先列出磁盘号(不需要管理员):
        powershell -ExecutionPolicy Bypass -File .\write_meeting_card.ps1 -List
      确认哪一个是你的 TF 卡(看 大小/型号, 别选成系统盘)。
   2) 以 **管理员** 身份打开 PowerShell, 执行(把 2 换成上一步看到的磁盘号):
        powershell -ExecutionPolicy Bypass -File .\write_meeting_card.ps1 -DiskNumber 2 -ConfirmWrite
   3) 脚本写完会自动回读校验, 打印逐扇区比对结果。

 安全措施:
   * -List 只读不写;
   * 真正写入必须同时给 -DiskNumber 和 -ConfirmWrite;
   * 自动拒绝写系统盘/启动盘(Get-Disk 的 IsSystem/IsBoot);
   * 写入前打印磁盘型号+容量, 并要求输入 YES 二次确认(可加 -Yes 跳过);
   * 写入长度按 512 对齐, 只覆盖 StartSector 起的连续扇区, 不动其它区域。

 为什么"裸写物理盘"会被拒绝(2026-09-19 实测踩到):
   Windows 有一条硬限制 —— 目标扇区只要落在某个**已挂载卷**内, 写操作
   就返回 ERROR_ACCESS_DENIED。而且 `[IO.File]::Open("\\.\PhysicalDriveN")`
   会**假装成功**, 直到 Write/Flush/Dispose 才抛
   "对路径的访问被拒绝(UnauthorizedAccessException)"。
   本卡 F: 卷范围 = LBA 2048..122142720, 目标 LBA 200000 正在其中,
   所以脚本会先对卷发 FSCTL_LOCK_VOLUME + FSCTL_DISMOUNT_VOLUME 把它卸载
   (文件系统下线, 盘符挂载点保留), 再写物理盘, 写完 FSCTL_UNLOCK_VOLUME 交还。
   如遇"锁定卷失败", 请先关掉资源管理器里该卡的窗口 / 杀毒扫描 / 索引服务,
   或直接拔下读卡器再插上。
   写完后读卡器可能需要重新拔插一次, Windows 才会重新挂载 F:。

 ⚠ 注意: 目标 LBA 200000 落在 F: 文件系统数据区内, 裸写会破坏该位置原本
   属于某个文件的数据。这与本项目 BMP 素材(裸扇区 126000 起)是同一套做法;
   若之后用 Windows 往卡里拷素材, 拷完请重跑本脚本一次。
------------------------------------------------------------------------------
#>
[CmdletBinding()]
param(
    # 目标物理磁盘号(Get-Disk 的 Number)。与 -List 配合确定。
    [int]    $DiskNumber   = -1,

    # 起始 LBA 扇区。必须与 src/top.v 的 .mtg_start_sector 完全一致。
    [int]    $StartSector  = 200000,

    # 待写入的配置字节流。默认取仿真工程生成的 meeting.bin。
    [string] $Bin = '',

    # 列出本机物理磁盘后退出(只读, 不需要管理员)。
    [switch] $List,

    # 真正执行写入的开关(缺省只做检查并打印将要做什么, 不落盘)。
    [switch] $ConfirmWrite,

    # 跳过交互式 YES 二次确认(用于脚本化/批处理)。
    [switch] $Yes,

    # 只回读校验, 不写入(用于确认卡上已有内容是否正确)。
    [switch] $VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SECTOR = 512

#------------------------------------------------------------------
# 工具函数
#------------------------------------------------------------------
function Fail([string]$msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

function Show-Disks {
    Write-Host "本机物理磁盘:" -ForegroundColor Cyan
    Get-Disk | Sort-Object Number | Format-Table `
        @{n='磁盘号';e={$_.Number}},
        @{n='型号';e={$_.FriendlyName}},
        @{n='容量GB';e={[math]::Round($_.Size/1GB,1)}},
        @{n='分区表';e={$_.PartitionStyle}},
        @{n='系统盘';e={$_.IsSystem}},
        @{n='启动盘';e={$_.IsBoot}},
        @{n='总线';e={$_.BusType}} -AutoSize
    Write-Host "提示: 读卡器里的 TF 卡通常 BusType=USB, 容量即卡的容量。" -ForegroundColor DarkGray
}

function Get-MeetingBin([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { Fail "找不到输入文件: $path" }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 5) { Fail "文件太小($($bytes.Length) B), 不是 MTG1 配置" }

    # ---- 校验魔数 ----
    $magic = [Text.Encoding]::ASCII.GetString($bytes, 0, 4)
    if ($magic -ne 'MTG1') { Fail "魔数不是 'MTG1' 而是 '$magic', 拒绝写入(避免写坏卡)" }

    # ---- 校验项数与长度 ----
    $total  = [int]$bytes[4]
    if ($total -lt 1 -or $total -gt 16) { Fail "议程项数非法: $total (合法 1..16)" }
    $need   = 5 + $total * 62
    if ($bytes.Length -lt $need) {
        Fail "文件长度不足: 需要 $need B ($total 项), 实际只有 $($bytes.Length) B"
    }

    # ---- 补齐到 512 整数倍(板上按扇区读, 尾部补 0 不影响解析) ----
    $padLen = [int]([math]::Ceiling($bytes.Length / $SECTOR) * $SECTOR)
    if ($padLen -ne $bytes.Length) {
        $buf = New-Object byte[] $padLen
        [Array]::Copy($bytes, $buf, $bytes.Length)
        Write-Host ("补齐: {0} B -> {1} B (尾部补 0x00)" -f $bytes.Length, $padLen) -ForegroundColor DarkGray
        $bytes = $buf
    }

    $info = [pscustomobject]@{
        Path     = (Resolve-Path -LiteralPath $path).Path
        Bytes    = $bytes
        RawLen   = $bytes.Length
        Total    = $total
        Sectors  = $padLen / $SECTOR
        NeedBody = $need
    }
    return $info
}

#------------------------------------------------------------------
# 卷锁定 / 卸载
#
# 为什么必须做:
#   Windows 对"裸扇区写物理盘"有一条硬限制 —— 只要目标扇区落在某个
#   **已挂载卷**的范围内, 写操作就会被拒绝。而且拒绝的时机很坑:
#   `[IO.File]::Open("\\.\PhysicalDriveN")` 会**成功**, 直到 Write/Flush/
#   Dispose 时才抛 "对路径的访问被拒绝(UnauthorizedAccessException)"。
#   本卡的 F: 卷范围 = LBA 2048..122142720, 而目标 LBA 200000 正在其中,
#   所以必须先对该卷发 FSCTL_LOCK_VOLUME + FSCTL_DISMOUNT_VOLUME 把它
#   卸下(文件系统下线, 但盘符挂载点保留), 之后写物理盘才被允许;
#   写完再 FSCTL_UNLOCK_VOLUME 交还。
#   这与 Win32DiskImager / dd for Windows 的做法完全一致。
#   注意: 卸载会失败于"卷上有打开的文件句柄"——请先关掉资源管理器里该卡
#        的窗口、杀毒扫描、以及任何占用该盘的程序。
#------------------------------------------------------------------
if (-not ('RawVol' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RawVol
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
        IntPtr lpInBuffer, uint nInBufferSize, IntPtr lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    public const uint GENERIC_READ      = 0x80000000;
    public const uint GENERIC_WRITE     = 0x40000000;
    public const uint FILE_SHARE_READ   = 0x00000001;
    public const uint FILE_SHARE_WRITE  = 0x00000002;
    public const uint OPEN_EXISTING     = 3;
    public const uint FSCTL_LOCK_VOLUME     = 0x00090018;
    public const uint FSCTL_UNLOCK_VOLUME   = 0x0009001C;
    public const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;

    public static IntPtr OpenVolume(string path)
    {
        return CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
    }
    public static bool Lock(IntPtr h)     { uint b; return DeviceIoControl(h, FSCTL_LOCK_VOLUME,     IntPtr.Zero, 0, IntPtr.Zero, 0, out b, IntPtr.Zero); }
    public static bool Unlock(IntPtr h)   { uint b; return DeviceIoControl(h, FSCTL_UNLOCK_VOLUME,   IntPtr.Zero, 0, IntPtr.Zero, 0, out b, IntPtr.Zero); }
    public static bool Dismount(IntPtr h) { uint b; return DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out b, IntPtr.Zero); }
}
'@
}

# 打开盘上所有卷并锁定+卸载; 返回句柄数组(交给 Unlock-Volumes 释放)
function Lock-DiskVolumes {
    param([int]$DiskNumber)

    $opened = New-Object System.Collections.Generic.List[object]
    $parts  = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)

    foreach ($p in $parts) {
        # 候选设备路径: 优先盘符形式, 其次卷 GUID 形式
        $cands = @()
        if ($p.DriveLetter) { $cands += "\\.\$($p.DriveLetter):" }
        foreach ($ap in @($p.AccessPaths)) {
            if ($ap -and $ap -match '^\\\\\?\\Volume\{') { $cands += $ap.TrimEnd('\') }
        }
        if ($cands.Count -eq 0) { continue }

        foreach ($dev in $cands) {
            $h = [RawVol]::OpenVolume($dev)
            if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr](-1)) { continue }

            if (-not [RawVol]::Lock($h)) {
                $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                # 0x80070015 = ERROR_NOT_READY(可移动盘空卷), 其余多为"卷被占用"
                [RawVol]::CloseHandle($h) | Out-Null
                Write-Host ("  [警告] 锁定卷 {0} 失败 (Win32={1}); 若稍后写入被拒, 请关闭占用该卡的窗口后重试。" -f $dev, $err) -ForegroundColor Yellow
                continue
            }
            if (-not [RawVol]::Dismount($h)) {
                $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Write-Host ("  [警告] 卸载卷 {0} 失败 (Win32={1})。" -f $dev, $err) -ForegroundColor Yellow
            } else {
                Write-Host ("  已锁定并卸载卷 {0}" -f $dev) -ForegroundColor DarkGray
            }
            $opened.Add([pscustomobject]@{ Handle = $h; Dev = $dev })
            break       # 一个分区拿到一个可用句柄即可
        }
    }
    # 前导逗号: 阻止 PowerShell 把 List 拆包成"单对象/数组",
    #   否则只有一个卷时调用方拿到的是裸 pscustomobject, .Count 会报错。
    return ,$opened
}

function Unlock-Volumes($handles) {
    foreach ($o in $handles) {
        [RawVol]::Unlock($o.Handle) | Out-Null
        [RawVol]::CloseHandle($o.Handle) | Out-Null
    }
}

#------------------------------------------------------------------
# -List: 只列出磁盘
#------------------------------------------------------------------
if ($List) {
    Show-Disks
    Write-Host ""
    Write-Host "选定磁盘号后执行(需管理员):" -ForegroundColor Yellow
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -DiskNumber <N> -ConfirmWrite"
    exit 0
}

#------------------------------------------------------------------
# 1. 准备数据
#------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Bin)) {
    $Bin = Join-Path $PSScriptRoot '..\..\fpgapmzs_audio\meeting_scene3_sim\assets\meeting.bin'
    $Bin = [IO.Path]::GetFullPath($Bin)
}

Write-Host "=== 会议议程写卡 ===" -ForegroundColor Cyan
$cfg = Get-MeetingBin $Bin
Write-Host ("输入文件 : {0}" -f $cfg.Path)
Write-Host ("议程项数 : {0}" -f $cfg.Total)
Write-Host ("字节数   : {0} B  = {1} 扇区" -f $cfg.RawLen, $cfg.Sectors)
Write-Host ("起始扇区 : LBA {0} (字节偏移 {1})" -f $StartSector, ($StartSector * $SECTOR))
Write-Host ("占用区间 : LBA {0} .. {1}" -f $StartSector, ($StartSector + $cfg.Sectors - 1))

#------------------------------------------------------------------
# 2. 检查目标磁盘
#------------------------------------------------------------------
if ($DiskNumber -lt 0) { Fail "未指定 -DiskNumber。先运行 -List 找出 TF 卡的磁盘号。" }

try {
    $disk = Get-Disk -Number $DiskNumber
} catch {
    Fail "磁盘 $DiskNumber 不存在: $($_.Exception.Message)"
}

Write-Host ""
Write-Host ("目标磁盘 : #{0}  {1}  {2} GB  ({3})" -f `
    $disk.Number, $disk.FriendlyName, [math]::Round($disk.Size/1GB,1), $disk.BusType) -ForegroundColor Yellow

if ($disk.IsSystem -or $disk.IsBoot) {
    Fail "磁盘 $DiskNumber 是系统/启动盘, 拒绝写入。请核对 -List 的输出。"
}

$byteOff   = [long]$StartSector * $SECTOR
$endOff    = $byteOff + $cfg.Sectors * $SECTOR
if ($endOff -gt [long]$disk.Size) {
    Fail ("写入区间超出磁盘范围: 需要到字节 {0}, 磁盘只有 {1} 字节" -f $endOff, $disk.Size)
}

# 卷信息(仅提示, 不阻塞)
$vols = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
        Where-Object DriveLetter |
        ForEach-Object { "$($_.DriveLetter):" }
if ($vols) {
    Write-Host ("该盘上的卷 : {0}  (裸扇区写不会改动文件系统结构, 但会覆盖写到的扇区)" -f ($vols -join ' ')) -ForegroundColor DarkGray
}

$devPath = "\\.\PhysicalDrive$DiskNumber"

#------------------------------------------------------------------
# 3. -VerifyOnly: 只回读比对
#------------------------------------------------------------------
if ($VerifyOnly) {
    Write-Host ""
    Write-Host "=== 只读校验 ===" -ForegroundColor Cyan
    # 读物理盘也可能被"已挂载卷"挡住, 故同样先锁定+卸载
    $vols = @()
    try {
        $vols = @(Lock-DiskVolumes -DiskNumber $DiskNumber)
        $fs = [IO.File]::Open($devPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $fs.Seek($byteOff, [IO.SeekOrigin]::Begin) | Out-Null
            $rb = New-Object byte[] ($cfg.Sectors * $SECTOR)
            $got = 0
            while ($got -lt $rb.Length) {
                $n = $fs.Read($rb, $got, $rb.Length - $got)
                if ($n -le 0) { break }
                $got += $n
            }
        } finally {
            try { $fs.Dispose() } catch { }
        }
    } finally { Unlock-Volumes $vols }

    $bad = 0
    for ($i = 0; $i -lt [math]::Min($got, $cfg.Bytes.Length); $i++) {
        if ($rb[$i] -ne $cfg.Bytes[$i]) { $bad++ }
    }
    if ($got -ne $rb.Length) { Write-Host "读取字节数不足: $got / $($rb.Length)" -ForegroundColor Red }
    if ($bad -eq 0 -and $got -eq $rb.Length) {
        Write-Host "校验通过: LBA $StartSector 起的 $($cfg.Sectors) 个扇区与 $([IO.Path]::GetFileName($cfg.Path)) 完全一致。" -ForegroundColor Green
        exit 0
    } else {
        Fail "校验失败: $bad 字节不一致 (读到 $got 字节)"
    }
}

#------------------------------------------------------------------
# 4. 写入
#------------------------------------------------------------------
if (-not $ConfirmWrite) {
    Write-Host ""
    Write-Host "当前为预演模式(未落盘)。确认无误后加上 -ConfirmWrite 重新执行:" -ForegroundColor Yellow
    Write-Host ("  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -DiskNumber {0} -ConfirmWrite" -f $DiskNumber)
    exit 0
}

if (-not $Yes) {
    Write-Host ""
    Write-Host ("即将把 {0} 字节写入 磁盘#{1} ({2}) 的 LBA {3}..{4}。" -f `
        $cfg.RawLen, $disk.Number, $disk.FriendlyName, $StartSector, ($StartSector + $cfg.Sectors - 1)) -ForegroundColor Yellow
    Write-Host "目标扇区原有内容将被覆盖, 且不可撤销!" -ForegroundColor Red
    $ans = Read-Host "确认请输入大写 YES"
    if ($ans -ne 'YES') { Write-Host "已取消。" -ForegroundColor DarkGray; exit 0 }
}

Write-Host ""
Write-Host "=== 写入 ===" -ForegroundColor Cyan
Write-Host "先锁定并卸载该盘上的卷(否则写物理盘会被 Windows 拒绝)..." -ForegroundColor DarkGray
$vols = @()
try {
    $vols = @(Lock-DiskVolumes -DiskNumber $DiskNumber)
    if ($vols.Count -eq 0) {
        Write-Host "  [警告] 没有成功锁定任何卷; 若下面写入报 Access Denied, 请关闭占用该卡的窗口后重试。" -ForegroundColor Yellow
    }

    try {
        $fs = [IO.File]::Open($devPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    } catch {
        Fail ("无法打开 {0}: {1}`n  * 请确认以【管理员】身份运行 PowerShell;`n  * 并关闭资源管理器/其他程序中该卡的窗口后重试。" -f $devPath, $_.Exception.Message)
    }

    try {
        $fs.Seek($byteOff, [IO.SeekOrigin]::Begin) | Out-Null
        $fs.Write($cfg.Bytes, 0, $cfg.Bytes.Length)
        $fs.Flush($true)
    } catch {
        Fail ("写入失败: {0}`n  * 常见原因: 卷仍被占用(资源管理器窗口/杀毒扫描/索引服务)。`n  * 处理: 关掉该卡的所有窗口, 或直接把读卡器拔下再插上后重跑本脚本。" -f $_.Exception.Message)
    } finally {
        # Dispose 会隐含 Flush: 写入被拒时异常正是在这里抛出, 故必须吞掉,
        # 由上面的 catch 统一给出可读的诊断信息。
        try { $fs.Dispose() } catch { }
    }
} finally {
    # 无论成功/失败/抛异常, 都必须交还卷, 否则 F: 会一直处于"已卸载"状态
    Unlock-Volumes $vols
}
Write-Host ("已写入 {0} 字节到 LBA {1}。" -f $cfg.Bytes.Length, $StartSector) -ForegroundColor Green

#------------------------------------------------------------------
# 5. 回读校验
#------------------------------------------------------------------
Write-Host ""
Write-Host "=== 回读校验 ===" -ForegroundColor Cyan
$rb  = $null
$got = 0
try {
    $fs = [IO.File]::Open($devPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $fs.Seek($byteOff, [IO.SeekOrigin]::Begin) | Out-Null
        $rb = New-Object byte[] $cfg.Bytes.Length
        while ($got -lt $rb.Length) {
            $n = $fs.Read($rb, $got, $rb.Length - $got)
            if ($n -le 0) { break }
            $got += $n
        }
    } finally {
        try { $fs.Dispose() } catch { }
    }
} catch {
    Write-Host ("  [警告] 回读打不开设备(卷刚被卸载, 可能需重新枚举): {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    Write-Host "  请把读卡器拔下再插上, 然后跑 -VerifyOnly 复验。" -ForegroundColor Yellow
    exit 0
}

if ($got -ne $rb.Length) { Fail "回读字节数不足: $got / $($rb.Length)" }
$bad = 0
for ($i = 0; $i -lt $rb.Length; $i++) {
    if ($rb[$i] -ne $cfg.Bytes[$i]) { $bad++ }
}
if ($bad -ne 0) { Fail "回读不一致: $bad / $($rb.Length) 字节" }

Write-Host ("校验通过: LBA {0} 起 {1} 个扇区与源文件逐字节一致。" -f $StartSector, $cfg.Sectors) -ForegroundColor Green
Write-Host ""
Write-Host "完成。可插卡上板: 会议模式将读取该配置(首次上电读到配置即 ready)。" -ForegroundColor Green
Write-Host "提示: 若资源管理器里看不到 F: 盘符了, 把读卡器拔下再插上即可恢复。" -ForegroundColor DarkGray
