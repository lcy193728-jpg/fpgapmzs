#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_osd_font.py —— 全屏矢量首页菜单 · 字形 ROM 生成器(数据源唯一, V3)
=====================================================================
V3 相对 V2 的唯一变化(2026-09-17) —— 字模分辨率与字体:
  · scale=2 的带(标题/卡标题/欢迎语/会议标题/抢答标题/应急标题)由
    "16×16 字模 + RTL 行列复制放大到 32×32" 改为 **直接存 32×32 真字模**。
    原因: 16×16 装不下汉字笔画, 密集字(能/端/信)在格内互相挤压成墨团,
    稀疏字仍是 1px 细线 —— 观感"笔画有粗有细"; 且行列复制放大把斜笔
    画(撇捺点)变成 2px 阶梯块。32×32 直渲让 FreeType 在目标尺寸做
    hinting 像素对齐, 笔画均匀、结构清晰。
  · scale=1 的带(副标题/滚动条/公告行/数字)保持 16×16 不变。
  · 字体统一为 **思源黑体 / Noto Sans SC(Noto Sans SC Regular)**。
    (V3.4 定版: 由微软雅黑 Bold 回到思源黑体, 仅换字体, 几何/文案/阈值/
     ROM 格式全部不变。选它作为定版的原因: 16px 小字墨点密度居中
     (「报到地点：东区体育馆」10 字 660/1600 = 41%, 等线 543 偏细、
     雅黑 Bold 1230 偏密易粘连), 笔画规整匀称、中英数字辨识度均衡;
     32px 标题清爽不失力度。)
  · 显示几何(ty/gx/N/带宽)完全不变 —— 32×32 字模 1:1 显示, 其物理尺寸
    恰好等于原 "16×16 放大 2 倍", 因此三个 OSD 模块的几何表无需改动。
  · ROM 位宽 16 → **32**:
        scale=2 带: 每行一个 32bit word, 数据占 rom_q[31:0]
        scale=1 带: 每行一个 32bit word, 数据占 **rom_q[15:0]**(高半填 0)
    这样 RTL 侧 scale=1 的取位表达式 rom_q[15 - ...] 可原样保留。
=====================================================================
用途:
  1. 把菜单各"文字带"渲染成点阵字形, 按 行×N 格 顺序存为字(MSB=最左列);
  2. 生成 Verilog ROM 源文件 src/osd_font_rom.v
     (EG4S20 BRAM: reg[31:0] mem[] + `/* fehdl force_ram=1, ram_style="bram" */`
      初始化 initial 逐字赋值, 与官方 afifo IP 的 BRAM 推断写法一致);
  3. stdout 打印几何表 + 分区 base 表 + 静态文字带采样点(ON/OFF, 物理像素),
     供 tb_osd_menu.v 逐点断言, 以及 osd_menu/osd_welcome/osd_scene 的
     base 常量同步。
=====================================================================
用法:  python tools/gen_osd_font.py
依赖:  Python3 + Pillow, 字体 C:/Windows/Fonts/Noto Sans SC (TrueType).otf
输出:  fpgapmzs/src/osd_font_rom.v
注意: 几何/文案两处同步 = 本文件 + src/osd_menu.v/osd_welcome.v/osd_scene.v;
      改完重跑本脚本再仿真。
=====================================================================
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

# ------------------------------------------------------------------ #
# 0) 布局常量 —— 与 osd_menu.v / osd_welcome.v / osd_scene.v 严格一致
# ------------------------------------------------------------------ #
# 全屏版式 640×480:
#   顶部大标题(TITLE, 物理 32px)          : 行 ty 起 32 行, 9 格
#   四条"卡片"(各 80 行高, 间隔 10):
#       卡左 x=70 宽=500(右 570); 左侧 8px 强调色块; 右/上/下 2px 描边
#       卡标题(物理 32px): 行 top+12 起, x=98, 4 格
#       卡副标题(物理 16px): 行 top+52 起, x=98, N 格(7)
#   底部滚动宣传语条: 黑底行 438~479, 文字行 451~466, 带宽 20 格/行
CELL     = 16                     # ★基准格边长(scale=1 带的字模边长, 也是几何单位)
CELL_BIG = 32                     # ★scale=2 带的字模边长(= 2 × CELL)
H_ACT    = 640
V_ACT    = 480

