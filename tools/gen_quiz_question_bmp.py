#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ====================================================================
# gen_quiz_question_bmp.py —— 生成抢答场景「题目内容图」(QUIZ1.BMP)
#
# 【为什么需要】
#   抢答场景的流程应为: 上电/切换进入 → **停在题目界面**(QUIZ1) → 按"开始键"
#   启动倒计时 → 选手按下抢答键 → 锁定并切到对应队伍图(QUIZ2..5)。
#   原先的 QUIZ1 只是"等待开始"占位页, 没有真正的题目。本脚本按用户要求
#   **AI 生成一道题**, 渲染成 640x480 24bit BMP, 写入卡内 QUIZ1 扇区。
#
# 【输出规格】与 bmp_read_auto.v 硬校验严格一致:
#   · 640 x 480, 24bit, 非压缩(BI_RGB), 正高度(自底向上), 文件长 921654 字节
#   · 文件名严格 8.3 大写短名放卡根目录: QUIZ1.BMP
#     (fat32_lookup.v 只认 "QUIZ"+单个数字+' ' 的短名)
#
# 【为什么手写 BMP 头】
#   PIL 保存 24bit BMP 有 padding/方向差异; 显式写头保证文件长度恒 921654、
#   bfOffBits=54、biHeight 正数(自底向上)、行内 BGR + 每行 4 字节对齐。
# ====================================================================

import struct
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUTDIR = ROOT / "图片" / "_quiz_team"

W, H = 640, 480
FONT_BOLD = r"C:\Windows\Fonts\Noto Sans SC Bold (TrueType).otf"
FONT_REG = r"C:\Windows\Fonts\Noto Sans SC (TrueType).otf"

# ---------------------------------------------------------------
# 题目内容(改这里即可换题; 全部为可打印中文/ASCII)
# ---------------------------------------------------------------
QUESTION_LINES = [
    "在 FPGA 设计中, 用于实现组合逻辑",
    "查找表 (LUT) 的基本单元通常是几输入?",
]
OPTIONS = [
    ("A", "2 输入查找表"),
    ("B", "4 输入查找表"),
    ("C", "8 输入查找表"),
    ("D", "16 输入查找表"),
]
ANSWER_NOTE = "提示: 主流 FPGA 基本逻辑单元多采用 4 输入 LUT"


def f(path, size):
    try:
        return ImageFont.truetype(path, size)
    except OSError as exc:
        raise SystemExit(f"字体加载失败: {path} -> {exc}")


def write_bmp24_bottomup(img, path):
    """按 bmp_read_auto 硬校验口径写 640x480 24bit 非压缩 BMP(自底向上)。"""
    assert img.size == (W, H) and img.mode == "RGB"
    px = img.load()
    row_pad = (-(W * 3)) % 4              # 640*3=1920 已 4 字节对齐, 恒 0
    row_bytes = W * 3 + row_pad
    img_size = row_bytes * H
    file_size = 54 + img_size
    assert file_size == 921654, f"文件长度 {file_size} != 921654"

    buf = bytearray()
    buf += b"BM"
    buf += struct.pack("<IHHI", file_size, 0, 0, 54)
    buf += struct.pack("<IiiHHIIiiII", 40, W, H, 1, 24, 0,
                       img_size, 2835, 2835, 0, 0)
    pad = b"\x00" * row_pad
    for y in range(H - 1, -1, -1):         # 自底向上
        row = bytearray()
        for x in range(W):
            r, g, b = px[x, y]
            row += bytes((b, g, r))        # BMP = BGR
        buf += row + pad
    path.write_bytes(buf)
    return len(buf)


def main():
    OUTDIR.mkdir(parents=True, exist_ok=True)

    img = Image.new("RGB", (W, H), (14, 24, 52))
    d = ImageDraw.Draw(img)

    # ---- 1) 深蓝渐变底(顶部稍亮) ----
    for y in range(H):
        k = 1.0 - 0.35 * (y / (H - 1))
        d.line([(0, y), (W - 1, y)],
               fill=(int(14 * k), int(24 * k), int(52 * k)))

    # ---- 2) 顶部标题带 ----
    d.rectangle([0, 0, W, 62], fill=(8, 14, 34))
    d.line([(0, 62), (W, 62)], fill=(70, 140, 240), width=3)
    f_title = f(FONT_BOLD, 40)
    d.text((W // 2, 33), "抢 答 题", font=f_title, fill=(235, 242, 255),
           anchor="mm", stroke_width=2, stroke_fill=(20, 40, 80))

    # ---- 3) 题目正文(左对齐, 两行) ----
    f_q = f(FONT_BOLD, 27)
    y = 96
    for line in QUESTION_LINES:
        d.text((36, y), line, font=f_q, fill=(250, 252, 255))
        y += 40

    # ---- 4) 分隔线 ----
    d.line([(36, y + 4), (W - 36, y + 4)], fill=(60, 110, 190), width=2)

    # ---- 5) 四个选项(两列两行卡片) ----
    f_opt = f(FONT_REG, 24)
    f_tag = f(FONT_BOLD, 26)
    cw, ch = 270, 74
    gapx, gapy = 28, 18
    x0, y0 = 36, y + 24
    for i, (tag, text) in enumerate(OPTIONS):
        cx = x0 + (i % 2) * (cw + gapx)
        cy = y0 + (i // 2) * (ch + gapy)
        d.rounded_rectangle([cx, cy, cx + cw, cy + ch], radius=10,
                            fill=(24, 40, 78), outline=(80, 130, 210), width=2)
        # 选项字母徽标
        d.rounded_rectangle([cx + 10, cy + 12, cx + 58, cy + ch - 12],
                            radius=8, fill=(46, 106, 200))
        d.text((cx + 34, cy + ch // 2), tag, font=f_tag, fill=(255, 255, 255),
               anchor="mm")
        d.text((cx + 72, cy + ch // 2), text, font=f_opt, fill=(232, 240, 252),
               anchor="lm")

    # ---- 6) 底部提示带 ----
    d.rectangle([0, H - 52, W, H], fill=(8, 14, 34))
    d.line([(0, H - 52), (W, H - 52)], fill=(70, 140, 240), width=2)
    f_h = f(FONT_REG, 21)
    d.text((W // 2, H - 26), ANSWER_NOTE, font=f_h, fill=(150, 195, 245),
           anchor="mm")

    out = OUTDIR / "QUIZ1.BMP"
    n = write_bmp24_bottomup(img, out)
    print(f"[OK] {out}  {n} B")
    print(f"硬约束: {'OK' if n == 921654 else 'BAD'} (需 921654)")
    return 0 if n == 921654 else 1


if __name__ == "__main__":
    sys.exit(main())
