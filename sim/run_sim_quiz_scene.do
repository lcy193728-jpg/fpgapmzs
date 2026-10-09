#====================================================================
# ModelSim 仿真脚本：quiz_scene_ctrl 抢答「题目/队伍/结束」跳图桥接控制
# 用法：File -> Change Directory 到 sim 目录，再执行 do run_sim_quiz_scene.do
#   或命令行: vsim -c -do run_sim_quiz_scene.do (自动退出)
# 注：本模块为纯独立模块, 无子模块依赖, 直接编译即可。
#====================================================================

# 0. 清旧库
if {[file exists work]} { file delete -force work }

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件
vlog ../src/quiz_scene_ctrl.v
vlog ./tb/tb_quiz_scene_ctrl.v

# 3. 启动仿真
vsim -t 1ps work.tb_quiz_scene_ctrl

# 4. 添加波形(仅 GUI 下有意义)
if {![batch_mode]} {
    add wave -divider "输入"
    add wave /tb_quiz_scene_ctrl/clk
    add wave /tb_quiz_scene_ctrl/rst
    add wave /tb_quiz_scene_ctrl/en
    add wave -radix unsigned /tb_quiz_scene_ctrl/qstate
    add wave -radix unsigned /tb_quiz_scene_ctrl/winner
    add wave -radix unsigned /tb_quiz_scene_ctrl/q_idx
    add wave /tb_quiz_scene_ctrl/q_end

    add wave -divider "输出"
    add wave /tb_quiz_scene_ctrl/jump_req
    add wave -radix unsigned /tb_quiz_scene_ctrl/jump_idx
    add wave /tb_quiz_scene_ctrl/iris_trig
    add wave /tb_quiz_scene_ctrl/locked

    add wave -divider "内部"
    add wave -radix unsigned /tb_quiz_scene_ctrl/dut/tgt_idx
    add wave /tb_quiz_scene_ctrl/dut/idx_chg
    add wave /tb_quiz_scene_ctrl/dut/en_rise
}

# 5. 运行仿真
run -all

# 6. 批处理模式直接退出
if {[batch_mode]} {
    quit -f
}
wave zoomfull
