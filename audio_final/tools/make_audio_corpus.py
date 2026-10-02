#!/usr/bin/env python3
"""make_audio_corpus.py —— 把任意 WAV 歌曲转成 TF 卡上的裸 PCM 音源

与 FPGA 端的对应关系(见 ../rtl/wav_stream_player.v):
  · 格式: 裸 16 bit **有符号** PCM, **小端序**, **48 kHz**, **单声道**
          (TF 先低字节后高字节; 无任何文件头 —— 播放器只认 起始 LBA + 总扇区数)
  · 512 字节 = 1 扇区 = 256 个样本(16 bit); 尾部补 0 补齐到扇区整数倍
  · 数据**不放进文件系统**里的普通文件, 而是直接写到卡的固定 LBA 区间
    (默认 300000 起), 这样扇区天然连续 —— 播放器才能连续读而不必解 FAT。

卡上现有布局(不可与本音源区重叠):
  · 126656 ~ 135703   BMP 四场景分区(scan 区域)
  · 200000 ~ 200002   会议议程 MTG1 配置(3 扇区)
  · 300000 起         ← 本工具输出的音乐素材区

用法:
  python make_audio_corpus.py 好听的歌.wav
  python make_audio_corpus.py 好听的歌.wav --name wel_music --peak 0.9
  python make_audio_corpus.py 好听的歌.wav --lba 300000 --verify-physical 2

输出:
  audio_final/assets/<name>_48k_mono.raw     ← 拷进 TF 卡的裸 PCM
  audio_final/assets/<name>_48k_mono.wav     ← 参考回放(仅便于 PC 上试听/比对)
  audio_final/assets/<name>_48k_mono.json    ← 元数据(sha256 / 扇区数 / 布局)
  终端打印: 可直接粘进 top_final.v 的 localparam, 以及写卡命令
"""
import argparse
import hashlib
import json
import sys
import wave
from pathlib import Path

import numpy as np
from scipy.signal import resample_poly

RATE = 48000
BYTES_PER_SECTOR = 512
# 卡上已被占用的扇区区间 [start, end) (含 start, 不含 end), 音乐区不得与之重叠
RESERVED = [(126656, 135704), (200000, 200003)]


def die(msg):
    print(f"\n[ERROR] {msg}\n", file=sys.stderr)
    sys.exit(1)


def read_wav_mono(path):
    """读 WAV → 单声道 float32(未重采样)。仅依赖标准库 wave + numpy。

    支持 PCM 8/16/24/32 bit(含 WAVE_FORMAT_EXTENSIBLE); 多声道下混为单声道。
    MP3/AAC 等压缩格式请先用任意工具转成 WAV  (例如 ffmpeg -i song.mp3 song.wav)。
    """
    if not path.is_file():
        die(f"找不到输入文件: {path}")
    if path.suffix.lower() != ".wav":
        die(f"只支持 WAV(无损 PCM), 当前是 {path.suffix}。"
            f"请先转换: ffmpeg -i \"{path.name}\" \"{path.stem}.wav\"")
    try:
        with wave.open(str(path), "rb") as w:
            ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
            raw = w.readframes(n)
    except wave.Error as e:
        die(f"不是可解析的 PCM WAV(压缩/损坏?): {e}")
    if sr <= 0 or n <= 0:
        die("输入音频为空")
    if sw == 1:                                     # 8 bit 无符号
        d = (np.frombuffer(raw, "u1").astype(np.float32) - 128.0) / 128.0
    elif sw == 2:                                   # 16 bit 有符号(最常见)
        d = np.frombuffer(raw, "<i2").astype(np.float32) / 32768.0
    elif sw == 3:                                   # 24 bit 有符号
        b = np.frombuffer(raw, "u1").reshape(-1, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        v = np.where(v & 0x800000, v - 0x1000000, v)
        d = v.astype(np.float32) / 8388608.0
    elif sw == 4:                                   # 32 bit 有符号
        d = np.frombuffer(raw, "<i4").astype(np.float32) / 2147483648.0
    else:
        die(f"不支持的位深 {sw*8} bit(仅支持 8/16/24/32)")
    if ch > 1:
        d = d.reshape(-1, ch).mean(axis=1)           # 立体声→单声道(求平均)
    return d, sr, ch


def write_wav_mono(path, pcm_i2, rate):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm_i2.astype("<i2").tobytes())


