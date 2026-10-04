# JTAG/SRAM 临时下载（掉电即失，不写板载配置 Flash）
# 目标: audio_final 位流 —— 对比度调节(迎新模式4 / 应急模式2 复用槽) + 对比度 HUD 条
#       + 数码管"模式号"位改显真实槽号 4/2 (修掉误显复用槽标记码 6 的 bug)
# SHA-256: 552f3051cf9179ad824f509c1c1c1397310ed05914c07885cdb9ffecd27f30f1
# 构建: 2026-10-03 01:10 / SWNS +0.131ns, HWNS +0.020ns (0 违例, place seed=7)
# 面积: LUT 17463-19600 (89.10%) / BRAM9K 63-64 (98.44%) / DSP 14-29 / IO 53-188
# 仿真: 全量 17 套回归 0 FAIL / 0 ERROR (run_sim_ui 123 PASS, run_sim_display 73 PASS)
# 用法: bw_commands_prompt.exe E:/FPGA/ALST/_dev_sim_0b18789/_jtag_audio_final.tcl
download -bit "E:/FPGA/ALST/_dev_sim_0b18789/audio_final/artifacts/pic_sdram_audio_final.bit" -mode jtag -spd 7 -sec 64 -cable 0
exit
