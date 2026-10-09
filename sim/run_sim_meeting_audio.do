#====================================================================
# ModelSim 仿真脚本：会议场景音频行为(进入静音 / WARN 提示音 / 播完复位)
#
# ⚠ 编译目录必须在 audio_final/tb：
#   scene_audio_final.v 里写的是 `include "../rtl/audio_sine_init.vh",
#   ModelSim 按 **当前工作目录** 解析该相对路径 → cwd 必须是 audio_final/tb
#   (../rtl 才等于 audio_final/rtl)。故本脚本先 cd, 库仍建在 sim/work。
#
#   用法(在 sim 目录): vsim -c -do "do run_sim_meeting_audio.do"
#====================================================================
if {[file exists work]} { file delete -force work }
set absWork [file normalize work]

cd ../audio_final/tb
vlib $absWork
vmap work $absWork

vlog -work work ../rtl/scene_audio_final.v tb_scene_audio_meeting.v

vsim -t 1ps work.tb_scene_audio_meeting
run -all

cd ../../sim

if {[batch_mode]} {
    quit -f
}
