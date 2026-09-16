# TD BitWizard 命令行下载脚本
# 将 pic_sdram.bit 固化到板载配置 SPI Flash（赛题要求：上电即运行，无需 PC 下载）
# 约 77s，含 program_spi + verify_spi
download -bit "E:/FPGA/ALST/fpgapmzs/pic_sdram_Runs/phy_1/pic_sdram.bit" -mode program_spi -v -spd 7 -cable 0 -flashsize 128
