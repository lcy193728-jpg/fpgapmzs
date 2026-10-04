#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
export_rom_dath.py —— 把 Verilog 里 `mem[i] = N'hxxxx;` 形式的 ROM 初始数据
导出为 TD `EG_LOGIC_BRAM` 的 .INIT_FILE 所需的 .dath 文件。

.dath 格式（实测自 TD ip/depot 官方样例 mcu_rom.dath）:
  每行一个数据项, 小写 hex, 位数 = 数据位宽/4。
  - 16bit 数据 → 每行 4 位 hex
  - 32bit 数据 → 每行 8 位 hex

用法:
  python export_rom_dath.py <rom.v> <宽度bit> <输出.dath>
  例: python export_rom_dath.py src/meeting_glyph_rom.v 16 audio_final/assets/meeting_glyph.dath

注意: 只解析 `mem[...] = <N>'h<hex>;` 与 `mem[...] = <N>'b<bin>;` 两种写法,
      按 mem 下标从小到大输出。
"""
import re
import sys
import os

def parse_rom(path):
    entries = []
    rx_h = re.compile(r'mem\s*\[\s*(\d+)\s*\]\s*=\s*\d+\'h([0-9a-fA-F]+)\s*;')
    rx_b = re.compile(r'mem\s*\[\s*(\d+)\s*\]\s*=\s*\d+\'b([01]+)\s*;')
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            m = rx_h.search(line)
            if m:
                idx = int(m.group(1)); val = int(m.group(2), 16)
                entries.append((idx, val)); continue
            m = rx_b.search(line)
            if m:
                idx = int(m.group(1)); val = int(m.group(2), 2)
                entries.append((idx, val)); continue
    if not entries:
        print(f"[ERR] 未解析到任何 mem 数据, 请检查 {path}", file=sys.stderr)
        sys.exit(1)
    entries.sort(key=lambda t: t[0])
    return entries

def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(2)
    src, width, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    entries = parse_rom(src)

    # 校验下标连续性
    idxs = [t[0] for t in entries]
    expect = list(range(len(entries)))
    if idxs != expect:
        missing = [i for i in expect if i not in idxs]
        print(f"[WARN] mem 下标不连续: 缺 {missing[:20]}...", file=sys.stderr)

    hex_w = (width + 3) // 4  # 16bit->4, 32bit->8
    n = len(entries)
    os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
    with open(out, 'w', encoding='utf-8') as f:
        for _, val in entries:
            f.write(f"{val:0{hex_w}x}\n")
    print(f"[OK] 导出 {n} 项 x {width}bit -> {out} ({n} 行, 每行 {hex_w} hex)")

if __name__ == '__main__':
    main()
