#====================================================================
# ModelSim 仿真脚本：meeting_ctrl(4 态议程状态机 + 20s 倒计时)
#   用法(在 sim 目录): vsim -c -do "do run_sim_meeting_ctrl.do"
#====================================================================
if {[file exists work]} { file delete -force work }
vlib work
vmap work work

vlog ../src/meeting_ctrl.v
vlog ../tb/tb_meeting_ctrl.v

vsim -t 1ps work.tb_meeting_ctrl
run -all

if {[batch_mode]} {
    quit -f
}
