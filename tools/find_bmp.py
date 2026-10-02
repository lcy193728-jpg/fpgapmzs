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
#
# 【支持规格】(严格四项: 文件长度 / 宽 / 高 / 位深 全等才合格)
#   · 640×480  ×24bit = 921654  字节  (本卡 8KB 簇下占 1808 扇区)
#   · 1280×960 ×24bit = 3686454 字节  (本卡 8KB 簇下占 7216 扇区)
#   两者跨度都是 8 的整数倍 → 640/1280 混排时起点仍天然对齐。
#
# 【用途】
#   1) 扫物理盘, 列出卡上所有【严格合格】的 BMP 起始扇区与分辨率;
#   2) 按 --sizes 给出的每段张数自动切分成各场景分区, 计算
#      {START, WRAP, IMGS}, 并直接打印【可粘贴进 top_final.v】的 localparam
#      (已按 --base 加好物理偏移, 可原样覆盖 Z_*, 无需手算 +2048);
#   3) 列出「命中 BM 但不合格」的扇区(删除残留/尺寸不符) → 排查花屏。
#
# 【用法】(需在【管理员权限】终端运行, 物理盘读取要管理员)
#   python tools/find_bmp.py --drive F
#   python tools/find_bmp.py --drive F --start 120000 --sizes 4,1,1 --names WEL,MEET,QUIZ
#   python tools/find_bmp.py --drive F --all            # 只列合格图, 不切段
#
# 【参数】
#   --drive  物理盘符(不带冒号), 如 F
#   --start  扫描起始扇区(卷内口径), 默认 16000 (自动向上取整到 8 的倍数)
#   --end    扫描结束扇区, 0=自动(连续 1GB 无新命中即停), 默认 0
#   --sizes  各段张数, 逗号分隔, 默认 5,5,5
#   --names  各段名称, 逗号分隔, 默认 WEL,MEET,QUIZ (决定输出的 Z_* 前缀)
#   --all    只列合格图, 不做分段/不输出 localparam
#   --base   输出 localparam 时的物理偏移(卷内→物理), 默认 64
#            ⚠ 必须等于该卡的实际分区起始 LBA(读卷引导扇区 BPB 偏移 0x1C
#              "隐藏扇区数")。本卡 G: = 64(SD Formatter 典型布局), 不是 1MB
#              对齐的 2048。填错会让 Z_* 整体平移, 板子扫不到图(上电花屏/错图)。
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

# 白名单: (名称, 文件长度, 宽, 高, 位深, 本卡占用扇区[8KB簇, 仅供自检参考])
#   2026-10-02 扩展: 加入 320x240 与 1024x768 —— 与 bmp_read_auto.v 的
#   分辨率白名单(dim_320/dim_640/dim_1024/dim_2x)保持一一对应, 否则本工具
#   会把新分辨率图误报成"不合格残留", 无法用于分区定位。
#   占用扇区 = ceil(54 + W*H*3, 8192) 簇 × 16 扇区/簇 (8KB 簇):
#     230454/8192 = 28.13 → 29 簇 = 464   扇区
#     921654/8192 = 112.5 → 113 簇 = 1808 扇区
#     2359350/8192= 288.01 → 289 簇 = 4624 扇区
#     3686454/8192= 449.9 → 450 簇 = 7200 扇区
EXPECTED = [
    ('320x240',   230454,  320,  240, 24,  464),
    ('640x480',   921654,  640,  480, 24, 1808),
    ('1024x768', 2359350, 1024,  768, 24, 4624),
    ('1280x960', 3686454, 1280,  960, 24, 7200),
]

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
    p.add_argument('--base',  type=int, default=64,   help='输出 localparam 的物理偏移(默认 64; 本卡分区偏移仅 64 扇区)')
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


def classify(fl, w, h, b):
    """命中白名单则返回对应规格元组, 否则 None"""
    for e in EXPECTED:
        if fl == e[1] and w == e[2] and h == e[3] and b == e[4]:
            return e
    return None


def why_bad(fl, w, h, b):
    """返回不合格原因列表(用于排查花屏/误判残留)"""
    r = []
    cand = [e for e in EXPECTED if w == e[2] and h == e[3] and b == e[4]]
    if not cand:
        r.append('分辨率/位深 %dx%d/%dbit 不在白名单(%s)'
                 % (w, h, b, '/'.join('%dx%d' % (e[2], e[3]) for e in EXPECTED)))
    else:
        for e in cand:
            if fl != e[1]:
                r.append('长度%d≠%d(%s)' % (fl, e[1], e[0]))
    return r


