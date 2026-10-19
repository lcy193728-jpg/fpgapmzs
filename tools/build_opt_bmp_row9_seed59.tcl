# bmp_scale 行坐标/缓存标签位宽收敛候选。
# 独立目录与位流，不覆盖已上板稳定发布版。
set root E:/FPGA/ALST/_dev_sim_0b18789
set out  $root/_build_opt_bmp_row9_seed59
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
bitgen -bit $art/pic_sdram_audio_opt_bmp_row9_seed59.bit

puts "BUILD_OPT_BMP_ROW9_SEED59_DONE"
exit
