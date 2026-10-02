import sys, os
try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

# (标签, 设备, 卷内→物理偏移)  物理 = 卷内 + OFF
TARGETS = [
    ('G:(新卡)', r'\\.\G:', 64),
    ('F:(老卡)', r'\\.\F:', 2048),
]

def show(dev, off, phys):
    try:
        d = open(dev, 'rb', buffering=0)
    except Exception as e:
        print('  打开 %s 失败: %s' % (dev, e))
        return
    for name, plba in [('会议配置', 200000), ('音乐头', 300000), ('音乐中', 320000)]:
        vol = plba - off
        try:
            d.seek(vol * 512)
            buf = d.read(512)
        except Exception as e:
            print('  %-8s phys%-7d 读失败: %s' % (name, plba, e))
            continue
        print('  %-8s phys%-7d(卷内%-7d) %s ascii=%r'
              % (name, plba, vol, buf[:16].hex(' '), buf[:16]))
    d.close()

for tag, dev, off in TARGETS:
    print('==== %s (卷内 = 物理 - %d) ====' % (tag, off))
    show(dev, off, None)

print('\n==== 素材文件大小 ====')
for f in [r'e:\FPGA\ALST\_dev_sim_0b18789\audio_final\assets\wel_music_48k_mono.raw',
          r'e:\FPGA\ALST\_dev_sim_0b18789\audio_final\assets\mtg1_cfg_3sec.bin']:
    if os.path.exists(f):
        n = os.path.getsize(f)
        print('  %-30s %d 字节 = %.2f 扇区' % (os.path.basename(f), n, n / 512.0))
    else:
        print('  %s 不存在' % f)