# ---- 卡片/条带几何 ----
CX0      = 70                     # 卡左边界(含左侧色块)
CW       = 500                    # 卡宽(CX0+CW=570)
TOP0     = 80                     # 第 1 卡 top
CARD_H   = 80                     # 卡高
CARD_GAP = 10                     # 卡间距
# ---- 顶部标题条带 ----
TITLE_TY = 28                     # 标题字形窗行起点(物理 32 行)
TITLE_GX = 176                    # 标题字形窗 x 起点
# ---- 滚动宣传语 ----
MQ_Y0    = 438                    # 宣传语条底色上边
MQ_TY    = 451                    # 宣传语字形行起点(16 行)
MQ_P     = 20                     # 宣传语带 每行格数(条宽 = P*16 px)
MQ_TEXT  = "欢迎使用 校园信息终端 ＳＷ键 切换场景"   # 必须 == MQ_P 格
#   ★滚动带必须逐格对齐(整格周期左移才能无缝循环), 故半角字母改用**全角形**
#     (U+FF33/FF37), 字宽恰为 1 em == 1 格, 不会出现"字母间空半格"。
assert len(MQ_TEXT) == MQ_P, "宣传语长度必须等于 MQ_P(%d), 当前 %d" % (MQ_P, len(MQ_TEXT))

# 各卡 top(4 卡)
CARDS_TOP = [TOP0 + i * (CARD_H + CARD_GAP) for i in range(4)]   # 80/170/260/350

def card_title_ty(i):            # 卡标题(物理 32 高) 字形行起点
    return CARDS_TOP[i] + 12

def card_tag_ty(i):              # 卡副标题(物理 16 高) 字形行起点
    return CARDS_TOP[i] + 52

TEXT_GX = CX0 + 28               # 卡内文字 x 起点(=98)

# ---- 文字带定义: (name, text, scale, ty, gx) ----
#   scale: 1=16px/字格(字模 16×16)   2=32px/字格(字模 32×32, 1:1 显示)
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
# ------------------------------------------------------------------ #
WT_TY   = 14                     # 欢迎语字形行起点(物理 32 行)
WT_GX   = 208                    # 欢迎语字形 x 起点(= (640-7*32)/2)
WT_TEXT = "热烈欢迎新同学"        # 7 格
assert len(WT_TEXT) == 7, "W_TITLE 长度必须为 7"

WL_TY   = 400                    # 报到地点/联系方式 字形行起点(16)
WL_GX   = 85                     # 报到地点字形 x 起点(10 格, 字宽160)
WL_TEXT = "报到地点：东区体育馆"  # 10 格
assert len(WL_TEXT) == 10, "W_PLACE 长度必须为 10"

WR_GX   = 355                    # 联系方式字形 x 起点(15 格, 字宽240)
WR_TEXT = "新生QQ群：123456789"   # 15 格
assert len(WR_TEXT) == 15, "W_CONT 长度必须为 15"

WF_TY   = 452                    # 流程滚动字形行起点(16)
WF_TEXT = "迎新报到流程 签到 领卡 入住 军训物资"   # 必须 == 20 格(320px 周期)
assert len(WF_TEXT) == 20, "W_FLOW 长度必须等于 20"

BANDS.append(("W_TITLE", WT_TEXT, 2, WT_TY, WT_GX))
BANDS.append(("W_PLACE", WL_TEXT, 1, WL_TY, WL_GX))
BANDS.append(("W_CONT",  WR_TEXT, 1, WL_TY, WR_GX))
BANDS.append(("W_FLOW",  WF_TEXT, 1, WF_TY, 0))     # 滚动带 gx 占位 0

# ------------------------------------------------------------------ #
# 会议(M_*) / 抢答(Q_*) / 应急(A_*) / 公共数字(NUM) 文字带
#   ★★ 必须追加在既有带之后(追加不改变旧带 base 的相对关系, 但本版因字模
#      行数变化, 所有 base 均已重算 —— 三个 OSD 模块里的 base 常量须按
#      本脚本 stdout 打印的"分区 base 表"同步)。
#   几何与 src/osd_scene.v 同源, 改动需两处同步并重跑本脚本。
# ------------------------------------------------------------------ #
# ---- 会议场景 ----
MT_TY, MT_GX = 14, 192
MT_TEXT = "校园会议信息公示"           # 8 格(物理 256px, 居中 x=192)
assert len(MT_TEXT) == 8, "MT_TITLE 长度必须为 8"

