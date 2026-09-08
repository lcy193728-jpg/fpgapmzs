import os, struct

f = open(r'\\.\F:', 'rb')

# 搜索扫描范围内(16000~126656)所有 8 对齐扇区的 "BM" 头，看是否有假 BM 导致 img_cnt 误判
start = 16000
end = 126656
f.seek(start * 512)
data = f.read((end - start) * 512)
f.close()

hits = []
for s in range(0, end - start, 8):   # 每 8 扇区跳（模拟扫描）
    i = s * 512
    if i + 54 > len(data):
        break
    if data[i] == 0x42 and data[i+1] == 0x4D:  # "BM"
        sector = start + s
        file_len = struct.unpack('<I', data[i+2:i+6])[0]
        width    = struct.unpack('<I', data[i+18:i+22])[0]
        height   = struct.unpack('<i', data[i+22:i+26])[0]
        bitcnt   = struct.unpack('<H', data[i+28:i+30])[0]
        hits.append((sector, file_len, width, height, bitcnt))

print(f'扫描范围 {start}~{end} 内，8对齐扇区命中 BM 共 {len(hits)} 个：')
for h in hits:
    # 判断是否会被严格校验误判(宽640 高480 24bit 长921654)
    ok = (h[1]==921654 and h[2]==640 and h[3]==480 and h[4]==24)
    print(f'  扇区 {h[0]}  file_len={h[1]}  width={h[2]}  height={h[3]}  bit={h[4]}  {"<== 会误判!" if ok else ""}')