def load_mono(path, max_seconds):
    """读任意 WAV → 单声道 float32(未重采样)。"""
    mono, sr, _ch = read_wav_mono(path)
    mono = mono - float(np.mean(mono))              # 去直流(避免整排柱偏置)
    if max_seconds:
        mono = mono[: int(sr * max_seconds)]
    if mono.size == 0:
        die("截取后样本数为 0, 请检查 --max-seconds")
    return mono, sr


def build_pcm(mono, sr, peak, fade_ms):
    """重采样到 48 kHz → 淡入淡出 → 归一化 → 16 bit 小端 → 扇区对齐补零。"""
    y = resample_poly(mono, RATE, sr).astype(np.float32)
    if y.size == 0:
        die("重采样后样本数为 0")
    # 首尾各淡 fade_ms, 消除起播/收尾的爆音(与 prepare_alarm_audio.py 同样的处理)
    fade = max(1, RATE * fade_ms // 1000)
    fade = min(fade, y.size // 2)
    if fade > 0:
        y[:fade] *= np.linspace(0.0, 1.0, fade, dtype=np.float32)
        y[-fade:] *= np.linspace(1.0, 0.0, fade, dtype=np.float32)
    # 峰值归一化到 peak(默认 0.90 ≈ -0.9 dBFS, 留一点余量避免重建滤波过冲削顶)
    m = float(np.max(np.abs(y)))
    if m > 0:
        y = y * (peak / m)
    pcm = np.clip(np.rint(y * 32767.0), -32768, 32767).astype("<i2")
    raw = pcm.tobytes()
    pad = (-len(raw)) % BYTES_PER_SECTOR              # 尾部补 0 到扇区整数倍
    if pad:
        raw = raw + b"\x00" * pad
    return pcm, raw, pad


def check_layout(lba, sectors):
    if lba % 8 != 0:
        die(f"起始 LBA 必须 8 扇区(4 KB)对齐, 现值 {lba}")
    end = lba + sectors
    for r0, r1 in RESERVED:
        if lba < r1 and end > r0:
            die(f"音乐区 [{lba},{end}) 与已占用区间 [{r0},{r1}) 重叠")
    return end


def write_commands(raw_path, lba, sectors):
    """打印把裸 PCM 写到卡上固定偏移的命令(需要管理员权限)。"""
    off = lba * BYTES_PER_SECTOR
    size = sectors * BYTES_PER_SECTOR
    print("=" * 72)
    print("把裸 PCM 写到 TF 卡固定扇区(需管理员权限; 先确认物理盘号, 别写错盘!)")
    print("=" * 72)
    print(f"  文件      : {raw_path}")
    print(f"  起始字节  : {off}  (= {lba} 扇区 x 512)")
    print(f"  字节数    : {size}  ({size/1048576:.2f} MB = {sectors} 扇区)")
    print("\n  # 1) 查物理盘号(管理员 PowerShell):")
    print("  Get-Disk | Select-Object Number,FriendlyName,Size")
    print("\n  # 2) 写入(把 2 换成上面看到的 TF 卡盘号; 此操作会覆盖该盘从")
    print("  #    153600000 字节起的区域, 不会动别的数据, 但请务必核对盘号):")
    print("  $img = (Resolve-Path '%s').Path" % raw_path)
    print(f"  $fs = [IO.File]::Open('\\\\.\\PhysicalDrive2','Open','Write')")
    print(f"  $fs.Seek({off}, 'Begin')")
    print("  $b = [IO.File]::ReadAllBytes($img)")
    print("  $fs.Write($b, 0, $b.Length); $fs.Flush(); $fs.Close()")
    print("\n  # 3) 回读校验(可选):")
    print(f"  python tools/make_audio_corpus.py --verify-physical 2 "
          f"--lba {lba} --name <name>")
    print("  (或本脚本已生成的 .raw 直接与回读文件比对 sha256)")


def verify_physical(dev_no, lba, raw_path):
    """从物理盘回读该区间并比对 sha256(不做改动, 需管理员)。"""
    want = raw_path.read_bytes()
    path = f"\\\\.\\PhysicalDrive{dev_no}"
    try:
        f = open(path, "rb")            # 只读
    except OSError as e:
        die(f"打不开 {path}(需要管理员权限): {e}")
    with f:
        f.seek(lba * BYTES_PER_SECTOR)
        got = f.read(len(want))
    hw, hg = hashlib.sha256(want).hexdigest(), hashlib.sha256(got).hexdigest()
    print(f"  expect sha256 = {hw}")
    print(f"  on-card sha256 = {hg}")
    print("  RESULT: " + ("PASS 卡上数据与生成文件一致" if hw == hg else "FAIL 不一致!"))
    return hw == hg


def main():
    ap = argparse.ArgumentParser(
        description="WAV → TF 卡裸 PCM 音源(48kHz/16bit/mono/小端/扇区对齐)",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", nargs="?", help="输入音频(WAV; 压缩格式请先转 WAV)")
    ap.add_argument("--name", default=None, help="素材名(默认取输入文件名)")
    ap.add_argument("--lba", type=int, default=300000, help="音乐区起始扇区(默认 300000)")
    ap.add_argument("--max-seconds", type=float, default=0.0, help="只取前 N 秒(0=整首)")
    ap.add_argument("--peak", type=float, default=0.90, help="峰值归一化系数(默认 0.90)")
    ap.add_argument("--fade-ms", type=int, default=30, help="首尾淡入淡出毫秒(默认 30)")
    ap.add_argument("--verify-physical", type=int, default=None, metavar="N",
                    help="只做校验: 从物理盘 N 回读并比对(需管理员)")
    args = ap.parse_args()

    assets = Path(__file__).resolve().parent.parent / "assets"
    assets.mkdir(parents=True, exist_ok=True)

    if args.verify_physical is not None:
        if not args.name:
            die("--verify-physical 需要同时给 --name(或 positional input 当作素材名)")
        stem = args.name or Path(args.input).stem
        ok = verify_physical(args.verify_physical, args.lba,
                             assets / f"{stem}_48k_mono.raw")
        sys.exit(0 if ok else 1)

    if not args.input:
        die("缺少输入音频文件(或改用 --verify-physical 校验模式)")
    src = Path(args.input).resolve()
    stem = args.name or src.stem

    mono, sr = load_mono(src, args.max_seconds)
    pcm, raw, pad = build_pcm(mono, sr, args.peak, args.fade_ms)

    sectors = len(raw) // BYTES_PER_SECTOR
    end_lba = check_layout(args.lba, sectors)

    raw_path = assets / f"{stem}_48k_mono.raw"
    ref_path = assets / f"{stem}_48k_mono.wav"
    meta_path = assets / f"{stem}_48k_mono.json"
    raw_path.write_bytes(raw)
    write_wav_mono(ref_path, pcm, RATE)

    sha = hashlib.sha256(raw).hexdigest()
    meta = {
        "source": str(src),
        "source_sha256": hashlib.sha256(src.read_bytes()).hexdigest(),
        "source_rate": sr,
        "source_type": "mono->resample 48000 Hz",
        "format": "signed 16-bit PCM, little-endian, mono, 48 kHz, headerless",
        "samples": int(pcm.size),
        "bytes": len(raw),
        "tail_pad_bytes": pad,
        "sectors": sectors,
        "start_lba": args.lba,
        "end_lba_exclusive": end_lba,
        "byte_offset": args.lba * BYTES_PER_SECTOR,
        "peak_norm": args.peak,
        "fade_ms": args.fade_ms,
        "sha256": sha,
    }
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"源文件   : {src}")
    print(f"源采样率 : {sr} Hz  →  {RATE} Hz, 单声道, 16 bit 小端")
    print(f"时长     : {pcm.size / RATE:.2f} s  ({pcm.size} 样本, 尾部补 {pad} 字节)")
    print(f"裸 PCM   : {raw_path}  ({len(raw)/1048576:.2f} MB)")
    print(f"参考回放 : {ref_path}")
    print(f"元数据   : {meta_path}")
    print(f"sha256   : {sha}")
    print()
    print("=" * 72)
    print("扇区布局(粘进 audio_final/integrated/top_final.v)")
    print("=" * 72)
    print(f"  音乐区 : {args.lba} ~ {end_lba - 1}  ({sectors} 扇区, "
          f"字节偏移 {args.lba * BYTES_PER_SECTOR})")
    print()
    print(f"\t// TF 卡音乐素材(裸 PCM 48kHz/16bit/mono), 由 tools/make_audio_corpus.py 生成")
    print(f"\tlocalparam [31:0] WAV_START_LBA = 32'd{args.lba};")
    print(f"\tlocalparam [31:0] WAV_SECTORS   = 32'd{sectors};")
    print()
    write_commands(raw_path, args.lba, sectors)


if __name__ == "__main__":
    main()
