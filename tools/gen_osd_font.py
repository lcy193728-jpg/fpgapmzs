#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_osd_font.py —— 全屏矢量首页菜单 · 字形 ROM 生成器(数据源唯一, V2)
=====================================================================
用途:
  1. 用 Windows 黑体(simhei.ttf)把菜单各"文字带"渲染成 16×16 点阵字形,
     每个文字带按 16 行×N 格 顺序存为 16bit 字(MSB=最左列);
  2. 硬件侧按带的 缩放scale(1=16px / 2=32px 由 16 点阵复制放大)重采样显示,
     因此 ROM 里一律存 16×16 原字模, 放大在 RTL 端完成(复制行列即可);
  3. 滚动宣传语条同样存 16×16 字模(带宽 = 每行 20 格, 硬件按 滚动相位
     取模寻址, 实现整行水平平滑左滚);
  4. 生成 Verilog ROM 源文件 src/osd_font_rom.v
     (EG4S20 BRAM: reg[15:0] mem[] + `/* fehdl force_ram=1, ram_style="bram" */`
      初始化 initial 逐字赋值, 与官方 afifo IP 的 BRAM 推断写法一致);
  5. stdout 打印几何表 + 静态文字带采样点(ON/OFF, 物理像素坐标),
     供 tb_osd_menu.v 逐点断言。
=====================================================================
用法:  python tools/gen_osd_font.py
依赖:  Python3 + Pillow, 字体 C:/Windows/Fonts/simhei.ttf
输出:  fpgapmzs/src/osd_font_rom.v
注意: 几何/文案两处同步 = 本文件 + src/osd_menu.v; 改完重跑本脚本再仿真。
=====================================================================
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

# ------------------------------------------------------------------ #
# 0) 布局常量 —— 与 osd_menu.v 严格一致(改菜单务必两处同步)
# ------------------------------------------------------------------ #
# 全屏版式 640×480:
#   顶部大标题(TITLE, 2× = 32px)          : 行 ty 起 32 行, 9 格
#   四条"卡片"(各 80 行高, 间隔 10):
#       卡左 x=70 宽=500(右 570); 左侧 8px 强调色块; 右/上/下 2px 描边
#       卡标题(2× = 32px): 行 top+12 起, x=98, 4 格
#       卡副标题(1× = 16px): 行 top+52 起, x=98, N 格(7)
#   底部滚动宣传语条: 黑底行 438~479, 文字行 451~466, 带宽 20 格/行
CELL     = 16                     # 字模格边长(px)
H_ACT    = 640
V_ACT    = 480

# ---- 卡片/条带几何 ----
CX0      = 70                     # 卡左边界(含左侧色块)
CW       = 500                    # 卡宽(CX0+CW=570)
TOP0     = 80                     # 第 1 卡 top
CARD_H   = 80                     # 卡高
CARD_GAP = 10                     # 卡间距
# ---- 顶部标题条带 ----
TITLE_TY = 28                     # 标题字形窗行起点(2×: 占 32 行)
TITLE_GX = 176                    # 标题字形窗 x 起点
# ---- 滚动宣传语 ----
MQ_Y0    = 438                    # 宣传语条底色上边
MQ_TY    = 451                    # 宣传语字形行起点(16 行)
MQ_P     = 20                     # 宣传语带 每行格数(条宽 = P*16 px)
MQ_TEXT  = "欢迎使用 校园信息终端 SW键 切换场景"   # 必须 == MQ_P 格
assert len(MQ_TEXT) == MQ_P, "宣传语长度必须等于 MQ_P(%d), 当前 %d" % (MQ_P, len(MQ_TEXT))

# 各卡 top(4 卡)
CARDS_TOP = [TOP0 + i * (CARD_H + CARD_GAP) for i in range(4)]   # 80/170/260/350

def card_title_ty(i):            # 卡标题(2×,32 高) 字形行起点
    return CARDS_TOP[i] + 12

