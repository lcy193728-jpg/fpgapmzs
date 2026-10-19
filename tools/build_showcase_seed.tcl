# Reproducible full build with an externally selected placement seed.
# PowerShell: $env:TD_SEED='23'; td_commands_prompt.exe tools/build_showcase_seed.tcl
set root E:/FPGA/ALST/_dev_sim_0b18789
set seed $::env(TD_SEED)
set out  $root/_build_showcase_seed$seed
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
set_param place seed $seed
place
route
fix_hold
update_timing -mode final
report_qor -step route -file $out/route.qor
report_area -io_info -file $out/final.area
report_timing_summary -file $out/final.timing
bitgen -bit $art/pic_sdram_audio_font_aa_seed$seed.bit

puts "BUILD_FONT_AA_SEED${seed}_DONE"
exit
