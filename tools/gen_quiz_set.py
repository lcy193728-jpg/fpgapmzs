#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ====================================================================
# gen_quiz_set.py —— 生成抢答场景「新编号素材」共 4 张 640x480 24bit BMP
#
# 【为什么需要】
#   用户 2026-10-09 定义的抢答新流程需要按下面口径占用卡上 QUIZ 序号:
#     QUIZ1.BMP = 第 1 题  (题目图)
#     QUIZ2.BMP = 第 2 题  (题目图)
#     QUIZ3.BMP = 第 3 题  (题目图)
#     QUIZ4.BMP = 1 号队伍图 (红)
#     QUIZ5.BMP = 2 号队伍图 (蓝)
#     QUIZ6.BMP = 3 号队伍图 (绿)
#     QUIZ7.BMP = 4 号队伍图 (黄)
#     QUIZ8.BMP = 比赛结束页 (含 4 队分数位)
#   ⇒ 本脚本只负责其中「新做」的 4 张: QUIZ1/2/3(题目) + QUIZ8(结束页)。
#     队伍图 QUIZ4..7 由 gen_quiz_team_bmps.py 改名产出(见该脚本 main)。
#
# 【输出规格】与 bmp_read_auto.v 硬校验严格一致:
#   · 640 x 480, 24bit, 非压缩(BI_RGB), 正高度(自底向上), 文件长 921654 字节
#   · 文件名严格 8.3 大写短名放卡根目录
#     (fat32_lookup.v 只认 "QUIZ"+单个数字+' ' 的短名, 数字 1..9)
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
# 三道题目(改这里即可换题)
# ---------------------------------------------------------------
QUESTIONS = [
    # ---- 第 1 题 (QUIZ1) ----
    dict(
        lines=[
            "在 FPGA 设计中, 用于实现组合逻辑",
            "查找表 (LUT) 的基本单元通常是几输入?",
        ],
        options=[
            ("A", "2 输入查找表"),
            ("B", "4 输入查找表"),
            ("C", "8 输入查找表"),
            ("D", "16 输入查找表"),
        ],
        note="提示: 主流 FPGA 基本逻辑单元多采用 4 输入 LUT",
    ),
    # ---- 第 2 题 (QUIZ2) ----
    dict(
        lines=[
            "HDMI 1.4 在 640x480 分辨率下通常采用",
            "多少 kHz 的音频采样率作为标准?",
        ],
        options=[
            ("A", "32 kHz"),
            ("B", "44.1 kHz"),
            ("C", "48 kHz"),
            ("D", "96 kHz"),
        ],
        note="提示: HDMI 音频最通用的工业标准采样率是 48 kHz",
    ),
    # ---- 第 3 题 (QUIZ3) ----
    dict(
        lines=[
            "赛题要求 640x480、24bit 的非压缩 BMP",
            "图像, 其文件字节数应该正好是多少?",
        ],
        options=[
            ("A", "921600 字节"),
            ("B", "921654 字节"),
            ("C", "1024000 字节"),
            ("D", "460800 字节"),
        ],
        note="提示: 54 字节文件头 + 640x480x3 的像素数据",
    ),
]

# 4 队分数位(结束页用)
TEAMS = [
    (1, "红队", (220, 40, 40)),
    (2, "蓝队", (30, 90, 220)),
    (3, "绿队", (30, 160, 70)),
    (4, "黄队", (235, 190, 30)),
]


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


