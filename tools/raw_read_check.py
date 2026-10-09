#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""裸读 TF 卡某物理 LBA 起的内容, 与本地文件比对 sha256。
用法: python raw_read_check.py <physLBA> <localFile> [base=64] [bytes]
裸卷必须 os.open(O_RDWR)+lseek/read 且单次读 <= 32KB 分块 (Windows 裸卷限制)。
"""
import os, sys, hashlib

phys = int(sys.argv[1])
localf = sys.argv[2]
base = int(sys.argv[3]) if len(sys.argv) > 3 else 64
nbytes = int(sys.argv[4]) if len(sys.argv) > 4 else os.path.getsize(localf)

fd = os.open("\\\\.\\G:", os.O_RDWR | os.O_BINARY)
off = (phys - base) * 512
os.lseek(fd, off, 0)
chunks = []
remaining = nbytes
CHUNK = 32768
while remaining > 0:
    want = min(CHUNK, remaining)
    c = os.read(fd, want)
    if not c:
        break
    chunks.append(c)
    remaining -= len(c)
os.close(fd)
data = b"".join(chunks)
h = hashlib.sha256(data).hexdigest().upper()
lh = hashlib.sha256(open(localf, "rb").read()).hexdigest().upper()
print("read_bytes ", len(data))
print("head       ", data[:2])
print("card_sha256", h)
print("file_sha256", lh)
print("MATCH      ", h == lh)
