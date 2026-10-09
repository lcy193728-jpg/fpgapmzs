#====================================================================
# ModelSim 仿真脚本：★对比度功能回归(2026-10-09c 新增)
#   对应 display_adjust.v 的 stage2b「对比度」运算 + 对比度 HUD 条
# 用法：cd sim && vsim -c -do "do run_sim_contrast.do; quit -f"
#====================================================================

onerror {quit -f}

if {[file exists work]} { file delete -force work }
vlib work
vmap work work

vlog ../src/display_adjust.v
vlog ../tb/tb_display_contrast.v

vsim -c work.tb_display_contrast
run -all
quit -f
