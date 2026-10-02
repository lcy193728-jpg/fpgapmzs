# JTAG/SRAM 临时下载（掉电即失，不写板载配置 Flash）
# 目标: audio_final 位流 —— 含 1280×960 偏色修复 + len_ok 长路径拆流水
# SHA-256: 5caa4c1e1030b57df66325fdba9c09bf9dcab7adf173354c4ed626530eac993f
# 构建: 2026-10-02 16:01 / SWNS +0.148ns, HWNS +0.020ns (0 违例, seed=31)
# 仿真: tb_bmp_2x_decim 7/7 PASS + tb_bmp_read_auto 27 PASS / 0 FAIL
# 用法: bw_commands_prompt.exe E:/FPGA/ALST/_dev_sim_0b18789/_jtag_audio_final.tcl
download -bit "E:/FPGA/ALST/_dev_sim_0b18789/audio_final/artifacts/pic_sdram_audio_final.bit" -mode jtag -spd 7 -sec 64 -cable 0
exit