def card_tag_ty(i):              # 卡副标题(1×,16 高) 字形行起点
    return CARDS_TOP[i] + 52

TEXT_GX = CX0 + 28               # 卡内文字 x 起点(=98)

# ---- 文字带定义: (name, text, scale, ty, gx) ----
#   scale: 1=16px/字格  2=32px/字格(行×2 列×2 由 RTL 复制)
BANDS = [
    ("TITLE", "校园多功能信息终端", 2, TITLE_TY, TITLE_GX),          # 9 格
    ("CT0",   "迎新展示",           2, card_title_ty(0), TEXT_GX),   # 4 格
    ("CT1",   "会议公示",           2, card_title_ty(1), TEXT_GX),
    ("CT2",   "抢答现场",           2, card_title_ty(2), TEXT_GX),
    ("CT3",   "应急告警",           2, card_title_ty(3), TEXT_GX),
    ("TG0",   "轮播与手动切图",     1, card_tag_ty(0),   TEXT_GX),   # 7 格
    ("TG1",   "日程与滚动字幕",     1, card_tag_ty(1),   TEXT_GX),
    ("TG2",   "多路与硬件仲裁",     1, card_tag_ty(2),   TEXT_GX),
    ("TG3",   "应急最高优先级",     1, card_tag_ty(3),   TEXT_GX),
]
# 宣传语作为最后一个"带"(scale=1, 硬件按滚动相位取列; gx 无意义占位 0)
BANDS.append(("MARQ", MQ_TEXT, 1, MQ_TY, 0))

# ------------------------------------------------------------------ #
# 迎新展示场景 OSD 文字带(追加在菜单之后, 与 src/osd_welcome.v 同源)
#   W_TITLE 顶部金底欢迎语 2×: 字窗行 TY..+32, 格宽 32, 共 7 格
#   W_PLACE 左下报到地点    1×: 字窗行 400..415
#   W_CONT  右下联系方式    1×: 字窗行 400..415
#   W_FLOW  底部报到流程滚动 1×: 字窗行 452..467, 带宽 20 格/行(320px 周期)
# ------------------------------------------------------------------ #
WT_TY   = 14                     # 欢迎语字形行起点(2×, 占 32 行)
WT_GX   = 208                    # 欢迎语字形 x 起点(= (640-7*32)/2)
WT_TEXT = "热烈欢迎新同学"        # 7 格
assert len(WT_TEXT) == 7, "W_TITLE 长度必须为 7"

WL_TY   = 400                    # 报到地点/联系方式 字形行起点(1×)
WL_GX   = 85                     # 报到地点字形 x 起点(10 格, 字宽160)
WL_TEXT = "报到地点：东区体育馆"  # 10 格
assert len(WL_TEXT) == 10, "W_PLACE 长度必须为 10"

WR_GX   = 355                    # 联系方式字形 x 起点(15 格, 字宽240)
WR_TEXT = "新生QQ群：123456789"   # 15 格
assert len(WR_TEXT) == 15, "W_CONT 长度必须为 15"

WF_TY   = 452                    # 流程滚动字形行起点(1×)
WF_TEXT = "迎新报到流程 签到 领卡 入住 军训物资"   # 必须 == 20 格(320px 周期)
assert len(WF_TEXT) == 20, "W_FLOW 长度必须等于 20"

BANDS.append(("W_TITLE", WT_TEXT, 2, WT_TY, WT_GX))
BANDS.append(("W_PLACE", WL_TEXT, 1, WL_TY, WL_GX))
BANDS.append(("W_CONT",  WR_TEXT, 1, WL_TY, WR_GX))
BANDS.append(("W_FLOW",  WF_TEXT, 1, WF_TY, 0))     # 滚动带 gx 占位 0

