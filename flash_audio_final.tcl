# 烧录脚本: 固化到板载 SPI Flash(上电自启) —— 赛题红线要求
# 位流: audio_final/artifacts/pic_sdram_audio_final.bit
# SHA-256: 552f3051cf9179ad824f509c1c1c1397310ed05914c07885cdb9ffecd27f30f1
# 时序: SWNS +0.131ns / HWNS +0.020ns (0 违例, place seed=7)
# 面积: LUT 17463-19600 (89.10%) / bram9k 63-64 / bram32k 3-16 / dsp 14-29
# [2026-10-03 01:10 本版] 修数码管"模式号"位误显复用槽标记码 6 的 bug:
#   迎新模式4 应显示 4、应急模式2 应显示 2, 原接 hud_mode(对比度复用槽=6)。
#   改为顶层 wire disp_digit = ui_mode_raw(ui_key_ctrl 内部真实 mode 0..5);
#   仅换一个 wire 源、零新增寄存器(中途加 disp_num 寄存器导致 slices 97% +
#   seed 退化 -5.244ns, 已回退)。仿真全量 17 套 0 FAIL。
#   注意: 本版 RTL 微变 → netlist 变 → place seed 由 29 重扫为 7。
# [2026-10-02 三次改动] 修 1280×960 迎新图偏色: bmp_read_auto 的 2× 源水平均值
#   原按 8bit 求和丢进位(200+200 得 72、255+255 得 127), 改为 9bit 求和取 [8:1];
#   同时把 len_ok 长度校验拆成 rd_cnt 26/27/28 三级打拍, 消除 9.772ns/9 级长组合
#   路径(SWNS 由 -0.052ns 违例转 +0.148ns 达标)。仿真: tb_bmp_2x_decim 7/7 PASS
# [2026-10-02 换卡] 素材卡由老卡 F: 改为新卡 G:(FAT32, 分区偏移 64 扇区=物理口径),
#   Z_* 场景分区表按 G: 实测重排: 菜单/迎新=第5~8张(含 2×1280×960)、
#   会议=第1张、抢答=第2张、应急复用抢答区; 音乐+MTG1 已裸写入 G:(300000/200000)。
#   因 Z_* 常量变化导致原 seed=19 布局退化(SWNS -2.074ns), 重扫种子 20..35 取最优 35。
# 变更1: Z_* 场景分区表改为【物理扇区】口径(各 +2048)。
# 变更2(关键修复): 补回 sd_sec_read / sd_sec_read_addr 的显式 wire 声明 ——
#   仲裁器改造时漏了声明, TD 按 1 bit 处理(HDL-5007), 32 位扇区地址被截断成
#   bit0, CMD17 恒读扇区 0/1 → BMP 扫不到图(花屏) + WAV 读到 MBR(无声)。
#   本版编译日志已确认 'sd_sec_read_addr' 相关告警全部消失。
# 变更3(2026-09-27, 关键修复): 迎新场景"完全无声"的根因 —— 顶层那个静音
#   "test 源"原为 audio_pcm_tone(.enable(1'b0)), 其 sample_valid=(count!=0)
#   在 48 kHz 节拍那一拍恰为 0(晚一拍才置 1); 而 audio_src_mux 的
#   launch(→ media_ready → wav_ready) 要求 test_valid 与 media_valid **同拍**
#   为真, 于是节拍上 wav_ready 恒 0 → wav_stream_player 永不推进(rd_ptr 恒停
#   在预读值) → 没有任何 PCM 输出。改为"恒有效、恒零"的静音源后, 端到端
#   仿真 tick&&wav_ready 由 0 变为 576、audio_left 非零; 上板迎新已出声。
#   顺带删掉这个 audio_pcm_tone(256 点正弦 ROM + 乘法器), 面积更小。
# 注: 定位期用过的临时插桩(数码管调试字节/听诊音/dbg_* 端口)已全部回滚;
#   place seed 亦由临时的 3 恢复到 4(见 tools/build_td.tcl 注释)。
# 用法: bw_commands_prompt.exe E:/FPGA/ALST/_dev_sim_0b18789/flash_audio_final.tcl
download -bit "E:/FPGA/ALST/_dev_sim_0b18789/audio_final/artifacts/pic_sdram_audio_final.bit" -mode program_spi -v -spd 7 -cable 0 -flashsize 128
exit
