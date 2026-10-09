#====================================================================
# ModelSim 仿真脚本：抢答分数显示(弹窗式 + 结束页散点)像素级回归
#   对应 display_adjust.v 的 BUG-1(行尾拖字) / BUG-2(结束页不显分) 修复
# 用法：cd sim && vsim -c -do "do run_sim_score.do; quit -f"
#====================================================================

onerror {quit -f}

if {[file exists work]} { file delete -force work }
vlib work
vmap work work

vlog ../src/display_adjust.v
vlog ../tb/tb_display_score.v

vsim -c work.tb_display_score
run -all
quit -f