def make_question(q, qno, qtotal):
    """按题目内容渲染一页题目图(与既有 gen_quiz_question_bmp.py 同版式)。"""
    img = Image.new("RGB", (W, H), (14, 24, 52))
    d = ImageDraw.Draw(img)

    # ---- 1) 深蓝渐变底(顶部稍亮) ----
    for y in range(H):
        k = 1.0 - 0.35 * (y / (H - 1))
        d.line([(0, y), (W - 1, y)],
               fill=(int(14 * k), int(24 * k), int(52 * k)))

    # ---- 2) 顶部标题带(含题号) ----
    d.rectangle([0, 0, W, 62], fill=(8, 14, 34))
    d.line([(0, 62), (W, 62)], fill=(70, 140, 240), width=3)
    f_title = f(FONT_BOLD, 40)
    d.text((W // 2, 33), f"抢 答 题  ·  第 {qno} / {qtotal} 题",
           font=f_title, fill=(235, 242, 255),
           anchor="mm", stroke_width=2, stroke_fill=(20, 40, 80))

    # ---- 3) 题目正文(左对齐, 两行) ----
    f_q = f(FONT_BOLD, 27)
    y = 96
    for line in q["lines"]:
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
    for i, (tag, text) in enumerate(q["options"]):
        cx = x0 + (i % 2) * (cw + gapx)
        cy = y0 + (i // 2) * (ch + gapy)
        d.rounded_rectangle([cx, cy, cx + cw, cy + ch], radius=10,
                            fill=(24, 40, 78), outline=(80, 130, 210), width=2)
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
    d.text((W // 2, H - 26), q["note"], font=f_h, fill=(150, 195, 245),
           anchor="mm")
    return img


def make_end_page():
    """比赛结束页: 大标题 + 4 队分数位(分数由 OSD 叠加, 这里只画底框)。"""
    img = Image.new("RGB", (W, H), (14, 24, 52))
    d = ImageDraw.Draw(img)

    # ---- 1) 深蓝渐变底 ----
    for y in range(H):
        k = 1.0 - 0.35 * (y / (H - 1))
        d.line([(0, y), (W - 1, y)],
               fill=(int(14 * k), int(24 * k), int(52 * k)))

    # ---- 2) 顶部标题带 ----
    d.rectangle([0, 0, W, 62], fill=(8, 14, 34))
    d.line([(0, 62), (W, 62)], fill=(70, 140, 240), width=3)

    # ---- 3) 中央大标题「比赛结束」 ----
    f_big = f(FONT_BOLD, 68)
    d.text((W // 2, 100), "比 赛 结 束", font=f_big, fill=(255, 210, 74),
           anchor="mm", stroke_width=3, stroke_fill=(20, 40, 80))
    d.line([(140, 148), (W - 140, 148)], fill=(70, 140, 240), width=3)

    f_sub = f(FONT_REG, 26)
    d.text((W // 2, 178), "最终得分", font=f_sub, fill=(200, 218, 245),
           anchor="mm")

    # ---- 4) 4 队分数卡片(2x2) ----
    f_name = f(FONT_BOLD, 30)
    f_pts = f(FONT_BOLD, 44)
    cw, ch = 264, 92
    gapx, gapy = 32, 18
    x0 = (W - (cw * 2 + gapx)) // 2
    y0 = 206
    for i, (idx, name, rgb) in enumerate(TEAMS):
        cx = x0 + (i % 2) * (cw + gapx)
        cy = y0 + (i // 2) * (ch + gapy)
        d.rounded_rectangle([cx, cy, cx + cw, cy + ch], radius=12,
                            fill=(24, 40, 78), outline=rgb, width=3)
        # 队名色块
        d.rounded_rectangle([cx + 12, cy + 16, cx + 12 + 96, cy + ch - 16],
                            radius=8, fill=rgb)
        d.text((cx + 60, cy + ch // 2), name, font=f_name,
               fill=(255, 255, 255), anchor="mm")
        # 分数位(OSD 数字叠加区): 右半留空 + 灰色占位
        d.text((cx + cw - 78, cy + ch // 2), "--", font=f_pts,
               fill=(120, 150, 190), anchor="mm")

    # ---- 5) 底部提示带 ----
    d.rectangle([0, H - 44, W, H], fill=(8, 14, 34))
    d.line([(0, H - 44), (W, H - 44)], fill=(70, 140, 240), width=2)
    f_h = f(FONT_REG, 21)
    d.text((W // 2, H - 22), "感谢各队参与 · 本次抢答环节到此结束",
           font=f_h, fill=(150, 195, 245), anchor="mm")
    return img


def main():
    OUTDIR.mkdir(parents=True, exist_ok=True)
    produced = []

    # ---- QUIZ1..QUIZ3 = 第 1..3 题 ----
    total = len(QUESTIONS)
    for i, q in enumerate(QUESTIONS):
        img = make_question(q, i + 1, total)
        out = OUTDIR / f"QUIZ{i + 1}.BMP"
        n = write_bmp24_bottomup(img, out)
        produced.append((out.name, n, f"第 {i + 1} 题"))
        print(f"  [OK] {out.name}  {n} B  (第 {i + 1} 题)")

    # ---- QUIZ8 = 比赛结束页 ----
    img = make_end_page()
    out = OUTDIR / "QUIZ8.BMP"
    n = write_bmp24_bottomup(img, out)
    produced.append((out.name, n, "结束页"))
    print(f"  [OK] {out.name}  {n} B  (比赛结束页)")

    print(f"\n输出目录: {OUTDIR}")
    print("硬约束核对:")
    ok = True
    for name, n, _ in produced:
        flag = "OK " if n == 921654 else "BAD"
        if n != 921654:
            ok = False
        print(f"  [{flag}] {name:12s} {n} B")
    print("\n注意: QUIZ4..QUIZ7(队伍图) 由 gen_quiz_team_bmps.py 改名产出。")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
