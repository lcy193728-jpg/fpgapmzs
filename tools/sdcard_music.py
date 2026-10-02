#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ====================================================================
# sdcard_music.py —— TF 卡「裸扇区音乐区」安全写入 + 布局核验助手
#
# 【背景】
#   FPGA 端 sd_card 驱动按【裸 LBA】读扇区, 不解析文件系统:
#     · BMP 素材: bmp_read_auto.v 从 Z_*_START 起每 8 扇区扫 "BM" 头;
#     · 会议配置: meeting_cfg.v 固定读扇区 200000 (MTG1);
#     · 音乐素材: wav_stream_player 固定读 WAV_START_LBA (=300000) 起的
#                 连续 38464 个扇区(裸 PCM, 无文件头)。
#   因此音乐必须写在【卡上无人使用的连续扇区】里。本工具在写之前
#   先把卡的文件系统布局解析清楚, 逐项断言, 再写入并回读校验。
#
# 【为什么必须解析 exFAT】
#   裸写落在 FAT 表 / 分配位图 / 已被文件占用的簇上, 都会破坏卡上原有
#   素材(BMP 与 MTG1 配置)。仅看"目标区当前是全 0"是不够的 —— 必须确认
#   这些簇在 exFAT 分配位图里被标记为【未分配】。
#
# 【LBA 约定(易错点)】
#   本卡为 MBR 单分区(exFAT), 分区物理偏移通常为 2048 扇区。
#   · find_bmp.py 读的是 \\.\F:  → 报告的是【卷内扇区】(相对分区起点);
#   · FPGA 读的是物理扇区。
#   两者相差一个分区偏移。本工具 --probe 会在物理盘上扫 BMP 头, 实测判定
#   Z_* 常量到底是物理 LBA 还是卷内 LBA, 避免音乐区整体错位。
#
# 【用法】(必须【管理员权限】终端; 物理盘访问需要)
#   探测(只读, 不动盘):
#     python tools/sdcard_music.py --disk 1 --lba 300000 --sectors 38464
#   写入(先自动备份被覆盖区, 再写, 再回读校验 sha256):
#     python tools/sdcard_music.py --disk 1 --lba 300000 `
#         --raw audio_final/assets/wel_music_48k_mono.raw --write
# ====================================================================

import argparse
import hashlib
import os
import struct
import sys

SEC = 512

try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass


# --------------------------------------------------------------------
# 工具函数
# --------------------------------------------------------------------
def u16(b, o):
    return struct.unpack_from('<H', b, o)[0]


def u32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def u64(b, o):
    return struct.unpack_from('<Q', b, o)[0]


def read_at(f, lba, nsec):
    f.seek(lba * SEC)
    buf = f.read(nsec * SEC)
    if len(buf) != nsec * SEC:
        raise IOError('读取不足: lba=%d nsec=%d 实际=%d' % (lba, nsec, len(buf)))
    return buf


