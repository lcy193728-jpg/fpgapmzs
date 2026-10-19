# 10-13 OSD 展示增强版：独立构建，不覆盖已上板验证的旧 BIT。
set root E:/FPGA/ALST/_dev_sim_0b18789
set out  $root/_build_showcase_1013
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
# route 命令会较早生成一次 route.qor；若主机在布线与 bitgen 之间休眠，
# 旧时间戳会触发防混用门禁。最终时序更新后显式重写，确保面积、时序、
# route QoR 与 BIT 属于同一次完成的构建。
report_qor -step route -file $out/route.qor
report_area -io_info -file $out/final.area
report_timing_summary -file $out/final.timing
bitgen -bit $art/pic_sdram_audio_candidate_seed59.bit

puts "BUILD_CANDIDATE_SEED59_BIT_DONE"
exit
