#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ====================================================================
# gen_quiz_team_bmps.py —— 生成抢答场景「队伍图」素材 (4 张 640x480 24bit BMP)
#
# 【为什么需要】
#   抢答场景锁定后要跳到获胜队伍图(见 src/quiz_scene_ctrl.v)。
#   2026-10-09 用户重排卡上 QUIZ 序号口径为:
#     QUIZ1..3.BMP = 第 1..3 题      (由 tools/gen_quiz_set.py 产出)
#     QUIZ4.BMP    = 1 号队伍图 (红)
#     QUIZ5.BMP    = 2 号队伍图 (蓝)
#     QUIZ6.BMP    = 3 号队伍图 (绿)
#     QUIZ7.BMP    = 4 号队伍图 (黄)
#     QUIZ8.BMP    = 比赛结束页      (由 tools/gen_quiz_set.py 产出)
#   ⇒ 本脚本只产出 QUIZ4..QUIZ7 四张队伍图。
#     winner(0..3) ↔ jump_idx = winner + 3 (0 基), 即卡上第 winner+4 张。
#
# 【输出规格】与 bmp_read_auto.v 硬校验严格一致:
#   · 640 x 480, 24bit, 非压缩(BI_RGB), 正高度(自底向上), 文件长 921654 字节
#   · 文件名必须严格 8.3 大写短名放卡根目录: QUIZ1.BMP … QUIZ5.BMP
#     (fat32_lookup.v 只认 "QUIZ"+单个数字+' ' 的短名; 长名残留 QUIZ1~1.BMP
#      的短名第 4 位是 '~', 不满足 dig() → 匹配失败, 千万不要让 Windows
#      自动改名)
#
# 【为什么自己手写 BMP 头而不直接 img.save(".bmp")】
#   PIL 保存 24bit BMP 默认自顶向下且带 padding 处理差异; 本脚本显式写头,
#   保证: 文件长度恒 921654、bfOffBits=54、biHeight 正数(自底向上)、
#   行内 BGR + 每行 4 字节对齐(640*3=1920 已是 4 的倍数, 无需补位)。
# ====================================================================

import struct
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUTDIR = ROOT / "图片" / "_quiz_team"

W, H = 640, 480
FONT_PATH = r"C:\Windows\Fonts\Noto Sans SC (TrueType).otf"
FONT_BOLD = r"C:\Windows\Fonts\Noto Sans SC Bold (TrueType).otf"

# 队伍配色: (队号, 名称, 主色RGB, 深色RGB)  —— 深色用于描边/副标题块
TEAMS = [
    (1, "红队",   (220,  40,  40), (120,  16,  16)),
    (2, "蓝队",   ( 30,  90, 220), ( 12,  40, 120)),
    (3, "绿队",   ( 30, 160,  70), ( 12,  80,  34)),
    (4, "黄队",   (235, 190,  30), (130, 100,  10)),
]


def descender_safe_font(path, size):
    """字体缺失时回退系统 python 默认(避免脚本直接崩, 但要求字体存在)。"""
    try:
        return ImageFont.truetype(path, size)
    except OSError as exc:
        raise SystemExit(f"字体加载失败: {path} -> {exc}")