MA_TY, MA_GX = 196, 240                # 公告行(16px), 每条 10 格(160px, 居中 240)
MA_TEXTS = [
    "第一会议室 项目评审",
    "第二会议室 学术报告",
    "第三会议室 社团例会",
    "综合报告厅 迎新宣讲",
]
for _t in MA_TEXTS:
    assert len(_t) == 10, "会议公告文案长度必须为 10: %s" % _t

MR_TY, MR_GX = 76, 396
MR_TEXT = "已运行"                     # 3 格(16px = 48px)
assert len(MR_TEXT) == 3, "M_RUN 长度必须为 3"

MF_TY = 452
MF_TEXT = "会议进行中 请保持安静 并将手机调至静音"   # 20 格滚动(周期 320px)
assert len(MF_TEXT) == 20, "M_FOOT 长度必须为 20"

# ---- 抢答场景 ----
QT_TY, QT_GX = 20, 240
QT_TEXT = "抢答进行中"                 # 5 格(物理 160px)
assert len(QT_TEXT) == 5, "QT_TITLE 长度必须为 5"

QW_TY, QW_GX = 96, 256
QW_TEXT = "等待开始"                   # 4 格(物理 128px)
assert len(QW_TEXT) == 4, "QW_WAIT 长度必须为 4"

QR_TY, QR_GX = 96, 272
QR_TEXT = "抢答中"                     # 3 格(物理 96px)
assert len(QR_TEXT) == 3, "QR_READY 长度必须为 3"

QWL_TY, QWL_GX = 96, 192
QWL_TEXT = "选手"                      # 2 格(物理 64px)
assert len(QWL_TEXT) == 2, "QWL_WIN 长度必须为 2"

QWR_TY, QWR_GX = 96, 288
QWR_TEXT = "号抢答成功"                # 5 格(物理 160px)
assert len(QWR_TEXT) == 5, "QWR_WIN 长度必须为 5"

QN_TY, QN_GX = 96, 192
QN_TEXT = "时间到 无人抢答"            # 8 格(物理 256px)
assert len(QN_TEXT) == 8, "QN_NONE 长度必须为 8"

QS_TY, QS_GX = 180, 336
QS_TEXT = "秒"                         # 1 格(物理 32px)
assert len(QS_TEXT) == 1, "QS_SEC 长度必须为 1"

QF_TY = 452
QF_TEXT = "请各位选手仔细听题 抢答请按键 先按先得"   # 20 格滚动
assert len(QF_TEXT) == 20, "Q_FOOT 长度必须为 20"

# ---- 应急场景 ----
AT_TY, AT_GX = 82, 160
AT_TEXT = "紧急情况 请立即疏散"         # 10 格(物理 320px)
assert len(AT_TEXT) == 10, "AT_TITLE 长度必须为 10"

AF_TY = 452
AF_TEXT = "紧急告警 请全体人员沿疏散通道迅速撤离 注意安全"  # 24 格滚动(周期 384px)
assert len(AF_TEXT) == 24, "A_FOOT 长度必须为 24"

# ---- 公共数字带(硬件按 digit 选列, 用于时钟/倒计时/页码) ----
NUM_TEXT = "0123456789"                # 10 格(16px)
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

# ---- 采用"自然字距"的静态带(其余静态带均逐格对齐) ----
#   仅含**半角/全角混排**的静态带需要: 等宽格会把半角字符撑满一格, 出现
#   "数字之间空半格"的松散观感。纯汉字带两条路径结果完全一致(汉字 advance
#   == 1 em == 格宽), 故不列入, 以最小化改动面。
#   ★滚动带与 NUM 带禁止列入(见 render_line 说明)。
NATURAL_BANDS = ("W_CONT",)

EMERG_ROWS = 52                  # 应急顶部红条高度(行 0~51)

