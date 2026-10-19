# Fast candidate screen: stop after gate optimization and emit comparable QoR.
# This deliberately avoids placement/routing/bitgen; only candidates that do not
# regress the baseline gate area advance to the expensive physical build.
set root E:/FPGA/ALST/_dev_sim_0b18789
set out  $root/_gate_screen
file mkdir $out

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
report_qor -step gate -file $out/gate.qor
report_area -io_info -file $out/gate.area

puts "GATE_SCREEN_DONE"
exit
