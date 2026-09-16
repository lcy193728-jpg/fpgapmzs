#====================================================================
# ModelSim 仿真脚本：osd_menu OSD 菜单/应急红条叠加引擎
# 用法：在 ModelSim 命令行(Transcript)执行  do {本文件路径}
#   或先 File -> Change Directory 到 sim 目录，再执行  do run_sim_menu.do
# 说明: 先清库避免跨版本格式不一致, 可 GUI / 批处理通用
#====================================================================

# 0. 清旧库(不同 ModelSim 生成的库格式可能不兼容)
if {[file exists work]} { file delete -force work }

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件(先 ROM, 后菜单引擎, 再 TB)
vlog ../src/osd_font_rom.v
vlog ../src/osd_menu.v
vlog ../tb/tb_osd_menu.v

# 3. 启动仿真
vsim -t 1ps work.tb_osd_menu

# 4. 添加波形(仅 GUI 下有意义)
if {![batch_mode]} {
    add wave -divider "输入"
    add wave /tb_osd_menu/clk
    add wave /tb_osd_menu/rst
    add wave /tb_osd_menu/hs_i
    add wave /tb_osd_menu/vs_i
    add wave /tb_osd_menu/de_i
    add wave -radix hex /tb_osd_menu/data_i
    add wave -radix unsigned /tb_osd_menu/px_i
    add wave -radix unsigned /tb_osd_menu/py_i
    add wave /tb_osd_menu/menu_en
    add wave /tb_osd_menu/emerg_en

    add wave -divider "输出"
    add wave /tb_osd_menu/hs_o
    add wave /tb_osd_menu/vs_o
    add wave /tb_osd_menu/de_o
    add wave -radix hex /tb_osd_menu/data_o

    add wave -divider "内部(菜单引擎)"
    add wave -radix unsigned /tb_osd_menu/u_menu/px3
    add wave -radix unsigned /tb_osd_menu/u_menu/py3
    add wave /tb_osd_menu/u_menu/menu_ok
    add wave /tb_osd_menu/u_menu/emerg_ok
    add wave -radix unsigned /tb_osd_menu/u_menu/phase
    add wave -radix unsigned /tb_osd_menu/u_menu/rom_addr
    add wave -radix hex /tb_osd_menu/u_menu/rom_q

    add wave -divider "统计"
    add wave -radix unsigned /tb_osd_menu/act_cnt
    add wave -radix unsigned /tb_osd_menu/c_bgfull
    add wave -radix unsigned /tb_osd_menu/c_card
    add wave -radix unsigned /tb_osd_menu/c_bd
    add wave -radix unsigned /tb_osd_menu/c_txtw
    add wave -radix unsigned /tb_osd_menu/c_tag
    add wave -radix unsigned /tb_osd_menu/c_marq
    add wave -radix unsigned /tb_osd_menu/c_mqbg
    add wave -radix unsigned /tb_osd_menu/c_red
    add wave -radix unsigned /tb_osd_menu/c_pass
    add wave -radix unsigned /tb_osd_menu/valid_cnt
}

# 5. 运行仿真
run -all

# 6. 批处理模式直接退出(供命令行自动化用)
if {[batch_mode]} {
    quit -f
}
wave zoomfull
