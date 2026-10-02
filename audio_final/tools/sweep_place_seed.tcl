#=====================================================================
# sweep_place_seed.tcl —— 复用已综合的 gate 数据库, 单种子 place+route 并报告时序
#
# 用途: sd_card_clk(100MHz) 域在 85% LUT / 98% BRAM9K 的高占用下对布局极敏感。
#   加 WAV 播放器(多 4 块 BRAM)后, 默认种子的 bmp_scale
#   buf_row -> out_col.ce 路径 WNS 由 +0.374ns 退化为 -0.203ns。
#   本脚本扫描 place 种子, 找出时序达标的布局, 再把该种子固定进 build_td.tcl
#   使整包编译可复现(不改任何 RTL)。
#
# 用法: 设置环境变量 TD_PLACE_SEED=<n> 后
#         td_commands_prompt.exe sweep_place_seed.tcl
#   产物: build/pic_sdram_audio_final_seed<n>.timing / .area
#=====================================================================
set board_dir [file normalize [file join [file dirname [info script]] ..]]
set prj       [file join $board_dir .. pic_sdram_audio_final.al]
set name      pic_sdram_audio_final
set out       [file join $board_dir build]
set seed      1
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
report_area -io_info -file ${name}_seed${seed}.area
report_timing_summary -file ${name}_seed${seed}.timing
puts "SEED_DONE $seed"
# 必须显式 exit: td_commands_prompt.exe 在脚本自然结束后不会退出进程,
#   会让上层 foreach 循环卡死在第一个种子上(官方 MultiSeed.tcl 同理以 exit 收尾)。
exit
