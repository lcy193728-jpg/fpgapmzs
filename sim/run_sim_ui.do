#====================================================================
# ModelSim 仿真脚本：ui_key_ctrl 蓝桥风格人机交互(模式/参数/场景循环)
# 用法：在 ModelSim 命令行(Transcript)执行  do {本文件路径}
#====================================================================

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件
vlog ../src/ui_key_ctrl.v
vlog ../tb/tb_ui_key_ctrl.v

# 3. 启动仿真
vsim -t 1ps work.tb_ui_key_ctrl

# 4. 添加波形
add wave -divider "输入(按键/上下文)"
add wave /tb_ui_key_ctrl/clk
add wave /tb_ui_key_ctrl/rst
add wave /tb_ui_key_ctrl/key1
add wave /tb_ui_key_ctrl/key2
add wave /tb_ui_key_ctrl/key3
add wave -radix unsigned /tb_ui_key_ctrl/img_no
add wave /tb_ui_key_ctrl/scene_chg

add wave -divider "输出(模式/参数)"
add wave -radix unsigned /tb_ui_key_ctrl/mode
add wave -radix unsigned /tb_ui_key_ctrl/bri_level
add wave -radix unsigned /tb_ui_key_ctrl/res_level
add wave /tb_ui_key_ctrl/pic_manual
add wave -radix unsigned /tb_ui_key_ctrl/pic_param
add wave /tb_ui_key_ctrl/key_next_pl
add wave /tb_ui_key_ctrl/key_prev_pl
add wave /tb_ui_key_ctrl/res_chg_pl

add wave -divider "内部(消抖脉冲)"
add wave /tb_ui_key_ctrl/dut/k1_p
add wave /tb_ui_key_ctrl/dut/k2_p
add wave /tb_ui_key_ctrl/dut/k3_p
add wave -radix unsigned /tb_ui_key_ctrl/dut/img_no_l

# 5. 运行仿真
run -all
wave zoomfull
