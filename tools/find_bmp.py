#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ====================================================================
# find_bmp.py —— TF 卡 BMP 素材「扇区定位 + 分区排布」助手
#
# 【背景 / 为什么需要它】
#   本工程不解析文件系统: bmp_read_auto.v 按【每 8 扇区(4096B)跳一次】
#   扫描 "BM" 文件头; 读完整张图后, 下一次扫描从「当前扇区向上取整到
#   8 扇区边界」继续(见 bmp_read_auto.v S_HOLD 分支)。
#   因此有两个硬约束:
#     · 每张合格图的起始扇区必须落在 8 扇区的整数倍格点上;
#     · 同一分区的图片必须在卡上【连续排布】(顺序 = 拷贝顺序)。
#   一张 640×480×24bit BMP = 921654B ≈ 1801 扇区, 不是 8 的倍数;
#   只有当卡按 >=4KB 簇(FAT32/exFAT 默认)分配时, 每张图占 1808 扇区
#   (8 的整数倍) 且起点天然对齐 —— 这是能逐张扫到的前提条件。
#
# 【用途】
#   1) 扫物理盘, 列出卡上所有【严格合格】的 640×480/24bit BMP 起始扇区;
#   2) 按 --sizes 给出的每段张数自动切分成各场景分区, 计算
#      {START, WRAP, IMGS}, 并直接打印【可粘贴进 top.v】的 localparam;
#   3) 列出「命中 BM 但不合格」的扇区(删除残留/尺寸不符) → 排查花屏。
#
# 【用法】(需在【管理员权限】终端运行, 物理盘读取要管理员)
#   python tools/find_bmp.py --drive F
#   python tools/find_bmp.py --drive F --start 126000 --end 400000 --sizes 5,5,5
#   python tools/find_bmp.py --drive F --all            # 只列合格图, 不切段
#
# 【参数】
#   --drive  物理盘符(不带冒号), 如 F
#   --start  扫描起始扇区, 默认 16000 (自动向上取整到 8 的倍数)
#   --end    扫描结束扇区, 0=自动(连续 1GB 无新命中即停), 默认 0
#   --sizes  各段张数, 逗号分隔, 默认 5,5,5 (迎新/会议/抢答)
#   --names  各段名称, 逗号分隔, 默认 WEL,MEET,QUIZ (决定输出的 Z_* 前缀)
#   --all    只列合格图, 不做分段/不输出 localparam
#
# 【WRAP 语义】(与 bmp_read_auto.v 一致)
#   扫描中若 addr >= WRAP 则回卷到 START。故每段 WRAP 取「下一段首张图
#   起点」最安全(绝不会串到下一段); 最后一段取「本段末张 + 8 扇区」。
# ====================================================================

import argparse
import struct
import sys

SEC   = 512                              # 扇区字节数
ALIGN = 8                                # 扫描步进(扇区) —— 必须与 RTL 一致
CHUNK = 8192                             # 每次读盘块大小(扇区)=4MB, 需为 ALIGN 倍数
MISS_LIMIT = 256                         # --end 0 时: 连续 256 块(=1GB)无命中即停
HDR   = 54                               # BMP 文件头字节数

EXP_LEN = 921654                         # 期望文件长度 = 54 + 640*480*3
EXP_W   = 640
EXP_H   = 480
EXP_BIT = 24

try:                                     # Windows 控制台中文输出兜底
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass


