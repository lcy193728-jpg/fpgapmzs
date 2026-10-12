# 10-13 资源优化版：隔离构建并生成可烧录 BIT，不覆盖 10-12 既有产物。
set root E:/FPGA/ALST/_dev_sim_0b18789
set out  $root/_build_opt_1013
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
report_area -io_info -file $out/final.area
report_timing_summary -file $out/final.timing
bitgen -bit $art/pic_sdram_audio_opt_1013.bit

puts "BUILD_OPT_1013_BIT_DONE"
exit
