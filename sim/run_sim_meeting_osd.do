#====================================================================
# ModelSim 仿真脚本：meeting_osd(状态条 + MM:SS 倒计时 + 进度条) 像素验证
#   用法(在 sim 目录): vsim -c -do "do run_sim_meeting_osd.do"
#   纯 VHDL/Verilog, 无 BRAM → iverilog 也能跑, 此处用 ModelSim 统一回归。
#====================================================================
if {[file exists work]} { file delete -force work }
vlib work
vmap work work

vlog ../src/meeting_osd.v
vlog ../tb/tb_meeting_osd.v

vsim -t 1ps work.tb_meeting_osd
run -all

if {[batch_mode]} {
    quit -f
}
