#====================================================================
# ModelSim 仿真脚本：audio_viz_overlay 门控专项(会议仅 WARN 显示)
#   需要 EG_LOGIC_BRAM 行为模型(厂商宏在 ModelSim 下为空壳)。
#   用法(在 sim 目录): vsim -c -do "do run_sim_viz_gate.do"
#====================================================================
if {[file exists work]} { file delete -force work }
vlib work
vmap work work

vlog ../audio_final/tb/EG_LOGIC_BRAM_sim.v
vlog ../audio_final/rtl/audio_viz_overlay.v
vlog ../audio_final/tb/tb_audio_viz_gate.v

vsim -t 1ps work.tb_audio_viz_gate
run -all

if {[batch_mode]} {
    quit -f
}
