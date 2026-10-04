# 快速探针: 只跑到综合(gate)阶段, 验证 ram_style="bram_32k" 是否生效。
#   判读: 1) 不报 "emb number ... exceeds" 错 = 没爆 9K 池
#         2) rtl.area 里 font(meeting_glyph_rom) 的 macros 列 = 1(进了 BRAM)
#         3) gate 阶段报告里 #RAMs / EMB 计数
set board_dir [file normalize [file join [file dirname [info script]] ..]]
set prj  [file join $board_dir .. pic_sdram_audio_final.al]
set adc  [file join $board_dir .. top.adc]
set sdc  [file join $board_dir .. audio_board integrated audio.sdc]
set name pic_sdram_audio_final
set out  [file join $board_dir build_probe]
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
puts "PROBE_GATE_DONE"
exit