class Layout(object):
    """从 MBR + exFAT BPB 解析出的卡布局(全部换算为【物理扇区】)"""

    def __init__(self, f, disk_no):
        self.disk_no = disk_no
        self.raw0 = read_at(f, 0, 1)

        # ---- MBR: 取第一个非空分区项 ----
        if self.raw0[510] != 0x55 or self.raw0[511] != 0xAA:
            raise ValueError('扇区 0 无 MBR 签名, 可能卡未分区/格式异常')
        self.part_offset = None
        for i in range(4):
            e = 446 + i * 16
            lba = u32(self.raw0, e + 8)
            nsec = u32(self.raw0, e + 12)
            if lba and nsec:
                self.part_offset = lba
                self.part_sectors = nsec
                break
        if self.part_offset is None:
            raise ValueError('MBR 里没有非空分区项')

        # ---- exFAT Main Boot Sector(分区首扇区) ----
        bs = read_at(f, self.part_offset, 1)
        if bs[3:11] != b'EXFAT   ':
            raise ValueError('分区起点不是 exFAT(实际 fsname=%r); '
                             '本工具仅支持 exFAT, 请先确认卡格式' % bs[3:11])

        self.bpb_part_offset = u64(bs, 64)     # exFAT 自述的分区偏移(通常 0)
        self.volume_length   = u64(bs, 72)
        self.fat_offset      = u32(bs, 80)
        self.fat_length      = u32(bs, 84)
        self.heap_offset     = u32(bs, 88)
        self.cluster_count   = u32(bs, 92)
        self.root_cluster    = u32(bs, 96)
        self.bps_shift       = bs[108]
        self.spc_shift       = bs[109]
        self.num_fats        = bs[110]

        self.bytes_per_sec = 1 << self.bps_shift
        self.sec_per_clu   = 1 << self.spc_shift
        self.clu_bytes     = self.bytes_per_sec * self.sec_per_clu
        if self.bytes_per_sec != SEC:
            raise ValueError('扇区大小 %d != 512, 本工具未支持' % self.bytes_per_sec)

        # ---- 换算成物理扇区 ----
        self.fat_start_phys  = self.part_offset + self.fat_offset
        self.fat_end_phys    = self.fat_start_phys + self.fat_length * self.num_fats
        self.heap_start_phys = self.part_offset + self.heap_offset
        self.heap_end_phys   = self.heap_start_phys + self.cluster_count * self.sec_per_clu

    def clu_of(self, phys_lba):
        """物理扇区 → 簇号(相对簇堆; 簇 n 的首扇区 = heap_start + (n-2)*spc)"""
        return (phys_lba - self.heap_start_phys) // self.sec_per_clu

    def describe(self):
        print('==================== 卡布局(MBR + exFAT) ====================')
        print('  分区物理偏移      : %d 扇区 (=%d 字节)'
              % (self.part_offset, self.part_offset * SEC))
        print('  分区长度          : %d 扇区' % self.part_sectors)
        print('  exFAT 自述分区偏移: %d (0 表示整盘一卷)' % self.bpb_part_offset)
        print('  FAT 区(物理)      : %d ~ %d  (共 %d 份, 每份 %d 扇区)'
              % (self.fat_start_phys, self.fat_end_phys - 1,
                 self.num_fats, self.fat_length))
        print('  簇堆起点(物理)    : %d' % self.heap_start_phys)
        print('  簇堆结束(物理)    : %d' % self.heap_end_phys)
        print('  簇大小            : %d 字节 (%d 扇区/簇)'
              % (self.clu_bytes, self.sec_per_clu))
        print('  簇总数            : %d (%.2f GB 可用簇堆)'
              % (self.cluster_count,
                 self.cluster_count * self.clu_bytes / 1e9))
        print('  分配位图起点簇    : (由根目录 0x81 项给出)')
        print('  卷内扇区 → 物理扇区 = +%d' % self.part_offset)


