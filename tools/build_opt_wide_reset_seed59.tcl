# 10-17 等价资源/低功耗候选：UART/迎新 CDC 宽数据去复位，首帧原子装载。
# 独立构建，不覆盖已上板验证基线。
set root E:/FPGA/ALST/_dev_sim_0b18789
set out  $root/_build_opt_wide_reset_seed59
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
optimize_gate $out/opt_gate.area
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
bitgen -bit $art/pic_sdram_audio_opt_wide_reset_seed59.bit

puts "BUILD_OPT_WIDE_RESET_SEED59_DONE"
exit
