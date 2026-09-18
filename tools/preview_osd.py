#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
preview_osd.py —— 从生成的 osd_font_rom.v 反解字形, 渲染各场景 OSD 整屏预览
=====================================================================
用途(改字库/改文案后的自检工具, 不参与综合):
  1. 直接解析 src/osd_font_rom.v 的 `mem[N] = 32'h...` 数据 + 头部注释里的
     分区表(base/N/cell/scale/ty/gx), 按 osd_menu/osd_welcome/osd_scene 的
     取址规则重建点阵 —— 因此它同时校验了 **ROM 数据 + base 表 + 几何**;
  2. 按 640×480 有效区渲染成 PNG, 用于肉眼判断字形美观度与版面,
     避免"必须上板才能看到效果"的高成本循环;
  3. 若某带位置/内容明显错位 → 说明 RTL 的 base 常量与生成器不一致。
=====================================================================
用法:  python tools/preview_osd.py
输出:  tools/_preview_<场景>.png  (各场景 1:1) 与 tools/_preview_all.png(总览)
=====================================================================
"""
import os
import re
import sys
from PIL import Image, ImageDraw

H_ACT, V_ACT = 640, 480
BUILD_DIR = os.path.dirname(os.path.abspath(__file__))
ROM_PATH = os.path.normpath(os.path.join(BUILD_DIR, "..", "src", "osd_font_rom.v"))

# 配色(取自 osd_menu.v / osd_welcome.v / osd_scene.v)
C_BG_FULL = (0x0A, 0x12, 0x20)
C_CARD    = (0x15, 0x27, 0x42)
C_BD      = (0x2F, 0xA9, 0xE8)
C_WHITE   = (0xFF, 0xFF, 0xFF)
C_TAG     = (0x9D, 0xCB, 0xF2)
C_ULINE   = (0xFF, 0xD2, 0x4A)
C_MARQ    = (0xFF, 0x7A, 0x1F)
C_MQBG    = (0x00, 0x00, 0x00)
C_ACCENT  = [(0x2E, 0x7C, 0xF6), (0x18, 0xC9, 0x9E), (0xF5, 0xA6, 0x23), (0xE8, 0x4A, 0x4A)]
C_ALARM   = (0xE8, 0x4A, 0x4A)


def parse_rom(path):
    """解析 osd_font_rom.v -> (mem 列表, 分区表列表)"""
    txt = open(path, "r", encoding="utf-8").read()
    mem = {}
    for m in re.finditer(r"mem\[(\d+)\]\s*=\s*32'h([0-9A-Fa-f_]+);", txt):
        mem[int(m.group(1))] = int(m.group(2).replace("_", ""), 16)
    bands = []
    for m in re.finditer(
            r"//\s+(\w+)\s+base=\s*(\d+)\s+N=\s*(\d+)\s+cell=\s*(\d+)\s+scale=(\d+)\s+ty=\s*(\d+)\s+gx=\s*(\d+)\s+\"(.*?)\"",
            txt):
        bands.append(dict(name=m.group(1), base=int(m.group(2)), n=int(m.group(3)),
                          cell=int(m.group(4)), scale=int(m.group(5)),
                          ty=int(m.group(6)), gx=int(m.group(7)), text=m.group(8)))
    return mem, bands


def draw_band(img, mem, band, phase=0, color=C_WHITE, row_off=0, grp=None):
    """把一个文字带按硬件取址规则画到 img 上。
       grp: 用于同行多带(抢答状态区)共享同一个 y 判定, 此处直接由 band 提供 ty。
       取址与 RTL 完全一致:
         scale=2(cell=32): addr = base + row*N + ((px-gx)>>5);  取位 q[31 - ((px-gx)&31)]
         scale=1(cell=16): addr = base + row*N + ((px-gx)>>4);  取位 q[15 - ((px-gx)&15)]
       滚动带(grp="scroll"): 单元内偏移 = ((px+phase) % (N*cell)), cell = off>>?, bit = ...
    """
    gx, ty, n, cell, base = band["gx"], band["ty"], band["n"], band["cell"], band["base"]
    y0, y1 = ty + row_off, ty + row_off + cell
    if grp == "scroll":
        x0, x1 = 0, H_ACT
    else:
        x0, x1 = gx, gx + n * cell
    for y in range(max(0, y0), min(V_ACT, y1)):
        row = y - y0
        for x in range(max(0, x0), min(H_ACT, x1)):
            if grp == "scroll":
                off = (x + phase) % (n * cell)
                col, bit = off // cell, off % cell
            else:
                rel = x - gx
                if rel < 0 or rel >= n * cell:
                    continue
                col, bit = rel // cell, rel % cell
            w = mem.get(base + row * n + col, 0)
            hi = cell - 1
            if cell == 32:
                ink = (w >> (hi - bit)) & 1
            else:
                ink = (w >> (hi - bit)) & 1        # 数据在 q[15:0]
            if ink:
                img.putpixel((x, y), color)


def draw_digits16(img, mem, numband, xs, ty, digs, color=C_WHITE):
    """把 NUM(16×16 字模) 的数字按 1:1 画到 xs[i] 处(供会议运行时长/页码用)。"""
    for x0, d in zip(xs, digs):
        for row in range(16):
            w = mem.get(numband["base"] + row * 10 + d, 0)
            for bit in range(16):
                if (w >> (15 - bit)) & 1:
                    img.putpixel((x0 + bit, ty + row), color)


def draw_digits32(img, mem, numband, xs, ty, digs, color=C_WHITE):
    """把 NUM 的数字按 2× 放大(32×32)画到 xs[i] 处 —— 对应 RTL 的行列折叠。"""
    for x0, d in zip(xs, digs):
        for row in range(16):
            w = mem.get(numband["base"] + row * 10 + d, 0)
            for bit in range(16):
                if (w >> (15 - bit)) & 1:
                    for dy in range(2):
                        for dx in range(2):
                            img.putpixel((x0 + bit * 2 + dx, ty + row * 2 + dy), color)


def new_canvas(bg=C_BG_FULL):
    img = Image.new("RGB", (H_ACT, V_ACT), bg)
    return img


def menu_deco(d):
    """菜单卡片装饰(纯图形, 与字库无关)"""
    for i, top in enumerate([80, 170, 260, 350]):
        d.rectangle([70, top, 569, top + 79], fill=C_CARD)
        d.rectangle([70, top, 569, top + 79], outline=C_BD, width=2)
        d.rectangle([70, top, 77, top + 79], fill=C_ACCENT[i])
    d.rectangle([176, 64, 464, 66], fill=C_ULINE)
    d.rectangle([0, 438, 639, 479], fill=C_MQBG)


def main():
    if not os.path.exists(ROM_PATH):
        print("未找到 %s, 请先运行 gen_osd_font.py" % ROM_PATH)
        return 1
    mem, bands = parse_rom(ROM_PATH)
    if not mem or not bands:
        print("解析 ROM 失败: mem=%d bands=%d" % (len(mem), len(bands)))
        return 1
    B = {b["name"]: b for b in bands}
    print("解析到 %d 个 word, %d 个文字带" % (len(mem), len(bands)))

    scenes = {}

    # ---- 菜单 ----
    im = new_canvas()
    d = ImageDraw.Draw(im)
    menu_deco(d)
    draw_band(im, mem, B["TITLE"], color=C_WHITE)
    for i in range(4):
        draw_band(im, mem, B["CT%d" % i], color=C_WHITE)
        draw_band(im, mem, B["TG%d" % i], color=C_TAG)
    draw_band(im, mem, B["MARQ"], phase=0, color=C_MARQ, grp="scroll")
    scenes["menu"] = im

    # ---- 迎新 ----
    im = new_canvas()
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 639, 59], fill=(0x14, 0x2A, 0x4A))
    d.rectangle([0, 0, 639, 3], fill=C_ULINE)
    draw_band(im, mem, B["W_TITLE"], color=C_ULINE)
    d.rectangle([70, 392, 340, 424], fill=(0x0D, 0x1E, 0x33))
    d.rectangle([340, 392, 610, 424], fill=(0x0D, 0x1E, 0x33))
    draw_band(im, mem, B["W_PLACE"], color=C_TAG)
    draw_band(im, mem, B["W_CONT"], color=C_TAG)
    d.rectangle([0, 438, 639, 479], fill=C_MQBG)
    draw_band(im, mem, B["W_FLOW"], phase=0, color=C_WHITE, grp="scroll")
    scenes["welcome"] = im

    # ---- 会议 ----
    im = new_canvas()
    draw_band(im, mem, B["MT_TITLE"], color=C_WHITE)
    draw_band(im, mem, B["MA0"], color=C_WHITE)   # 公告一次只显示一页(此处取页 0)
    draw_band(im, mem, B["M_FOOT"], phase=0, color=C_WHITE, grp="scroll")
    draw_band(im, mem, B["M_RUN"], color=C_TAG)
    # "已运行 HH:MM:SS": 6 位数字的物理 x 与 RTL 的 mdg 窗一致(冒号由 RTL 另画)
    draw_digits16(im, mem, B["NUM"], [452, 468, 490, 506, 528, 544],
                  B["M_RUN"]["ty"], [1, 2, 3, 4, 5, 6], C_TAG)
    scenes["meeting"] = im

    # ---- 抢答 ----
    im = new_canvas()
    draw_band(im, mem, B["QT_TITLE"], color=C_WHITE)
    draw_band(im, mem, B["QW_WAIT"], color=C_WHITE)
    draw_band(im, mem, B["QS_SEC"], color=C_WHITE)
    # 倒计时个位: NUM 字模行列各折 2 倍 → 32×32, 物理 x 与 RTL 的 qcg 窗一致
    draw_digits32(im, mem, B["NUM"], [304], B["QS_SEC"]["ty"], [5], C_WHITE)
    draw_band(im, mem, B["Q_FOOT"], phase=0, color=C_WHITE, grp="scroll")
    scenes["quiz"] = im

    # ---- 应急 ----
    im = new_canvas()
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 639, 51], fill=C_ALARM)
    draw_band(im, mem, B["AT_TITLE"], color=C_WHITE)
    draw_band(im, mem, B["A_FOOT"], phase=0, color=C_WHITE, grp="scroll")
    scenes["alarm"] = im

    # ---- 输出 + 2× 放大总览 ----
    ZOOM = 2
    tiles = []
    for k, im in scenes.items():
        im.save(os.path.join(BUILD_DIR, "_preview_%s.png" % k))
        tiles.append(im.resize((H_ACT * ZOOM, V_ACT * ZOOM), Image.NEAREST))
    cols, rows_ = 2, 3
    sheet = Image.new("RGB", (cols * H_ACT * ZOOM + 4 * (cols + 1), rows_ * V_ACT * ZOOM + 4 * (rows_ + 1)),
                      (30, 30, 34))
    for idx, t in enumerate(tiles):
        cx, cy = idx % cols, idx // cols
        sheet.paste(t, (4 + cx * (H_ACT * ZOOM + 4), 4 + cy * (V_ACT * ZOOM + 4)))
    sheet.save(os.path.join(BUILD_DIR, "_preview_all.png"))
    print("已输出: tools/_preview_{menu,welcome,meeting,quiz,alarm}.png 与 tools/_preview_all.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
