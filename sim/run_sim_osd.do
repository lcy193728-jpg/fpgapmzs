#====================================================================
# ModelSim 仿真脚本：osd_engine OSD 叠加底座
# 用法：在 ModelSim 命令行(Transcript)执行  do {本文件路径}
#   或先 File -> Change Directory 到 sim 目录，再执行  do run_sim_osd.do
# 说明: 先清库避免跨版本格式不一致, 可 GUI / 批处理通用
#====================================================================

# 0. 清旧库(不同 ModelSim 生成的库格式可能不兼容)
if {[file exists work]} { file delete -force work }

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件
vlog ../src/osd_engine.v
vlog ../tb/tb_osd_engine.v

# 3. 启动仿真
vsim -t 1ps work.tb_osd_engine

# 4. 添加波形(仅 GUI 下有意义)
if {![batch_mode]} {
    add wave -divider "输入"
    add wave /tb_osd_engine/clk
    add wave /tb_osd_engine/rst
    add wave /tb_osd_engine/hs_i
    add wave /tb_osd_engine/vs_i
    add wave /tb_osd_engine/de_i
    add wave -radix hex /tb_osd_engine/data_i

    add wave -divider "输出"
    add wave /tb_osd_engine/hs_o
    add wave /tb_osd_engine/vs_o
    add wave /tb_osd_engine/de_o
    add wave -radix hex /tb_osd_engine/data_o
    add wave -radix unsigned /tb_osd_engine/px_x
    add wave -radix unsigned /tb_osd_engine/px_y

    add wave -divider "引擎内部"
    add wave -radix unsigned /tb_osd_engine/uut/cnt_x
    add wave -radix unsigned /tb_osd_engine/uut/cnt_y
    add wave /tb_osd_engine/uut/de_a
    add wave -radix unsigned /tb_osd_engine/uut/x_a
    add wave -radix unsigned /tb_osd_engine/uut/y_a
    add wave /tb_osd_engine/uut/de_o_r
    add wave -radix hex /tb_osd_engine/uut/data_o_r
}

# 5. 运行仿真
run -all

# 6. 批处理模式直接退出(供命令行自动化用)
if {[batch_mode]} {
    quit -f
}
wave zoomfull
