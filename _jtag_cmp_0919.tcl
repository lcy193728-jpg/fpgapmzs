# 对照实验 B —— 历史位流 f861a92 (2026-09-19 23:16)
# 目的: 卡上 BMP 素材若按"旧布局"(Z_MENU=126656 口径)摆放, 则本版应能正常显示图片
#   · Z_MENU/WEL=126656, MEET=130272, QUIZ=133888, ALARM=135696  ← 与当前(15936 口径)完全不同
#   · 该版本是 9/19 四场景音频链路的收官版, 当时上板验证过(有声音)
# 用法: bw_commands_prompt.exe E:/FPGA/ALST/_dev_sim_0b18789/_jtag_cmp_0919.tcl
download -bit "E:/FPGA/ALST/_dev_sim_f861a92/audio_final/artifacts/pic_sdram_audio_final.bit" -mode jtag -spd 7 -sec 64 -cable 0
exit