def parse_args():
    p = argparse.ArgumentParser(
        description='TF 卡 BMP 素材扇区定位 / 分区排布助手',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--drive', required=True, help='物理盘符(不带冒号), 如 F')
    p.add_argument('--start', type=int, default=16000, help='扫描起始扇区(默认 16000)')
    p.add_argument('--end',   type=int, default=0,     help='扫描结束扇区(0=自动, 默认 0)')
    p.add_argument('--sizes', default='5,5,5',         help='各段张数(默认 5,5,5)')
    p.add_argument('--names', default='WEL,MEET,QUIZ',  help='各段名称(默认 WEL,MEET,QUIZ)')
    p.add_argument('--all',   action='store_true',     help='只列合格图, 不分段')
    return p.parse_args()


def probe(buf, off):
    """检查 buf 偏移 off(字节) 处是否为 BMP 头; 返回 (file_len,w,h,bit) 或 None"""
    if off + HDR > len(buf):
        return None
    if buf[off] != 0x42 or buf[off + 1] != 0x4D:      # 'B' 'M'
        return None
    fl = struct.unpack_from('<I', buf, off + 2)[0]    # 文件长度
    w  = struct.unpack_from('<I', buf, off + 18)[0]   # 宽
    h  = struct.unpack_from('<i', buf, off + 22)[0]   # 高(有符号; 负=自上而下)
    b  = struct.unpack_from('<H', buf, off + 28)[0]   # 位深
    return (fl, w, h, b)


def why_bad(fl, w, h, b):
    """返回不合格原因列表(用于排查花屏/误判残留)"""
    r = []
    if fl != EXP_LEN:  r.append('长度%d≠%d' % (fl, EXP_LEN))
    if w  != EXP_W:    r.append('宽%d≠%d'  % (w,  EXP_W))
    if h  != EXP_H:    r.append('高%d≠%d(负值=自上而下存储)' % (h, EXP_H))
    if b  != EXP_BIT:  r.append('位深%d≠%d' % (b, EXP_BIT))
    return r


def scan(drive, start, end):
    """逐块扫描, 每 ALIGN 扇区检查一次 BMP 头; 返回 (hits, bads)"""
    f = open(drive, 'rb', buffering=0)
    hits = []        # 合格图起始扇区(升序)
    bads = []        # (扇区, 原因串)
    sec = start
    miss_blocks = 0
    while True:
        if end and sec >= end:
            break
        n = CHUNK if not end else min(CHUNK, end - sec)
        if n <= 0:
            break
        f.seek(sec * SEC)
        buf = f.read(n * SEC)
        if not buf:
            break
        got = 0
        for off in range(0, n, ALIGN):                # 全局对齐: sec 已是 ALIGN 倍数
            i = off * SEC
            if i + HDR > len(buf):
                break
            hd = probe(buf, i)
            if hd is None:
                continue
            fl, w, h, b = hd
            if fl == EXP_LEN and w == EXP_W and h == EXP_H and b == EXP_BIT:
                hits.append(sec + off)
                got += 1
            else:
                bads.append((sec + off, ' '.join(why_bad(fl, w, h, b))))
        sec += n
        if not end:                                   # 自动停止: 连续无命中超限
            miss_blocks = 0 if got else miss_blocks + 1
            if miss_blocks >= MISS_LIMIT:
                break
    f.close()
    return hits, bads


def build_zones(hits, sizes):
    """把合格图按 sizes 切分成段。
    返回 [(张数, START, WRAP, 首张序号, 末张序号)]; 调用前须保证
    len(hits) >= sum(sizes)。WRAP 取下一段首张起点(末段取末张+8)，
    与 bmp_read_auto.v「addr >= WRAP 即回卷 START」的语义一致。"""
    zones = []
    idx = 0
    for k, cnt in enumerate(sizes):
        seg = hits[idx:idx + cnt]
        idx += cnt
        st = seg[0]
        wr = hits[idx] if (k + 1 < len(sizes)) else (seg[-1] + ALIGN)
        zones.append((cnt, st, wr, idx - cnt + 1, idx))
    return zones


def main():
    a = parse_args()

    # ---- 起点对齐到 ALIGN 倍数(否则块内格点会整体错位) ----
    start = ((a.start + ALIGN - 1) // ALIGN) * ALIGN
    if start != a.start:
        print('[提示] 起始扇区 %d 已向上取整到 %d (必须 %d 扇区对齐)'
              % (a.start, start, ALIGN))
    drive = '\\\\.\\%s:' % a.drive.replace(':', '')

    sizes = [int(x) for x in a.sizes.split(',') if x.strip() != '']
    names = [x.strip() for x in a.names.split(',') if x.strip() != '']

    print('==== 扫描 %s 扇区 %d~%s (每 %d 扇区步进) ===='
          % (drive, start, ('%d' % a.end) if a.end else '盘末/自动停止', ALIGN))
    try:
        hits, bads = scan(drive, start, a.end)
    except PermissionError:
        print('*** 打开物理盘失败: 请用【管理员权限】的终端运行 ***')
        return 1
    except FileNotFoundError:
        print('*** 找不到 %s: 请确认盘符/读卡器已插入 ***' % drive)
        return 1

    # ---------------- 1) 合格图清单 ----------------
    print('\n==================== 1) 合格图清单(%d 张) ====================' % len(hits))
    print('  #    起始扇区     8扇区对齐   文件长度     分辨率     位深')
    nbad_align = 0
    for i, s in enumerate(hits, 1):
        al = (s % ALIGN) == 0
        if not al:
            nbad_align += 1
        print('  %-4d %-12d %-10s %-11d %-10s %d'
              % (i, s, 'OK' if al else '*** 未对齐', EXP_LEN, '%dx%d' % (EXP_W, EXP_H), EXP_BIT))
    if hits:
        print('  → 首张 %d, 末张 %d, 跨 %d 扇区' % (hits[0], hits[-1], hits[-1] - hits[0]))
    if len(hits) >= 2:
        gaps = [hits[i + 1] - hits[i] for i in range(len(hits) - 1)]
        print('  → 相邻起点间隔(扇区): %s' % ', '.join(str(g) for g in gaps))
        if min(gaps) < 1801:
            print('  → *** 警告: 存在间隔 <1801 扇区, 图片可能重叠/被截断, 请重做素材 ***')
        elif all(g % ALIGN == 0 for g in gaps):
            print('  → 间隔均 >=1801 且为 %d 的倍数 → 起点对齐正常(间隔=1808 表示两图紧邻连续)'
                  % ALIGN)
        else:
            print('  → 注意: 存在非 %d 倍数间隔, 可能有图片起点未对齐' % ALIGN)

    # ---------------- 2) 分区排布 ----------------
    if not a.all:
        total = sum(sizes)
        print('\n==================== 2) 分区排布(按 %s) ====================' % a.sizes)
        if len(sizes) != len(names):
            print('*** --sizes 与 --names 个数不一致, 无法分段 ***')
            return 1
        if any(c <= 0 for c in sizes) or len(sizes) == 0:
            print('*** --sizes 必须为正整数(如 5,5,5) ***')
            return 1
        if len(hits) < total:
            print('*** 合格图不足: 需要 %d 张, 实际只有 %d 张 ***' % (total, len(hits)))
            print('    请补齐素材或调小 --sizes')
        else:
            # 切分成段: (张数, START, WRAP, 首张序号, 末张序号)
            zones = build_zones(hits, sizes)
            for k, (nm, z) in enumerate(zip(names, zones)):
                cnt, st, wr, f0, f1 = z
                print('  段%d %-5s: 图 %d~%d  START=%-9d WRAP=%-9d IMGS=%d'
                      % (k, nm, f0, f1, st, wr, cnt))

            # ---- 直接输出可粘贴进 top.v 的 localparam ----
            print('\n------ 粘贴到 src/top.v 的分区表(Z_* 段) ------')
            for nm, (cnt, st, wr, f0, f1) in zip(names, zones):
                print("localparam [31:0] Z_%s_START = 32'd%-9d;  // %s 区起点(=第 %d 张)"
                      % (nm, st, nm, f0))
                print("localparam [31:0] Z_%s_WRAP  = 32'd%-9d;  // %s 区扫描上限(>=末张起点)"
                      % (nm, wr, nm))
                print("localparam [31:0] Z_%s_IMGS  = 32'd%-9d;  // %s 区张数"
                      % (nm, cnt, nm))
            z0 = zones[0]
            print("// 菜单态(四 SW 全关)底层仍轮播(被全屏菜单覆盖), 复用首段:")
            print("localparam [31:0] Z_MENU_START = 32'd%d;" % z0[1])
            print("localparam [31:0] Z_MENU_WRAP  = 32'd%d;" % z0[2])
            print("localparam [31:0] Z_MENU_IMGS  = 32'd%d;" % z0[0])

    # ---------------- 3) 命中但不合格(排查花屏) ----------------
    print('\n==================== 3) 命中 BM 但不合格(%d 处) ====================' % len(bads))
    if not bads:
        print('  (无) —— 卡上没有被误判的残留数据')
    else:
        for s, r in bads[:40]:
            print('  扇区 %-10d %s' % (s, r))
        if len(bads) > 40:
            print('  ... 其余 %d 处省略' % (len(bads) - 40))
        print('  → 这些会被严格校验滤掉(不会花屏); 若数量异常多, 建议【完整格式化】卡')

    # ---------------- 结论 ----------------
    print('\n==================== 结论 ====================')
    if not hits:
        print('  未找到任何合格图: 检查 BMP 属性(640x480/24bit/无压缩/921654B)')
        print('  与是否放在根目录、卡是否为 >=4KB 簇的 FAT32/exFAT。')
    else:
        ok = (nbad_align == 0)
        print('  合格图 %d 张, 8 扇区对齐: %s, 不合格残留 %d 处'
              % (len(hits), '全部 OK' if ok else ('%d 张未对齐 **需排查**' % nbad_align), len(bads)))
        if ok:
            print('  → 可直接采用上面的 localparam, 改 top.v 后重新综合生成比特流。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
