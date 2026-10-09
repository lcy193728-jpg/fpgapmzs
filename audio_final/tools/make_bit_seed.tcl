# 复用当前 gate.db + seed 17 + place/route/fix_hold/bitgen 生成最终位流
# 目的: 避免 build_td.tcl 重新 optimize_gate 导致 netlist 变化(seed 对 netlist 混沌敏感)
set board_dir [file normalize [file join [file dirname [info script]] ..]]
set prj [file join $board_dir .. pic_sdram_audio_final.al]
set name pic_sdram_audio_final
set out [file join $board_dir build]
set seed 17
if { [info exists ::env(TD_PLACE_SEED)] } { set seed $::env(TD_PLACE_SEED) }

cd [file dirname $prj]
import_device eagle_s20.db -package EG4S20BG256
open_project $prj -single_run
load_run_param -run syn_1
load_run_param -run phy_1
cd $out
import_db ${name}_gate.db
set_param place seed $seed
place
route
fix_hold
update_timing -mode final
report_area -io_info -file ${name}_final_seed${seed}.area
report_timing_summary -file ${name}_final_seed${seed}.timing
bitgen -bit ${name}_final_seed${seed}.bit
puts "FINAL_BITGEN_DONE $seed"
exit
