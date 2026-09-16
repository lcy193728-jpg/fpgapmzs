#====================================================================
# ModelSim 仿真脚本：osd_welcome 迎新展示场景 OSD 叠加引擎
# 用法：File -> Change Directory 到 sim 目录，再执行 do run_sim_welcome.do
#   或命令行: vsim -c -do run_sim_welcome.do (自动退出)
#====================================================================

# 0. 清旧库
if {[file exists work]} { file delete -force work }

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件(先 ROM, 后 OSD, 再 TB)
vlog ../src/osd_font_rom.v
vlog ../src/osd_welcome.v
vlog ../tb/tb_osd_welcome.v

# 3. 启动仿真
vsim -t 1ps work.tb_osd_welcome

# 4. 添加波形(仅 GUI 下有意义)
if {![batch_mode]} {
    add wave -divider "输入"
    add wave /tb_osd_welcome/clk
    add wave /tb_osd_welcome/rst
    add wave /tb_osd_welcome/hs_i
    add wave /tb_osd_welcome/vs_i
    add wave /tb_osd_welcome/de_i
    add wave -radix hex /tb_osd_welcome/data_i
    add wave -radix unsigned /tb_osd_welcome/px_i
    add wave -radix unsigned /tb_osd_welcome/py_i
    add wave /tb_osd_welcome/welcome_en

    add wave -divider "输出"
    add wave /tb_osd_welcome/hs_o
    add wave /tb_osd_welcome/vs_o
    add wave /tb_osd_welcome/de_o
    add wave -radix hex /tb_osd_welcome/data_o
    add wave -radix unsigned /tb_osd_welcome/px_x_o
    add wave -radix unsigned /tb_osd_welcome/px_y_o

    add wave -divider "内部"
    add wave -radix unsigned /tb_osd_welcome/u_welcome/px3
    add wave -radix unsigned /tb_osd_welcome/u_welcome/py3
    add wave /tb_osd_welcome/u_welcome/w_ok
    add wave -radix unsigned /tb_osd_welcome/u_welcome/phase
    add wave -radix unsigned /tb_osd_welcome/u_welcome/rom_addr
    add wave -radix hex /tb_osd_welcome/u_welcome/rom_q

    add wave -divider "统计"
    add wave -radix unsigned /tb_osd_welcome/act_cnt
    add wave -radix unsigned /tb_osd_welcome/c_bg
    add wave -radix unsigned /tb_osd_welcome/c_gold
    add wave -radix unsigned /tb_osd_welcome/c_title
    add wave -radix unsigned /tb_osd_welcome/c_card
    add wave -radix unsigned /tb_osd_welcome/c_wtxt
    add wave -radix unsigned /tb_osd_welcome/c_orng
    add wave -radix unsigned /tb_osd_welcome/c_dark
    add wave -radix unsigned /tb_osd_welcome/valid_cnt
}

# 5. 运行仿真
run -all

# 6. 批处理模式直接退出
if {[batch_mode]} {
    quit -f
}
wave zoomfull