def pump_header(f, phys_start, step, lba_lo, lba_hi):
    """在 [lba_lo, lba_hi) 里按 step 扇区步进找 "BM" 头, 返回物理起点列表"""
    hits = []
    start = ((lba_lo + step - 1) // step) * step
    lba = start
    while lba < lba_hi:
        if read_at(f, lba, 1)[0:2] == b'BM':
            hits.append(lba)
        lba += step
    return hits


def read_bitmap(lay, f):
    """读根目录, 找 0x81 分配位图项, 返回位图字节串"""
    # 根目录可能跨多个簇; 这里读前 32 个簇足够放下 0x81/0x82/标签项
    clu = lay.root_cluster
    total = 0
    for _ in range(32):
        lba = lay.heap_start_phys + (clu - 2) * lay.sec_per_clu
        d = read_at(f, lba, lay.sec_per_clu)
        for o in range(0, len(d), 32):
            t = d[o]
            if t == 0x81:                       # Allocation Bitmap
                first = u32(d, o + 20)
                dlen = u64(d, o + 24)
                blba = lay.heap_start_phys + (first - 2) * lay.sec_per_clu
                need = (dlen + SEC - 1) // SEC
                return read_at(f, blba, need)[:dlen], first, dlen
            if t == 0x00:                       # 目录项结束
                break
        # 下一簇(FAT 链) —— 用简单线性假设: 根目录通常连续
        clu += 1
        total += 1
    raise ValueError('根目录中未找到 0x81 分配位图项')


def bitmap_allocated(bm, clu):
    """簇 clu(>=2) 的分配位: bit(clu-2), 1=已分配"""
    idx = clu - 2
    return (bm[idx >> 3] >> (idx & 7)) & 1


# --------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description='TF 卡裸扇区音乐区安全写入/核验')
    ap.add_argument('--disk', type=int, default=1, help='物理盘号(默认 1)')
    ap.add_argument('--lba', type=int, default=300000, help='音乐区起始物理扇区')
    ap.add_argument('--sectors', type=int, default=38464, help='音乐区扇区数')
    ap.add_argument('--raw', default=None, help='裸 PCM 文件(写入时必需)')
    ap.add_argument('--write', action='store_true', help='真正写入(缺省只探测)')
    ap.add_argument('--force', action='store_true', help='目标区非全 0 时仍写入')
    a = ap.parse_args()

    dev = r'\\.\PhysicalDrive%d' % a.disk
    print('打开 %s (只读探测) ...' % dev)
    try:
        f = open(dev, 'rb', buffering=0)
    except PermissionError:
        print('*** 打开物理盘被拒绝: 请用【管理员权限】的终端重跑 ***')
        return 2

    lay = Layout(f, a.disk)
    lay.describe()

    # ---------------- 1) 判定 FPGA 读取的 LBA 口径 ----------------
    # FPGA 端 sd_card_sec_read_write.v 直接下发 CMD17(sec_addr) —— 即【物理扇区】。
    # 用两个已知锚点交叉验证: MTG1 配置(应固定物理 200000)与 BMP "BM" 头。
    print('\n==================== 1) LBA 口径实测(物理 vs 卷内) ====================')
    mtg = read_at(f, 200000, 1)[0:4]
    print('  物理扇区 200000 前 4 字节 : %r  ("MTG1" 表示会议配置在此)'
          % mtg)
    fpga_phys = (mtg == b'MTG1')

    print('  在物理扇区 124000~142000 按 8 扇区步进扫 "BM" 头 ...')
    bm = pump_header(f, None, 8, 124000, 142000)
    print('  物理扇区命中 %d 处: %s' % (len(bm), bm[:12]))
    vol = [x - lay.part_offset for x in bm]
    print('  换算成【卷内扇区】    : %s' % vol[:12])

    if fpga_phys:
        print('  → FPGA 口径 = 【物理扇区】(MTG1 锚点证实)')
    else:
        print('  → 注意: 物理 200000 未见 "MTG1", 请人工确认卡上配置位置')

    if bm:
        if 126656 in bm[:2]:
            print('  → top.v 的 Z_* 常量(126656...)是【物理】口径 ✔ 与 FPGA 一致')
        elif 126656 in vol[:2]:
            print('  → *** top.v 的 Z_* 常量(126656...)是【卷内】口径, 但 FPGA 读'
                  '【物理】扇区 → BMP 四分区整体偏移 %d 扇区(约 %.1f MB)! '
                  '每个 Z_* 需 +%d 才正确 (find_bmp.py 读 \\\\.\\F: 得卷内值, '
                  '粘进 top.v 前未加分区偏移) ***'
                  % (lay.part_offset, lay.part_offset * SEC / 1e6,
                     lay.part_offset))
        else:
            print('  → 与 126656 不符, 请人工核对(卡可能已换素材)')
    else:
        print('  → 未命中 BM 头, 无法判定(卡上可能没有素材)')

    print('  ※ 音乐区(本工具 --lba)一律按【物理扇区】书写, 与 FPGA 一致,'
          ' 不受上述 Z_* 口径问题影响。')

    # ---------------- 2) 音乐区落位核验 ----------------
    print('\n==================== 2) 音乐区落位核验 ====================')
    lba0 = a.lba
    lba1 = a.lba + a.sectors              # 开区间
    print('  目标物理扇区区间 : [%d, %d)  共 %d 扇区 (%.2f MB)'
          % (lba0, lba1, a.sectors, a.sectors * SEC / 1e6))

    errs = []
    if lba0 < lay.heap_end_phys and lba0 >= lay.heap_start_phys:
        pass
    else:
        errs.append('目标起点不在簇堆范围内')
    if lba1 > lay.heap_end_phys:
        errs.append('目标终点越过簇堆末端(卡容量不足)')
    if not (lba1 <= lay.fat_start_phys or lba0 >= lay.fat_end_phys):
        errs.append('目标区与 FAT 表区 [%d,%d) 重叠 —— 会毁文件系统!'
                    % (lay.fat_start_phys, lay.fat_end_phys))
    if lba1 - 1 >= lay.heap_end_phys:
        errs.append('目标区越过卡容量')

    c0 = lay.clu_of(lba0)
    c1 = lay.clu_of(lba1 - 1)
    print('  对应簇号范围     : %d ~ %d  (共 %d 簇)'
          % (c0, c1, c1 - c0 + 1))
    print('  簇堆剩余空间     : 目标终点后还有 %d 扇区 (%.1f MB)'
          % (lay.heap_end_phys - lba1,
             (lay.heap_end_phys - lba1) * SEC / 1e6))

    if not errs:
        bmd, bfirst, bdlen = read_bitmap(lay, f)
        print('  分配位图         : 首簇 %d, 长度 %d 字节(覆盖 %d 簇)'
              % (bfirst, bdlen, bdlen * 8))
        used_bits = sum(bin(x).count('1') for x in bmd)
        print('  位图已置位数     : %d 簇 (=%.2f MB 已用)'
              % (used_bits, used_bits * lay.clu_bytes / 1e6))
        if c1 >= bdlen * 8:
            errs.append('目标簇号超出位图覆盖范围, 无法确认是否空闲')
        else:
            bad = [c for c in range(c0, c1 + 1) if bitmap_allocated(bmd, c)]
            if bad:
                errs.append('目标区有 %d 个簇已被文件系统占用(例: 簇 %s) —— '
                            '写入会破坏卡上文件!' % (len(bad), bad[:8]))
            else:
                print('  → 目标区全部 %d 个簇在位图中均为【未分配】 ✔'
                      % (c1 - c0 + 1))

    if errs:
        print('\n*** 核验未通过, 拒绝写入: ***')
        for e in errs:
            print('   - %s' % e)
        f.close()
        return 3

    # ---------------- 3) 目标区当前内容 ----------------
    print('\n==================== 3) 目标区当前内容 ====================')
    CH = 4096
    zeros = True
    nz_examples = []
    lba = lba0
    while lba < lba1:
        n = min(CH, lba1 - lba)
        blk = read_at(f, lba, n)
        if any(blk):
            zeros = False
            if len(nz_examples) < 3:
                nz_examples.append((lba, blk[:16].hex()))
        lba += n
    if zeros:
        print('  目标区当前全为 0 → 是空白区, 无数据可丢 ✔')
    else:
        print('  目标区存在非 0 数据, 例: %s' % nz_examples)
        print('  （若确认这些扇区对 FPGA 无用, 加 --force 覆盖）')

    if not a.write:
        print('\n[探测模式] 未写入任何数据。加 --write 执行写入。')
        f.close()
        return 0

    # ---------------- 4) 写入 ----------------
    if not a.raw:
        print('\n*** --write 必须配合 --raw <裸PCM文件> ***')
        f.close()
        return 1
    if not os.path.isfile(a.raw):
        print('\n*** 找不到文件 %s ***' % a.raw)
        f.close()
        return 1
    raw_len = os.path.getsize(a.raw)
    h = hashlib.sha256()
    with open(a.raw, 'rb') as g:
        for chunk in iter(lambda: g.read(1 << 20), b''):
            h.update(chunk)
    src_sha = h.hexdigest()
    print('\n==================== 4) 写入 ====================')
    print('  源文件        : %s' % a.raw)
    print('  源文件长度    : %d 字节 (%d 扇区, 余 %d 字节)'
          % (raw_len, raw_len // SEC, raw_len % SEC))
    print('  源 sha256     : %s' % src_sha)
    if raw_len % SEC:
        print('*** 源文件长度不是 512 的整数倍, 写入后尾部不完整 ***')
        f.close()
        return 1
    if raw_len > a.sectors * SEC:
        print('*** 源文件超出预留扇区数(%d) ***' % a.sectors)
        f.close()
        return 1
    if not zeros and not a.force:
        print('*** 目标区非空, 拒绝写入(加 --force 强制) ***')
        f.close()
        return 1

    f.close()
    fw = open(dev, 'r+b', buffering=0)
    try:
        fw.seek(lba0 * SEC)
        wrote = 0
        with open(a.raw, 'rb') as g:
            while True:
                chunk = g.read(1 << 20)
                if not chunk:
                    break
                fw.write(chunk)
                wrote += len(chunk)
        fw.flush()
        os.fsync(fw.fileno())
        print('  已写入 %d 字节' % wrote)
    finally:
        fw.close()

    # ---------------- 5) 回读校验 ----------------
    print('\n==================== 5) 回读校验 ====================')
    f = open(dev, 'rb', buffering=0)
    h2 = hashlib.sha256()
    lba = lba0
    remain = raw_len
    while remain > 0:
        n = min(CH, (remain + SEC - 1) // SEC)
        blk = read_at(f, lba, n)[:min(remain, n * SEC)]
        h2.update(blk)
        lba += n
        remain -= len(blk)
    f.close()
    got = h2.hexdigest()
    print('  回读 sha256   : %s' % got)
    if got == src_sha:
        print('  → 校验一致 ✔  音乐区写入完成 (LBA %d, %d 扇区)'
              % (lba0, raw_len // SEC))
        return 0
    print('  *** 校验不一致 —— 写入失败, 请重试 ***')
    return 4


if __name__ == '__main__':
    sys.exit(main())
