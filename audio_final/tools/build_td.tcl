# Final audio integration build; no simulation/download.
set board_dir [file normalize [file join [file dirname [info script]] ..]]
set prj [file join $board_dir .. pic_sdram_audio_final.al]
set adc [file join $board_dir .. top.adc]
set sdc [file join $board_dir .. audio_board integrated audio.sdc]
set name pic_sdram_audio_final
set out [file join $board_dir build]
file mkdir $out
cd [file dirname $prj]
import_device eagle_s20.db -package EG4S20BG256
open_project $prj -single_run
load_run_param -run syn_1
cd $out
elaborate -top top
read_adc $adc
read_sdc $sdc
optimize_rtl
report_area -file ${name}_rtl.area
optimize_gate ${name}_gate.area
legalize_phy_inst
update_timing
report_timing_summary -file ${name}_gate.timing
export_db ${name}_gate.db
load_run_param -run phy_1
place
route
update_timing -mode final
report_area -io_info -file ${name}_phy.area
report_timing_summary -file ${name}_pr.timing
report_timing_exception -file ${name}_exception.timing
bitgen -bit ${name}.bit
puts "FINAL_AUDIO_BUILD_COMPLETE: [file join $out ${name}.bit]"
