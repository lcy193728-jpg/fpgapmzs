# 临时烧录脚本: 队友 dev_sim@0b18789《改用官方 HDMI 1.4b 发送器 IP》
# 位流: audio_final/artifacts/pic_sdram_audio_final.bit
# SHA-256: 3cb0c5463ad3796780eafa9a2d925c5eff6b9c8d8da1212f2fb5fe2674fd2c56
# 用法: bw_commands_prompt.exe E:/FPGA/ALST/_dev_sim_0b18789/flash_audio_final.tcl
download -bit "E:/FPGA/ALST/_dev_sim_0b18789/audio_final/artifacts/pic_sdram_audio_final.bit" -mode program_spi -v -spd 7 -cable 0 -flashsize 128