def scan(drive, start, end):
    """逐块扫描, 每 ALIGN 扇区检查一次 BMP 头; 返回 (hits, bads)
    hits = [(起始扇区, 规格名)] 升序; bads = [(扇区, 原因串)]"""
    f = open(drive, 'rb', buffering=0)
    hits = []
    bads = []
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
            e = classify(fl, w, h, b)
            if e is not None:
                hits.append((sec + off, e[0]))
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
    返回 [(张数, START, WRAP, 首张序号, 末张序号, 本段命中)]; 调用前须保证
    len(hits) >= sum(sizes)。WRAP 取下一段首张起点(末段取末张+8)，
    与 bmp_read_auto.v「addr >= WRAP 即回卷 START」的语义一致。"""
    zones = []
    idx = 0
    for k, cnt in enumerate(sizes):
        seg = hits[idx:idx + cnt]
        idx += cnt
        st = seg[0][0]
        wr = hits[idx][0] if (k + 1 < len(sizes) and idx < len(hits)) else (seg[-1][0] + ALIGN)
        zones.append((cnt, st, wr, idx - cnt + 1, idx, seg))
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
    print('  #    卷内扇区     物理扇区(+%d)  8扇区对齐   分辨率' % a.base)
    nbad_align = 0
    for i, (s, tag) in enumerate(hits, 1):
        al = (s % ALIGN) == 0
        if not al:
            nbad_align += 1
        print('  %-4d %-12d %-15d %-10s %s'
              % (i, s, s + a.base, 'OK' if al else '*** 未对齐', tag))
    if hits:
        print('  → 首张 %d, 末张 %d, 跨 %d 扇区'
              % (hits[0][0], hits[-1][0], hits[-1][0] - hits[0][0]))
    if len(hits) >= 2:
        gaps = [hits[i + 1][0] - hits[i][0] for i in range(len(hits) - 1)]
        print('  → 相邻起点间隔(扇区): %s' % ', '.join(str(g) for g in gaps))
        tmap = {e[0]: e for e in EXPECTED}
        warn = False
        for i in range(len(hits) - 1):
            gap = hits[i + 1][0] - hits[i][0]
            need = (tmap[hits[i][1]][1] + SEC - 1) // SEC   # 前一张最少占用的扇区
            if gap < need:
                print('  → *** 警告: 第%d→%d张间隔 %d < %d(前一张%s长度), 可能重叠/截断 ***'
                      % (i + 1, i + 2, gap, need, hits[i][1]))
                warn = True
            if gap % ALIGN != 0:
                print('  → *** 警告: 第%d→%d张间隔 %d 非 %d 的倍数, 起点可能错位 ***'
                      % (i + 1, i + 2, gap, ALIGN))
                warn = True
        if not warn:
            print('  → 间隔均 >= 前一张长度 且为 %d 的倍数 → 起点对齐正常'
                  '(间隔=1808 表示两张 640 紧邻; 1280 单独占 7216)' % ALIGN)

    # ---------------- 2) 分区排布 ----------------
    if not a.all:
        total = sum(sizes)
        print('\n==================== 2) 分区排布(按 %s) ====================' % a.sizes)
        if len(sizes) != len(names):
            print('*** --sizes 与 --names 个数不一致, 无法分段 ***')
            return 1
        if any(c <= 0 for c in sizes) or len(sizes) == 0:
            print('*** --sizes 必须为正整数(如 4,1,1) ***')
            return 1
        if len(hits) < total:
            print('*** 合格图不足: 需要 %d 张, 实际只有 %d 张 ***' % (total, len(hits)))
            print('    请补齐素材或调小 --sizes')
        else:
            zones = build_zones(hits, sizes)
            for k, (nm, z) in enumerate(zip(names, zones)):
                cnt, st, wr, f0, f1, seg = z
                tags = ', '.join(t for _, t in seg)
                print('  段%d %-5s: 图 %d~%d  START=%-9d WRAP=%-9d IMGS=%d  [%s]'
                      % (k, nm, f0, f1, st + a.base, wr + a.base, cnt, tags))

            # ---- 直接输出可粘贴进 top_final.v 的 localparam ----
            print('\n------ 粘贴到 audio_final/integrated/top_final.v 的分区表(Z_* 段) ------')
            print('// (下列扇区值已含 +%d 物理偏移, 可直接覆盖)' % a.base)
            for nm, (cnt, st, wr, f0, f1, seg) in zip(names, zones):
                print("localparam [31:0] Z_%s_START = 32'd%-9d;  // %s 区起点(=第 %d 张)"
                      % (nm, st + a.base, nm, f0))
                print("localparam [31:0] Z_%s_WRAP  = 32'd%-9d;  // %s 区扫描上限(>=末张起点)"
                      % (nm, wr + a.base, nm))
                print("localparam [31:0] Z_%s_IMGS  = 32'd%-9d;  // %s 区张数"
                      % (nm, cnt, nm))
            z0 = zones[0]
            print("// 菜单态(四 SW 全关)底层仍轮播(被全屏菜单覆盖), 复用首段:")
            print("localparam [31:0] Z_MENU_START = 32'd%d;" % (z0[1] + a.base))
            print("localparam [31:0] Z_MENU_WRAP  = 32'd%d;" % (z0[2] + a.base))
            print("localparam [31:0] Z_MENU_IMGS  = 32'd%d;" % z0[0])
            print("// 应急区(SW4)无专属素材时, 直接复用抢答区: Z_ALARM_* = Z_QUIZ_*")

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
        print('  未找到任何合格图: 检查 BMP 属性(640x480=921654B / 1280x960=3686454B,')
        print('  24bit 非压缩, 正高度)与是否放在根目录、卡是否为 >=4KB 簇的 FAT32/exFAT。')
    else:
        ok = (nbad_align == 0)
        print('  合格图 %d 张, 8 扇区对齐: %s, 不合格残留 %d 处'
              % (len(hits), '全部 OK' if ok else ('%d 张未对齐 **需排查**' % nbad_align), len(bads)))
        if ok:
            print('  → 可直接采用上面的 localparam, 改 top_final.v 后重新综合生成比特流。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
