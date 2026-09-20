#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
FONT = r"C:\Windows\Fonts\Noto Sans SC (TrueType).otf"
OUT = ROOT / "src" / "emergency_font_rom.v"

lines = [
    "紧急告警", "火灾警报", "地震避险", "恶劣天气", "临时疏散",
    "告警级别：紧急", "告警级别：警告", "告警级别：提示",
    "事件地点：实验楼三层", "事件地点：校园室外", "事件地点：教学楼区域",
    "请沿东侧安全通道有序撤离", "禁止乘坐电梯",
    "远离玻璃和高大物体", "双手保护头部",
    "暂停室外活动前往室内安全区", "远离树木和高空坠物",
    "按照现场人员指引有序撤离", "前往东区操场集合点",
    "持续时间：", "告警尚未解除", "仅管理员可解除告警",
    "按键四切换告警类型", "0123456789："
]
chars = []
for s in lines:
    for ch in s:
        if ch not in chars:
            chars.append(ch)
ids = {ch: i for i, ch in enumerate(chars)}

font = ImageFont.truetype(FONT, 16)
def glyph(ch):
    canvas = Image.new("L", (32, 32), 255)
    d = ImageDraw.Draw(canvas)
    box = d.textbbox((0, 0), ch, font=font)
    w, h = box[2]-box[0], box[3]-box[1]
    d.text(((16-w)//2-box[0], (16-h)//2-box[1]), ch, font=font, fill=0)
    crop = canvas.crop((0, 0, 16, 16))
    return [sum((1 << (15-x)) for x in range(16) if crop.getpixel((x,y)) < 150) for y in range(16)]

with OUT.open("w", encoding="utf-8", newline="\n") as f:
    f.write("`timescale 1ns/1ps\nmodule emergency_font_rom(input wire clk,input wire en,input wire [10:0] addr,output reg [15:0] q);\n")
    f.write(f"  reg [15:0] mem [0:{len(chars)*16-1}]; integer i;\n  initial begin\n")
    for ch, idx in ids.items():
        for row, bits in enumerate(glyph(ch)):
            f.write(f"    mem[{idx*16+row}] = 16'h{bits:04X};\n")
    f.write("  end\n  always @(posedge clk) if(en) q<=mem[addr];\nendmodule\n")

map_out = ROOT / "src" / "emergency_text_map.vh"
with map_out.open("w", encoding="utf-8", newline="\n") as f:
    f.write("function [6:0] emergency_glyph_id;\n")
    f.write("  input [4:0] text_id; input [4:0] char_pos;\n  begin\n")
    f.write("    emergency_glyph_id = 7'h7f;\n    case ({text_id,char_pos})\n")
    for tid, text in enumerate(lines):
        f.write(f"      // {tid}: {text}\n")
        for pos, ch in enumerate(text):
            f.write(f"      10'd{tid*32+pos}: emergency_glyph_id = 7'd{ids[ch]};\n")
    f.write("      default: emergency_glyph_id = 7'h7f;\n    endcase\n  end\nendfunction\n")
    f.write("function [4:0] emergency_text_len; input [4:0] text_id; begin\n")
    f.write("  case(text_id)\n")
    for tid, text in enumerate(lines):
        f.write(f"    5'd{tid}: emergency_text_len = 5'd{len(text)};\n")
    f.write("    default: emergency_text_len = 5'd0;\n  endcase\nend endfunction\n")
print(f"generated {OUT} with {len(chars)} glyphs ({len(chars)*16} words)")
print("CHAR_IDS=" + repr(ids))
