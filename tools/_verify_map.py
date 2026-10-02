import glob, hashlib, sys
try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

# 每个 BMP 文件首 512B 的 md5 -> 文件名(用于与卡上扇区一一比对)
fh = {}
for f in glob.glob(r'G:\*.bmp'):
    h = hashlib.md5(open(f, 'rb').read(512)).hexdigest()
    fh[h] = f.split('\\')[-1]

hits = [8448, 10304, 12160, 14016, 15872, 17728, 19584, 26816]
BASE = 64
d = open(r'\\.\G:', 'rb', buffering=0)
for i, s in enumerate(hits, 1):
    d.seek(s * 512)
    h = hashlib.md5(d.read(512)).hexdigest()
    print('%d  卷内 %-7d 物理 %-7d  %s' % (i, s, s + BASE, fh.get(h, '*** 未匹配')))
d.close()
