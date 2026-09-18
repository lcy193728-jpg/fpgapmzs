#====================================================================
# ModelSim 仿真脚本：quiz_ctrl 抢答场景控制(消抖/并行仲裁/倒计时)
# 用法：File -> Change Directory 到 sim 目录，再执行 do run_sim_quiz.do
#   或命令行: vsim -c -do run_sim_quiz.do (自动退出)
# 注：key_debounce 子模块定义在 scene_control.v 末尾, 故须一并编译
#====================================================================

# 0. 清旧库
if {[file exists work]} { file delete -force work }

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件(先 key_debounce 所在文件, 后被测模块, 再 TB)
vlog ../src/scene_control.v
vlog ../src/quiz_ctrl.v
vlog ../tb/tb_quiz_ctrl.v

# 3. 启动仿真
vsim -t 1ps work.tb_quiz_ctrl

# 4. 添加波形(仅 GUI 下有意义)
if {![batch_mode]} {
    add wave -divider "输入"
    add wave /tb_quiz_ctrl/clk
    add wave /tb_quiz_ctrl/rst
    add wave /tb_quiz_ctrl/en
    add wave -radix binary /tb_quiz_ctrl/player_raw
    add wave /tb_quiz_ctrl/start_raw
    add wave /tb_quiz_ctrl/clear_raw

    add wave -divider "输出"
    add wave -radix unsigned /tb_quiz_ctrl/qstate
    add wave -radix unsigned /tb_quiz_ctrl/winner
    add wave -radix unsigned /tb_quiz_ctrl/t_tens
    add wave -radix unsigned /tb_quiz_ctrl/t_ones

    add wave -divider "内部"
    add wave -radix binary /tb_quiz_ctrl/dut/pl6
    add wave -radix binary /tb_quiz_ctrl/dut/hit
    add wave -radix unsigned /tb_quiz_ctrl/dut/hit_sel
    add wave /tb_quiz_ctrl/dut/hit_any
    add wave /tb_quiz_ctrl/dut/tick
}

# 5. 运行仿真
run -all

# 6. 批处理模式直接退出
if {[batch_mode]} {
    quit -f
}
wave zoomfull