# ------------------------------------------------------------------ #
# 会议(M_*) / 抢答(Q_*) / 应急(A_*) / 公共数字(NUM) 文字带
#   ★★ 必须追加在既有带之后: 既有带 base 由"累计格数×16"决定, 追加不改变
#      旧 base, 因此 osd_menu.v / osd_welcome.v 的既有几何表无需改动,
#      仅需把其 osd_font_rom 例化的 DEPTH 同步增大(见文件末统计)。
#   几何与 src/osd_scene.v 同源, 改动需两处同步并重跑本脚本。
# ------------------------------------------------------------------ #
# ---- 会议场景 ----
MT_TY, MT_GX = 14, 192
MT_TEXT = "校园会议信息公示"           # 8 格(2× = 256px, 居中 x=192)
assert len(MT_TEXT) == 8, "MT_TITLE 长度必须为 8"

MA_TY, MA_GX = 196, 240                # 公告行(1×), 每条 10 格(160px, 居中 240)
MA_TEXTS = [
    "第一会议室 项目评审",
    "第二会议室 学术报告",
    "第三会议室 社团例会",
    "综合报告厅 迎新宣讲",
]
for _t in MA_TEXTS:
    assert len(_t) == 10, "会议公告文案长度必须为 10: %s" % _t

MR_TY, MR_GX = 76, 396
MR_TEXT = "已运行"                     # 3 格(1× = 48px)
assert len(MR_TEXT) == 3, "M_RUN 长度必须为 3"

MF_TY = 452
MF_TEXT = "会议进行中 请保持安静 并将手机调至静音"   # 20 格滚动(周期 320px)
assert len(MF_TEXT) == 20, "M_FOOT 长度必须为 20"

# ---- 抢答场景 ----
QT_TY, QT_GX = 20, 240
QT_TEXT = "抢答进行中"                 # 5 格(2× = 160px)
assert len(QT_TEXT) == 5, "QT_TITLE 长度必须为 5"

QW_TY, QW_GX = 96, 256
QW_TEXT = "等待开始"                   # 4 格(2× = 128px)
assert len(QW_TEXT) == 4, "QW_WAIT 长度必须为 4"

QR_TY, QR_GX = 96, 272
QR_TEXT = "抢答中"                     # 3 格(2× = 96px)
assert len(QR_TEXT) == 3, "QR_READY 长度必须为 3"

QWL_TY, QWL_GX = 96, 192
QWL_TEXT = "选手"                      # 2 格(2× = 64px)
assert len(QWL_TEXT) == 2, "QWL_WIN 长度必须为 2"

QWR_TY, QWR_GX = 96, 288
QWR_TEXT = "号抢答成功"                # 5 格(2× = 160px)
assert len(QWR_TEXT) == 5, "QWR_WIN 长度必须为 5"

QN_TY, QN_GX = 96, 192
QN_TEXT = "时间到 无人抢答"            # 8 格(2× = 256px)
assert len(QN_TEXT) == 8, "QN_NONE 长度必须为 8"

QS_TY, QS_GX = 180, 336
QS_TEXT = "秒"                         # 1 格(2× = 32px)
assert len(QS_TEXT) == 1, "QS_SEC 长度必须为 1"

QF_TY = 452
QF_TEXT = "请各位选手仔细听题 抢答请按键 先按先得"   # 20 格滚动
assert len(QF_TEXT) == 20, "Q_FOOT 长度必须为 20"

# ---- 应急场景 ----
AT_TY, AT_GX = 82, 160
AT_TEXT = "紧急情况 请立即疏散"         # 10 格(2× = 320px)
assert len(AT_TEXT) == 10, "AT_TITLE 长度必须为 10"

AF_TY = 452
AF_TEXT = "紧急告警 请全体人员沿疏散通道迅速撤离 注意安全"  # 24 格滚动(周期 384px)
assert len(AF_TEXT) == 24, "A_FOOT 长度必须为 24"

# ---- 公共数字带(硬件按 digit 选列, 用于时钟/倒计时/页码) ----
NUM_TEXT = "0123456789"                # 10 格(1×)
assert len(NUM_TEXT) == 10, "NUM 长度必须为 10"