# ---- 渲染质量 ----
#   两种字模都**按目标尺寸直渲(s=1)**, 让 FreeType 的 hinting 把竖笔画
#   对齐到整数像素 —— 这是"笔画粗细均匀"的关键:
#     · 32×32: 直渲 + 阈值 TH_BIG → 笔画 2px, 结构清晰;
#     · 16×16: 直渲 + 阈值 TH_SML → 笔画 1px。
#   ★不要用"超采样 + LANCZOS 缩回"(曾试 S_SML=4): 缩放会破坏 hinting,
#     二值化后同一带内 1px/2px 笔画混杂(实测竖游程 1px 仅占 42%), 观感
#     "笔画有粗有细"; 直渲后 1px 占比提升到 ~70%, 笔画均匀。
FONT_PATH = r"C:\Windows\Fonts\Noto Sans SC (TrueType).otf"   # 思源黑体(统一大小字)
S_BIG     = 1                     # 32×32 直渲
S_SML     = 1                     # 16×16 直渲(hinting 像素对齐)
TH_BIG    = 112                   # 判墨阈值: 灰度 < TH 记墨(越低笔画越细)
TH_SML    = 128                   # 16px 直渲阈值(112 更细但边缘开始掉点)

OUT_VLOG   = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "src", "osd_font_rom.v"))


# ------------------------------------------------------------------ #
# 1) 渲染工具: 一行文本 -> cell×cellN 的 0/1 矩阵(1=墨)
# ------------------------------------------------------------------ #
def adv_of(fnt, ch) -> float:
    """字符排版宽度(兼容新旧 Pillow)"""
    try:
        return fnt.getlength(ch)
    except AttributeError:
        return fnt.getsize(ch)[0]


def vbox_of(fnt, cell_px: int, th: int, probe: str):
    """量出一组文本的**并集墨盒**相对基线的位置 → (top_rel, ink_h)。
      · top_rel = 墨盒上缘在基线上方多少像素(正值);
      · ink_h   = 墨盒高(像素)。
    ★为什么不用 asc/desc: 思源黑体 asc+desc = 24@16px / 48@32px, 都**大于**
      字模边长, 按 em 盒居中再取整会让 16px 的基线落在第 14 行 → 字形底部
      被裁掉 1 行(实测行 15 有 9~21 个墨点)。改为量真实墨盒:
      16px / 32px 的并集墨盒高都恰等于格边长, 于是 1:1 填满格, 不裁不空。
    ★probe 用**该字号全部文案的字符并集**(而非单个"国"): 单个字的墨盒比整段
      文案窄(如"国"16px 只有 14 行), 据此定位会漏算上下 1 行。
    """
    base = cell_px * 2                              # 画布内任意基线
    img  = Image.new("L", (int(adv_of(fnt, probe)) + cell_px * 2, cell_px * 4), 255)
    ImageDraw.Draw(img).text((cell_px, base), probe, font=fnt, fill=0, anchor="ls")
    bb = img.point(lambda v: 255 if v < th else 0).getbbox()
    return base - bb[1], bb[3] - bb[1]


def render_line(text: str, cell: int, s: int, th: int, natural: bool = False,
                vbox=None) -> list:
    """一行文本 -> cell×cellN 的 0/1 矩阵(1=墨)。

    两种排版模式(由带名决定, 见 NATURAL_BANDS):
      · natural=True  —— **自然字距**: 逐字符按字体实际 advance 累加排版, 整行在
        N 格窗口内居中。汉字 advance == 1 em == 格宽(故纯汉字带与逐格对齐完全
        一致), 半角字母/数字只占约半格 → 不会出现"字母间空半格、又与相邻汉字
        紧贴"的字距忽大忽小。仅用于**静态带**(RTL 按物理像素取址, 与格边界无关)。
      · natural=False —— **逐格对齐**(默认): 每个字符占满一个格宽并在格内水平
        居中。★必须用于: ① 滚动带(整格周期性左移才能无缝循环, 周期 = N*cell);
        ② NUM 数字带(硬件按列号 digit 选列, 必须第 d 列 == 字符 d)。
    """
    n       = len(text)
    cell_px = cell * s
    h_res   = cell * s
    line_w  = n * cell_px
    img     = Image.new("L", (line_w, h_res), 255)
    drw     = ImageDraw.Draw(img)
    fnt     = ImageFont.truetype(FONT_PATH, h_res)
    top_rel, ink_h = vbox if vbox else vbox_of(fnt, cell_px, th, text)
    base_y  = (cell - ink_h) // 2 + top_rel      # 墨盒在格内垂直居中
    advs    = [adv_of(fnt, ch) for ch in text]
    if natural:
        total = sum(advs)
        x     = max(0.0, (line_w - total) / 2.0)     # 整行居中; 超宽则左对齐
        for ch, adv in zip(text, advs):
            drw.text((x, base_y), ch, font=fnt, fill=0, anchor="ls")
            x += adv
    else:
        for i, ch in enumerate(text):
            x = i * cell_px + (cell_px - advs[i]) / 2.0   # 格内水平居中
            drw.text((x, base_y), ch, font=fnt, fill=0, anchor="ls")
    sm  = img.resize((cell * n, cell), Image.LANCZOS)
    px  = sm.load()
    rows = []
    for y in range(cell):
        row = []
        for xx in range(cell * n):
            row.append(1 if px[xx, y] < th else 0)
        rows.append(row)
    return rows


