# 临时烧录脚本: 队友 dev_sim@75a33cb《场景四: 四类应急告警显示》
# 位流: audio_final/artifacts/pic_sdram_audio_final.bit
# SHA-256: 9fb42a4dd23762f0368c2f4a9c210fe0ba5112d1249228314a8f9c9e69dc0649
# 用法: bw_commands_prompt.exe E:/FPGA/ALST/_dev_sim_0b18789/flash_audio_final.tcl
download -bit "E:/FPGA/ALST/_dev_sim_0b18789/audio_final/artifacts/pic_sdram_audio_final.bit" -mode program_spi -v -spd 7 -cable 0 -flashsize 128