BANDS.append(("MT_TITLE", MT_TEXT, 2, MT_TY, MT_GX))
for _i, _t in enumerate(MA_TEXTS):
    BANDS.append(("MA%d" % _i, _t, 1, MA_TY, MA_GX))
BANDS.append(("M_RUN",  MR_TEXT, 1, MR_TY, MR_GX))
BANDS.append(("M_FOOT", MF_TEXT, 1, MF_TY, 0))      # 滚动带 gx 占位 0

BANDS.append(("QT_TITLE", QT_TEXT, 2, QT_TY, QT_GX))
BANDS.append(("QW_WAIT",  QW_TEXT, 2, QW_TY, QW_GX))
BANDS.append(("QR_READY", QR_TEXT, 2, QR_TY, QR_GX))
BANDS.append(("QWL_WIN",  QWL_TEXT, 2, QWL_TY, QWL_GX))
BANDS.append(("QWR_WIN",  QWR_TEXT, 2, QWR_TY, QWR_GX))
BANDS.append(("QN_NONE",  QN_TEXT, 2, QN_TY, QN_GX))
BANDS.append(("QS_SEC",   QS_TEXT, 2, QS_TY, QS_GX))
BANDS.append(("Q_FOOT",   QF_TEXT, 1, QF_TY, 0))    # 滚动带 gx 占位 0

BANDS.append(("AT_TITLE", AT_TEXT, 2, AT_TY, AT_GX))
BANDS.append(("A_FOOT",   AF_TEXT, 1, AF_TY, 0))    # 滚动带 gx 占位 0

BANDS.append(("NUM", NUM_TEXT, 1, 0, 0))            # 动态选列, ty/gx 无意义

# ---- 滚动带名(采样点无法固定, 生成采样点时跳过) ----
SCROLL_BANDS = ("MARQ", "W_FLOW", "M_FOOT", "Q_FOOT", "A_FOOT")

EMERG_ROWS = 52                  # 应急顶部红条高度(行 0~51)

# 渲染质量: 每点渲染 S×S 再缩回(抗锯齿→阈值)
S          = 4
FONT_PATH  = r"C:\Windows\Fonts\simhei.ttf"

OUT_VLOG   = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "src", "osd_font_rom.v"))


# ------------------------------------------------------------------ #
# 1) 渲染工具: 一行文本 -> 16×16N 的 0/1 矩阵(1=墨)
# ------------------------------------------------------------------ #
def render_line(text: str) -> list:
    n = len(text)
    cell_px = CELL * S
    H_res   = CELL * S
    W_res   = n * cell_px
    img     = Image.new("L", (W_res, H_res), 255)
    drw     = ImageDraw.Draw(img)
    fnt     = ImageFont.truetype(FONT_PATH, H_res)
    asc, desc = fnt.getmetrics()
    margin  = (H_res - (asc + desc)) / 2.0
    base_y  = int(margin + asc)
    for i, ch in enumerate(text):
        drw.text((i * cell_px, base_y), ch, font=fnt, fill=0, anchor="ls")
    sm  = img.resize((CELL * n, CELL), Image.LANCZOS)
    px  = sm.load()
    rows = []
    for y in range(CELL):
        row = []
        for x in range(CELL * n):
            row.append(1 if px[x, y] < 160 else 0)
        rows.append(row)
    return rows


def words_of(rows: list) -> list:
    """矩阵(16×16N) -> 每行 N 个 16bit 字, 顺序 idx = r*N + c; MSB=格内最左。"""
    n_col = len(rows[0]) // CELL
    words = []
    for r in range(CELL):
        for c in range(n_col):
            w = 0
            for b in range(CELL):
                if rows[r][c * CELL + b]:
                    w |= 1 << (CELL - 1 - b)
            words.append(w)
    return words