def words_of(rows: list, cell: int) -> list:
    """矩阵(cell×cellN) -> 每行 N 个 cell-bit 字, 顺序 idx = r*N + c; MSB=格内最左。"""
    n_col = len(rows[0]) // cell
    words = []
    for r in range(cell):
        for c in range(n_col):
            w = 0
            for b in range(cell):
                if rows[r][c * cell + b]:
                    w |= 1 << (cell - 1 - b)
            words.append(w)
    return words


# ------------------------------------------------------------------ #
# 2) 生成 ROM 数据 + 统计
# ------------------------------------------------------------------ #
def main():
    assert os.path.exists(FONT_PATH), f"未找到字体: {FONT_PATH}"

    # ---- 垂直定位: 每个字号量一次"全部文案字符并集"的墨盒, 所有带共用 → 带间基线一致 ----
    vbox = {}
    for cell, s, th in ((CELL, S_SML, TH_SML), (CELL_BIG, S_BIG, TH_BIG)):
        probe = "".join(t for (_n, t, sc, _ty, _gx) in BANDS
                        if (CELL_BIG if sc == 2 else CELL) == cell)
        fnt   = ImageFont.truetype(FONT_PATH, cell * s)
        vbox[cell] = vbox_of(fnt, cell * s, th, probe)
        print(f"垂直定位 cell={cell}: top_rel={vbox[cell][0]} ink_h={vbox[cell][1]}"
              f" → 墨盒占 0..{vbox[cell][1] - 1} 行")

    bands = []                    # [name, text, n, scale, ty, gx, base, words, ink, cell]
    word_cum = 0
    for name, text, scale, ty, gx in BANDS:
        n     = len(text)
        cell  = CELL_BIG if scale == 2 else CELL
        s     = S_BIG    if scale == 2 else S_SML
        th    = TH_BIG   if scale == 2 else TH_SML
        rows  = render_line(text, cell, s, th, natural=(name in NATURAL_BANDS),
                            vbox=vbox[cell])
        words = words_of(rows, cell)
        assert len(words) == n * cell, "%s: 字数 %d ≠ %d" % (name, len(words), n * cell)
        ink   = sum(bin(w).count("1") for w in words)
        base  = word_cum
        bands.append((name, text, n, scale, ty, gx, base, words, ink, cell))
        word_cum += n * cell
    depth = word_cum
    addr_w = max(1, (depth - 1).bit_length())

    # ---- 数字带逐字符墨点(供 TB 精确推算"动态数字区域"的期望计数) ----
    #   字模按列-主序存放: 字符 c 的 cell 行位于 words[r*n + c] (r=0..cell-1)
    num_ch_ink = []
    for (name, text, n, scale, ty, gx, base, words, ink, cell) in bands:
        if name == "NUM":
            for c in range(n):
                num_ch_ink.append(sum(bin(words[r * n + c]).count("1")
                                      for r in range(cell)))

    # ---- 采样点: 静态带各给 1 个字形 ON 与 1 个空白 OFF(物理像素) ----
    #   V3 起字模与显示 1:1(不再有 RTL 放大), 物理 x = gx + fcol, 物理 y = ty + row
    spot = []
    for (name, text, n, scale, ty, gx, base, words, ink, cell) in bands:
        if name in SCROLL_BANDS:
            continue   # 滚动带无法给出固定采样点
        if name == "NUM":
            continue   # 动态选列带(0~9), 无固定采样点
        def phys(px, py):
            return (gx + px, ty + py)
        on = None
        for r in range(cell):
            for c in range(n):
                w = words[r * n + c]
                if w:
                    b = cell - 1
                    while not (w & (1 << b)):
                        b -= 1
                    # ★必须含 c*cell: 首个非空格可能不在第 0 格(否则坐标会偏到左边)
                    fx, fy = phys(c * cell + (cell - 1 - b), r)   # MSB=左 -> 列=cell-1-b
                    on = (name, fx, fy)
                    break
            if on:
                break
        off = None
        found = False
        for r in range(cell):
            for c in range(n):
                w = words[r * n + c]
                for b in range(cell):                  # MSB..LSB = 格内左..右
                    if not (w & (1 << (cell - 1 - b))):  # 该像素为 0(空白)
                        fx = gx + c * cell + b
                        fy = ty + r
                        off = (name, fx, fy)
                        found = True
                        break
                if found:
                    break
            if found:
                break
        spot.append((on, off))

    # ---- 打印统计(供 TB 与三个 OSD 模块的 base 常量同步) ----
    print("======== gen_osd_font V3 输出 ========")
    print(f"字体={os.path.basename(FONT_PATH)}  字模: scale=2 用 {CELL_BIG}×{CELL_BIG}(直渲 th{TH_BIG}) / "
          f"scale=1 用 {CELL}×{CELL}(超采{S_SML}× th{TH_SML})")
    print(f"ROM 位宽=32bit  深度(words)={depth}  ADDR_W={addr_w}  ({depth*32//1024}Kbit)")
    print("---- 分区 base 表(★RTL 里的 base 常量必须与此一致) ----")
    for (name, text, n, scale, ty, gx, base, words, ink, cell) in bands:
        print(f"  {name:8s} base={base:5d} N={n:2d} cell={cell:2d} scale={scale} ty={ty:3d} gx={gx:3d} "
              f"墨点={ink:4d} \"{text}\"")
    print("静态文字带采样点 (物理像素, ON=字形应写字色 / OFF=字形区内应底色):")
    for (on, off) in spot:
        print(f"  {on[0]:8s} ON=({on[1]},{on[2]})  OFF=({off[1]},{off[2]})")
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
    A("// OSD 点阵字形 ROM (EG4S20 片内 Block RAM), V3: 32bit 宽, scale=2 带存 32×32 真字模")
    A("//   端口: clk / rst(高) / rd_en(读使能) / addr / q(同步读, 晚 addr 一拍)")
    A("//   位序: scale=2 带 —— MSB(bit31)=格内最左列, 字模 32×32, 取位 q[31-c]")
    A("//         scale=1 带 —— 数据在 q[15:0](高 16 位填 0), MSB(bit15)=格内最左列, 取位 q[15-c]")
    A("//   addr = base + row*N + word(0..N-1);  row 数: scale=2 为 32, scale=1 为 16")
    A("//   分区表(与 osd_menu/osd_welcome/osd_scene 几何同源):")
    for (name, text, n, scale, ty, gx, base, words, ink, cell) in bands:
        A("//     %-8s base=%5d N=%2d cell=%2d scale=%d ty=%3d gx=%3d  \"%s\"" %
          (name, base, n, cell, scale, ty, gx, text))
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
    A("    output reg  [31:0]       q       // 读数据(同步输出)")
    A(");")
    A("")
    A("    // 单端口只读 BRAM(官方 afifo 同款推断注释)")
    A("    reg [31:0] mem [0:DEPTH-1]; /* fehdl force_ram=1, ram_style=\"bram\" */")
    A("")
    A("    integer i;")
    A("    initial begin")
    A("        for (i = 0; i < DEPTH; i = i + 1)")
    A("            mem[i] = 32'h0000_0000;")
    base_word = 0
    for (name, text, n, scale, ty, gx, base, words, ink, cell) in bands:
        A("        // ---- %s  \"%s\" (base=%d, cell=%d) ----" % (name, text, base, cell))
        for w in words:
            if cell == CELL_BIG:
                A("        mem[%d] = 32'h%08X;" % (base_word, w))
            else:
                A("        mem[%d] = 32'h0000_%04X;" % (base_word, w))
            base_word += 1
    A("    end")
    A("")
    A("    always @(posedge clk or posedge rst) begin")
    A("        if (rst)")
    A("            q <= 32'h0000_0000;")
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