def centered_text(draw, cy, text, font, fill, anchor="mm"):
    draw.text((W // 2, cy), text, font=font, fill=fill, anchor=anchor)


def make_team_image(idx, name, main_rgb, dark_rgb):
    """生成一张队伍图: 主色渐变底 + 大号队号 + 队名 + 中文提示。"""
    img = Image.new("RGB", (W, H), main_rgb)
    d = ImageDraw.Draw(img)

    # ---- 1) 上下渐变(自顶深 -> 自底亮), 纯像素操作, 不依赖 numpy ----
    for y in range(H):
        # 0.55(顶) .. 1.0(底) 的亮度系数
        k = 0.55 + 0.45 * (y / (H - 1))
        r = min(255, int(main_rgb[0] * k))
        g = min(255, int(main_rgb[1] * k))
        b = min(255, int(main_rgb[2] * k))
        d.line([(0, y), (W - 1, y)], fill=(r, g, b))

    # ---- 2) 顶部/底部深色色带(给文字让出对比度) ----
    band_h = 96
    d.rectangle([0, 0, W, band_h], fill=dark_rgb)
    d.rectangle([0, H - band_h, W, H], fill=dark_rgb)

    # ---- 3) 中央大号队号圆盘 ----
    cx, cy, R = W // 2, H // 2, 130
    d.ellipse([cx - R, cy - R, cx + R, cy + R], fill=(250, 250, 250))
    d.ellipse([cx - R, cy - R, cx + R, cy + R], outline=dark_rgb, width=8)

    f_num = descender_safe_font(FONT_BOLD, 190)
    d.text((cx, cy - 6), str(idx), font=f_num, fill=main_rgb, anchor="mm",
           stroke_width=4, stroke_fill=dark_rgb)

    # ---- 4) 上带: 队名 ----
    f_top = descender_safe_font(FONT_BOLD, 56)
    centered_text(d, band_h // 2 - 2, f"{name}  抢答", f_top, (250, 250, 250))

    # ---- 5) 下带: 锁定提示 ----
    f_bot = descender_safe_font(FONT_PATH, 34)
    centered_text(d, H - band_h // 2 - 2,
                  f"{idx} 号队伍 · 抢答成功", f_bot, (250, 250, 250))

    # ---- 6) 左右中点小装饰块(增强"队伍图"辨识度) ----
    for sx in (40, W - 40):
        d.rectangle([sx - 12, cy - 60, sx + 12, cy + 60], fill=(250, 250, 250))
        d.rectangle([sx - 15, cy - 63, sx + 15, cy + 63], outline=dark_rgb, width=4)

    return img


def write_bmp24_bottomup(img, path):
    """按 bmp_read_auto 硬校验口径写 640x480 24bit 非压缩 BMP(自底向上)。"""
    assert img.size == (W, H) and img.mode == "RGB"
    px = img.load()

    row_pad = (-(W * 3)) % 4            # 640*3=1920 已对齐, 恒为 0
    row_bytes = W * 3 + row_pad
    img_size = row_bytes * H
    file_size = 54 + img_size
    assert file_size == 921654, f"文件长度 {file_size} != 921654"

    buf = bytearray()
    buf += b"BM"
    buf += struct.pack("<IHHI", file_size, 0, 0, 54)   # bfSize/bfReserved/bfOffBits
    buf += struct.pack("<IiiHHIIiiII",
                       40,          # biSize
                       W, H,        # biWidth, biHeight(正 = 自底向上)
                       1, 24,       # biPlanes, biBitCount
                       0,           # biCompression = BI_RGB
                       img_size,
                       2835, 2835,  # biXPelsPerMeter/Y (72dpi)
                       0, 0)        # biClrUsed/Important

    pad = b"\x00" * row_pad
    for y in range(H - 1, -1, -1):                     # 自底向上
        row = bytearray()
        for x in range(W):
            r, g, b = px[x, y]
            row += bytes((b, g, r))                    # BMP = BGR
        buf += row + pad

    path.write_bytes(buf)
    return len(buf)


def main():
    OUTDIR.mkdir(parents=True, exist_ok=True)
    produced = []

    # ---- QUIZ4..QUIZ7 = 1..4 号队伍图 ----
    for idx, name, main_rgb, dark_rgb in TEAMS:
        img = make_team_image(idx, name, main_rgb, dark_rgb)
        out = OUTDIR / f"QUIZ{idx + 3}.BMP"
        n = write_bmp24_bottomup(img, out)
        produced.append((out.name, n, name))
        print(f"  [OK] {out.name}  {n} B  ({name})")

    print(f"\n输出目录: {OUTDIR}")
    print("硬约束核对:")
    for name, n, _ in produced:
        flag = "OK " if n == 921654 else "BAD"
        print(f"  [{flag}] {name:12s} {n} B")
    print("\n注意: QUIZ1..3(题目) / QUIZ8(结束页) 由 gen_quiz_set.py 产出。")
    print("下一步: 拷到卡根目录(名保持 QUIZ1..QUIZ8.BMP), 再用 find_bmp.py 复核扇区。")


if __name__ == "__main__":
    sys.exit(main())
