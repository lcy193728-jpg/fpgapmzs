# 10-17 架构/低功耗候选：UART与音频计数器按参数最小位宽实现。
# 独立构建，不覆盖已上板验证基线。
set root E:/FPGA/ALST/_dev_sim_0b18789
set out  $root/_build_arch_counter_width_seed59
set art  $root/artifacts
file mkdir $out
file mkdir $art

cd $root
import_device eagle_s20.db -package EG4S20BG256
open_project $root/pic_sdram_audio_final.al -single_run
load_run_param -run syn_1

cd $out
elaborate -top top
read_adc $root/top.adc
read_sdc $root/audio_board/integrated/audio.sdc
optimize_rtl
optimize_gate
report_qor -step gate -file $out/gate.qor
legalize_phy_inst
update_timing

load_run_param -run phy_1
set_param place seed 59
place
route
fix_hold
update_timing -mode final
report_qor -step route -file $out/route.qor
report_area -io_info -file $out/final.area
report_timing_summary -file $out/final.timing
bitgen -bit $art/pic_sdram_audio_arch_counter_width_seed59.bit

puts "BUILD_ARCH_COUNTER_WIDTH_SEED59_DONE"
exit
