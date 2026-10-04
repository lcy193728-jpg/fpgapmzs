# 快速探针: 只跑到综合(gate)阶段, 用于验证 BRAM 推断结果(ram_style 指令是否生效)。
#   产出 build_probe/pic_sdram_audio_final_rtl.area 与 build_probe/gate.qor
#   判读: rtl.area 的 macros 列 = 该实例被推断成 RAM 宏的个数;
#         gate.qor 的 #RAMs = 全设计 RAM 宏总数(与 phy 报告同源)。
#   用法: cd <build_probe> && E:/FPGA/TD/bin/td_commands_prompt.exe <本文件绝对路径>
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
# --- 追加: 只做 place, 用 report_area 看 BRAM 分池(9K vs 32K)是否变化 ---
load_run_param -run phy_1
place
report_area -io_info -file ${name}_place.area
puts "PROBE_PLACE_DONE: [file join $out ${name}_place.area]"
exit