# ------------------------------------------------------------------ #
# 2) 生成 ROM 数据 + 统计
# ------------------------------------------------------------------ #
def main():
    assert os.path.exists(FONT_PATH), f"未找到字体: {FONT_PATH}"

    bands = []                    # [name, text, n, scale, ty, gx, base, words, ink]
    cell_cum = 0
    for name, text, scale, ty, gx in BANDS:
        n     = len(text)
        rows  = render_line(text)
        words = words_of(rows)
        assert len(words) == n * CELL
        ink   = sum(bin(w).count("1") for w in words)
        base  = cell_cum * CELL
        bands.append((name, text, n, scale, ty, gx, base, words, ink))
        cell_cum += n
    depth = cell_cum * CELL
    addr_w = max(1, (depth - 1).bit_length())

    # ---- 数字带逐字符墨点(供 TB 精确推算"动态数字区域"的期望计数) ----
    #   字模按列-主序存放: 字符 c 的 16 行位于 words[r*n + c] (r=0..15)
    num_ch_ink = []
    for (name, text, n, scale, ty, gx, base, words, ink) in bands:
        if name == "NUM":
            for c in range(n):
                num_ch_ink.append(sum(bin(words[r * n + c]).count("1")
                                      for r in range(CELL)))

    # ---- 采样点: 静态带(非 MARQ)各给 1 个字形 ON 与 1 个空白 OFF(物理像素) ----
    #   2× 带: 物理 x = gx + fcol*2(+0/1), 物理 y = ty + frow*2(+0/1)
    #   1× 带: 物理 x = gx + fcol,      物理 y = ty + frow
    spot = []
    for (name, text, n, scale, ty, gx, base, words, ink) in bands:
        if name in SCROLL_BANDS:
            continue   # 滚动带无法给出固定采样点
        if name == "NUM":
            continue   # 动态选列带(0~9), 无固定采样点
        def phys(px, py):
            return (gx + (px) * scale, ty + (py) * scale)
        on = None
        for r in range(CELL):
            for c in range(n):
                w = words[r * n + c]
                if w:
                    b = 15
                    while not (w & (1 << b)):
                        b -= 1
                    fx, fy = phys(15 - b, r)          # MSB=左 -> 列=(15-b)
                    on = (name, fx, fy, fx + scale - 1, fy + scale - 1)  # ON 区内任一点均可
                    break
            if on:
                break
        off = None
        found = False
        for r in range(CELL):
            for c in range(n):
                w = words[r * n + c]
                for b in range(CELL):                  # MSB..LSB = 格内左..右
                    if not (w & (1 << (CELL - 1 - b))):  # 该像素为 0(空白)
                        fx = gx + c * CELL * scale + b * scale
                        fy = ty + r * scale
                        off = (name, fx, fy)
                        found = True
                        break
                if found:
                    break
            if found:
                break
        spot.append((on, off))

    # ---- 打印统计(供 TB 与人工核对) ----
    print("======== gen_osd_font V2 输出 ========")
    print(f"ROM 深度(words)={depth}  ADDR_W={addr_w}  ({depth*16//1024}Kbit)")
    for (name, text, n, scale, ty, gx, base, words, ink) in bands:
        print(f"  {name:5s} N={n:2d} scale={scale} ty={ty:3d} gx={gx:3d} base={base:4d} 墨点={ink:4d} \"{text}\"")
    print("静态文字带采样点 (物理像素, ON=字形应写字色 / OFF=字形区内应底色):")
    for (on, off) in spot:
        print(f"  {on[0]:5s} ON=({on[1]},{on[2]}) 区内可另取=({on[3]},{on[4]})  OFF=({off[1]},{off[2]})")
    print(f"数字带 NUM 逐字符墨点(下标=字符 0..9): {num_ch_ink}")
    print(f"滚动宣传语: 行{MQ_TY}~{MQ_TY+15} 条带黑底行{MQ_Y0}~{V_ACT-1}, 带宽{MQ_P}格/行(=×16px)")
    print(f"应急红条: 行0~{EMERG_ROWS-1} 全区宽")
    print(f"卡片: top={CARDS_TOP} h={CARD_H} gap={CARD_GAP} x=[{CX0},{CX0+CW}) 左侧8px色块/边框/标题/副标题见 osd_menu")
    print("---- 场景 2/3/4 几何(与 src/osd_scene.v 同源) ----")
    print(f"  会议: 标题2×(ty{MT_TY},gx{MT_GX},N8) 公告1×(ty{MA_TY},gx{MA_GX},N10,4条) "
          f"运行标签1×(ty{MR_TY},gx{MR_GX},N3) 滚动(ty{MF_TY},N20/周期320px)")
    print(f"  抢答: 标题2×(ty{QT_TY},gx{QT_GX},N5) 状态2×(ty{QW_TY},gx256/272/192/288) "
          f"倒计时秒2×(ty{QS_TY},gx{QS_GX},N1) 滚动(ty{QF_TY},N20/320px)")
    print(f"  应急: 标题2×(ty{AT_TY},gx{AT_GX},N10) 滚动(ty{AF_TY},N24/{24*16}px)")
    print(f"  数字带 NUM: N10(0~9), 硬件按 digit 选列(base 见上表)")

    # ---- 生成 Verilog 源文件 ----
    L = []
    A = L.append
    A("//==============================================================================")
    A("// 本文件由 tools/gen_osd_font.py 自动生成 —— 请勿手工修改!")
    A("// OSD 全屏菜单 16×16 点阵字形 ROM (EG4S20 片内 Block RAM)")
    A("//   端口: clk / rst(高) / rd_en(读使能) / addr / q(同步读, 晚 addr 一拍)")
    A("//   位序: MSB(bit15)=格内最左列;  addr = base + row*N + word(0..N-1)")
    A("//   分区表(与 osd_menu.v 几何同源; 2× 带硬件按行列复制放大):")
    for (name, text, n, scale, ty, gx, base, words, ink) in bands:
        A("//     %-5s base=%5d N=%2d scale=%d ty=%3d gx=%3d  \"%s\"" %
          (name, base, n, scale, ty, gx, text))
    A("//==============================================================================")
    A("")
    A("`timescale 1ns/1ps")
    A("")
    A("module osd_font_rom #(")
    A("    parameter ADDR_W = %2d,          // 地址位宽(深度 %d)" % (addr_w, depth))
    A("    parameter DEPTH  = %4d           // 深度(words)" % depth)
    A(")(")
    A("    input  wire              clk,    // 读时钟(video_clk)")
    A("    input  wire              rst,    // 高有效复位(仅清输出寄存器)")
    A("    input  wire              rd_en,  // 读使能")
    A("    input  wire [ADDR_W-1:0] addr,   // 读地址")
    A("    output reg  [15:0]       q       // 读数据(同步输出)")
    A(");")
    A("")
    A("    // 单端口只读 BRAM(官方 afifo 同款推断注释)")
    A("    reg [15:0] mem [0:DEPTH-1]; /* fehdl force_ram=1, ram_style=\"bram\" */")
    A("")
    A("    integer i;")
    A("    initial begin")
    A("        for (i = 0; i < DEPTH; i = i + 1)")
    A("            mem[i] = 16'h0000;")
    base_word = 0
    for (name, text, n, scale, ty, gx, base, words, ink) in bands:
        A("        // ---- %s  \"%s\" (base=%d) ----" % (name, text, base))
        for w in words:
            A("        mem[%d] = 16'h%04X;" % (base_word, w))
            base_word += 1
    A("    end")
    A("")
    A("    always @(posedge clk or posedge rst) begin")
    A("        if (rst)")
    A("            q <= 16'h0000;")
    A("        else if (rd_en)")
    A("            q <= mem[addr];")
    A("    end")
    A("")
    A("endmodule")
    A("")

    out_path = os.path.abspath(OUT_VLOG)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(L))
    print(f"已生成: {out_path}  ({len(L)} 行)")
    print("==========================================")
    return 0


if __name__ == "__main__":
    sys.exit(main())
