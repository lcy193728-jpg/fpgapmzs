#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate true 2-bit coverage ROMs for menu and emergency big text.

The coverage comes directly from FreeType's grayscale rasterizer.  Keeping the
four alpha levels in ROM preserves diagonal/vertical edge information that
cannot be reconstructed from a thresholded 1-bit glyph in RTL.
"""
from pathlib import Path
import sys
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_osd_font as menu_src

MENU_FONT = r"C:\Windows\Fonts\Noto Sans SC Medium (TrueType).otf"
EMERG_FONT = r"C:\Windows\Fonts\Noto Sans SC Bold (TrueType).otf"
SUPERSAMPLE = 4
MENU_OUT = ROOT / "src" / "osd_menu_aa_rom.v"
EMERG_OUT = ROOT / "src" / "emergency_big_font_rom.v"
EMERG_TITLE_OUT = ROOT / "src" / "emergency_title_font_rom.v"


def quantize(img):
    """8-bit FreeType coverage -> 2-bit alpha, rounded to the nearest quarter."""
    p = img.load()
    return [[min(3, max(0, ((255 - p[x, y]) * 3 + 127) // 255))
             for x in range(img.width)] for y in range(img.height)]


def menu_line(text, vbox):
    cell = 32
    hi = cell * SUPERSAMPLE
    img = Image.new("L", (len(text) * hi, hi), 255)
    draw = ImageDraw.Draw(img)
    font = ImageFont.truetype(MENU_FONT, hi)
    top_rel, ink_h = vbox
    base_y = (hi - ink_h) // 2 + top_rel
    for i, ch in enumerate(text):
        adv = menu_src.adv_of(font, ch)
        x = i * hi + (hi - adv) / 2.0
        draw.text((x, base_y), ch, font=font, fill=0, anchor="ls")
    return quantize(img.resize((len(text) * cell, cell), Image.Resampling.LANCZOS))


def glyph_square(ch, cell, font_path):
    hi = cell * SUPERSAMPLE
    img = Image.new("L", (hi, hi), 255)
    draw = ImageDraw.Draw(img)
    font = ImageFont.truetype(font_path, hi)
    box = draw.textbbox((0, 0), ch, font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    draw.text(((hi - w) / 2 - box[0], (hi - h) / 2 - box[1]),
              ch, font=font, fill=0)
    return quantize(img.resize((cell, cell), Image.Resampling.LANCZOS))


def packed_words_of(cov, cell):
    """Square-cell coverage matrix -> row-major 2-bit words, pixel 0 at MSB."""
    n_col = len(cov[0]) // cell
    words = []
    for row in cov:
        for cell_no in range(n_col):
            word = 0
            for x in range(cell):
                word |= (row[cell_no * cell + x] & 3) << (2 * (cell - 1 - x))
            words.append(word)
    return words


def emit(path, module, words, addr_w, data_w):
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write("`timescale 1ns/1ps\n")
        f.write(f"module {module}(input wire clk,input wire en,input wire [{addr_w-1}:0] addr,output reg [{data_w-1}:0] q);\n")
        f.write(f"  reg [{data_w-1}:0] mem [0:{len(words)-1}];\n")
        f.write("  /* synthesis syn_ramstyle=\"block_ram\" */\n")
        f.write("  initial begin\n")
        for i, word in enumerate(words):
            f.write(f"    mem[{i}] = {data_w}'h{word:0{data_w // 4}X};\n")
        f.write("  end\n  always @(posedge clk) if(en) q <= mem[addr];\nendmodule\n")


def emit_emergency_32k(path, glyph_cov):
    """Emit a 64px 2-bit pixel ROM backed by five EG4 BRAM32K blocks.

    A row-wide inferred ROM consumes 19 BRAM9K blocks and cannot fit the
    nearly-full design. Linear pixel addressing plus 8:1 packing maps the
    same 155,648 bits onto five physical 2Kx16 BRAM32K blocks.
    """
    pixels = []
    for cov in glyph_cov:
        for row in cov:
            pixels.extend(row)
    assert len(pixels) == 19 * 64 * 64
    bank_depth = 16384
    banks = []
    for bank_no in range(5):
        bank_pixels = pixels[bank_no * bank_depth:(bank_no + 1) * bank_depth]
        bank_pixels += [0] * (bank_depth - len(bank_pixels))
        # EMB32 is physically 16 bits x 2048. Packing eight 2-bit coverage
        # samples into each word prevents four-deep block cascading.
        bank = []
        for word_base in range(0, bank_depth, 8):
            word = 0
            for lane in range(8):
                word |= bank_pixels[word_base + lane] << (2 * lane)
            bank.append(word)
        banks.append(bank)
        dat = ROOT / "src" / f"emergency_big_font_bank{bank_no}.dat"
        with dat.open("w", encoding="ascii", newline="\n") as f:
            for value in bank:
                f.write(f"{value:016b}\n")

    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write("`timescale 1ns/1ps\n")
        f.write("module emergency_big_font_rom(input wire clk,input wire en,input wire [16:0] addr,output reg [1:0] q);\n")
        f.write("  wire [2:0] bank=addr[16:14]; wire [10:0] local_addr=addr[13:3];\n")
        f.write("  reg [2:0] bank_q,lane_q; wire [15:0] q0,q1,q2,q3,q4; reg [15:0] word_q;\n")
        f.write("  always @(posedge clk) if(en) begin bank_q<=bank; lane_q<=addr[2:0]; end\n")
        for bank_no in range(5):
            f.write("  EG_LOGIC_BRAM #(\n")
            f.write("    .DATA_WIDTH_A(16),.DATA_WIDTH_B(16),.ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),\n")
            f.write("    .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),.MODE(\"SP\"),\n")
            f.write("    .REGMODE_A(\"NOREG\"),.REGMODE_B(\"NOREG\"),.IMPLEMENT(\"32K\"),\n")
            # top_final.v includes this module from audio_final/integrated;
            # TD resolves INIT_FILE relative to that compilation unit.
            f.write(f"    .INIT_FILE(\"../../src/emergency_big_font_bank{bank_no}.dat\")\n")
            f.write(f"  ) u_bank{bank_no}(.doa(q{bank_no}),.dob(),.dia(16'b0),.dib(16'b0),\n")
            f.write(f"    .cea(en&&(bank==3'd{bank_no})),.ocea(1'b1),.clka(clk),.wea(1'b0),.rsta(1'b0),.bea(1'b0),\n")
            f.write("    .ceb(1'b0),.oceb(1'b1),.clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),\n")
            f.write("    .addra(local_addr),.addrb(11'd0));\n")
        f.write("  always @(*) begin\n")
        f.write("    case(bank_q)\n")
        f.write("      3'd0:word_q=q0; 3'd1:word_q=q1; 3'd2:word_q=q2; 3'd3:word_q=q3; 3'd4:word_q=q4; default:word_q=16'd0;\n")
        f.write("    endcase\n")
        f.write("    case(lane_q)\n")
        f.write("      3'd0:q=word_q[1:0]; 3'd1:q=word_q[3:2]; 3'd2:q=word_q[5:4]; 3'd3:q=word_q[7:6];\n")
        f.write("      3'd4:q=word_q[9:8]; 3'd5:q=word_q[11:10]; 3'd6:q=word_q[13:12]; default:q=word_q[15:14];\n")
        f.write("    endcase\n  end\nendmodule\n")


def main():
    menu_texts = ["校园多功能信息终端", "迎新展示", "会议公示", "抢答现场", "应急告警"]
    # Match gen_osd_font.py's global 32px baseline so enabling AA does not move text.
    probe = "".join(t for (_n, t, sc, _ty, _gx) in menu_src.BANDS if sc == 2)
    font = ImageFont.truetype(MENU_FONT, 32 * SUPERSAMPLE)
    vbox = menu_src.vbox_of(font, 32 * SUPERSAMPLE,
                            menu_src.TH_BIG, probe)
    menu_words = []
    for text in menu_texts:
        menu_words.extend(packed_words_of(menu_line(text, vbox), 32))
    assert len(menu_words) == 800
    emit(MENU_OUT, "osd_menu_aa_rom", menu_words, 10, 64)

    big_lines = ["紧急告警", "火灾警报", "地震避险", "恶劣天气", "临时疏散"]
    big_chars = []
    for text in big_lines:
        for ch in text:
            if ch not in big_chars:
                big_chars.append(ch)
    assert len(big_chars) == 19
    # Render at the final display size. No RTL enlargement remains in the
    # 64px alarm path, so the supersampled FreeType contour reaches HDMI intact.
    emergency_cell = 64
    emergency_cov = []
    for ch in big_chars:
        emergency_cov.append(glyph_square(ch, emergency_cell, EMERG_FONT))
    emit_emergency_32k(EMERG_OUT, emergency_cov)

    title_chars = list("紧急告警")
    title_words = []
    for ch in title_chars:
        title_words.extend(packed_words_of(
            glyph_square(ch, 32, MENU_FONT), 32))
    emit(EMERG_TITLE_OUT, "emergency_title_font_rom", title_words, 7, 64)
    print(f"generated {MENU_OUT} ({len(menu_words)}x64)")
    print(f"generated {EMERG_OUT} (77824x2 in 5x BRAM32K), chars={''.join(big_chars)}")
    print(f"generated {EMERG_TITLE_OUT} ({len(title_words)}x64)")


if __name__ == "__main__":
    main()
