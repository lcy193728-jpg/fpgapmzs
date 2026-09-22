#====================================================================
# ModelSim 仿真脚本：audio_viz_overlay 时间序列"音量柱"叠加层
# 用法：在 ModelSim 命令行(Transcript)执行  do {本文件路径}
#   或批处理: vsim -c -do "do run_sim_viz.do"
# 说明:
#   1) 先编译 EG_LOGIC_BRAM_sim.v —— 厂商 eagle_macro.v 里 EG_LOGIC_BRAM
#      只是空壳声明, ModelSim 下 dob 会悬空; 用本地行为模型替代。
#      该文件不进 TD 工程(build_td.tcl 显式列 RTL 文件)。
#   2) 先清库避免跨版本格式不一致, 可 GUI / 批处理通用
#====================================================================

# 0. 清旧库(不同 ModelSim 生成的库格式可能不兼容)
if {[file exists work]} { file delete -force work }

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件(先 BRAM 行为模型, 再 DUT, 最后 TB)
vlog ../audio_final/tb/EG_LOGIC_BRAM_sim.v
vlog ../audio_final/rtl/audio_viz_overlay.v
vlog ../audio_final/tb/tb_audio_viz_overlay.v

# 3. 启动仿真
vsim -t 1ps work.tb_audio_viz_overlay

# 4. 添加波形(仅 GUI 下有意义)
if {![batch_mode]} {
    add wave -divider "输入"
    add wave /tb_audio_viz_overlay/clk
    add wave /tb_audio_viz_overlay/rst
    add wave /tb_audio_viz_overlay/de_i
    add wave -radix unsigned /tb_audio_viz_overlay/px_x
    add wave -radix unsigned /tb_audio_viz_overlay/px_y
    add wave /tb_audio_viz_overlay/menu_active
    add wave -radix unsigned /tb_audio_viz_overlay/scene_id
    add wave /tb_audio_viz_overlay/pcm_take
    add wave -radix decimal /tb_audio_viz_overlay/pcm

    add wave -divider "输出"
    add wave /tb_audio_viz_overlay/de_o
    add wave -radix hex /tb_audio_viz_overlay/data_o
    add wave -radix unsigned /tb_audio_viz_overlay/px_x_o
    add wave -radix unsigned /tb_audio_viz_overlay/px_y_o

    add wave -divider "内部(柱阵)"
    add wave -radix unsigned /tb_audio_viz_overlay/dut/wp
    add wave -radix unsigned /tb_audio_viz_overlay/dut/col
    add wave -radix unsigned /tb_audio_viz_overlay/dut/ridx
    add wave -radix unsigned /tb_audio_viz_overlay/dut/grp_max
    add wave -radix unsigned /tb_audio_viz_overlay/dut/wave_q
    add wave -radix unsigned /tb_audio_viz_overlay/dut/hgt
    add wave -radix unsigned /tb_audio_viz_overlay/dut/dh
    add wave -radix hex /tb_audio_viz_overlay/dut/accent
}

# 5. 运行仿真
run -all

# 6. 批处理模式直接退出(供命令行自动化用)
if {[batch_mode]} {
    quit -f
}
wave zoomfull
