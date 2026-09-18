#====================================================================
# ModelSim 仿真脚本：osd_scene 会议/抢答/应急 三场景 OSD 叠加引擎
# 用法：File -> Change Directory 到 sim 目录，再执行 do run_sim_osd_scene.do
#   或命令行: vsim -c -do run_sim_osd_scene.do (自动退出)
#====================================================================

# 0. 清旧库
if {[file exists work]} { file delete -force work }

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件(先 ROM, 后场景 OSD, 再 TB)
vlog ../src/osd_font_rom.v
vlog ../src/osd_scene.v
vlog ../tb/tb_osd_scene.v

# 3. 启动仿真
vsim -t 1ps work.tb_osd_scene

# 4. 添加波形(仅 GUI 下有意义)
if {![batch_mode]} {
    add wave -divider "输入"
    add wave /tb_osd_scene/clk
    add wave /tb_osd_scene/rst
    add wave /tb_osd_scene/hs_i
    add wave /tb_osd_scene/vs_i
    add wave /tb_osd_scene/de_i
    add wave -radix hex /tb_osd_scene/data_i
    add wave -radix unsigned /tb_osd_scene/px_i
    add wave -radix unsigned /tb_osd_scene/py_i
    add wave /tb_osd_scene/meeting_en
    add wave /tb_osd_scene/quiz_en
    add wave /tb_osd_scene/alarm_en
    add wave -radix unsigned /tb_osd_scene/qstate
    add wave -radix unsigned /tb_osd_scene/winner
    add wave -radix unsigned /tb_osd_scene/t_tens
    add wave -radix unsigned /tb_osd_scene/t_ones
    add wave -radix unsigned /tb_osd_scene/run_hh
    add wave -radix unsigned /tb_osd_scene/run_mm
    add wave -radix unsigned /tb_osd_scene/run_ss

    add wave -divider "输出"
    add wave /tb_osd_scene/hs_o
    add wave /tb_osd_scene/vs_o
    add wave /tb_osd_scene/de_o
    add wave -radix hex /tb_osd_scene/data_o
    add wave -radix unsigned /tb_osd_scene/px_x_o
    add wave -radix unsigned /tb_osd_scene/px_y_o

    add wave -divider "内部"
    add wave -radix unsigned /tb_osd_scene/u_scene/px3
    add wave -radix unsigned /tb_osd_scene/u_scene/py3
    add wave /tb_osd_scene/u_scene/mt_ok
    add wave /tb_osd_scene/u_scene/qz_ok
    add wave /tb_osd_scene/u_scene/al_ok
    add wave /tb_osd_scene/u_scene/blink
    add wave -radix unsigned /tb_osd_scene/u_scene/phase
    add wave -radix unsigned /tb_osd_scene/u_scene/page
    add wave -radix unsigned /tb_osd_scene/u_scene/rom_addr
    add wave -radix hex /tb_osd_scene/u_scene/rom_q

    add wave -divider "统计"
    add wave -radix unsigned /tb_osd_scene/act_cnt
    add wave -radix unsigned /tb_osd_scene/c_bg
    add wave -radix unsigned /tb_osd_scene/c_navy
    add wave -radix unsigned /tb_osd_scene/c_gold
    add wave -radix unsigned /tb_osd_scene/c_white
    add wave -radix unsigned /tb_osd_scene/c_steel
    add wave -radix unsigned /tb_osd_scene/c_panel
    add wave -radix unsigned /tb_osd_scene/c_orng
    add wave -radix unsigned /tb_osd_scene/c_dark
    add wave -radix unsigned /tb_osd_scene/c_alred
    add wave -radix unsigned /tb_osd_scene/c_bara
    add wave -radix unsigned /tb_osd_scene/c_barb
    add wave -radix unsigned /tb_osd_scene/valid_cnt
}

# 5. 运行仿真
run -all

# 6. 批处理模式直接退出
if {[batch_mode]} {
    quit -f
}
wave zoomfull
