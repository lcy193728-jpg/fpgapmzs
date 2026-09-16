#====================================================================
# ModelSim 仿真脚本：display_adjust 显示末级调节引擎
#   (16档亮度条 + 8档缩放条 + 轮播/手动状态卡 + 场景切换淡入淡出 + 应急抑制)
# 用法：File -> Change Directory 到 sim 目录，再执行 do run_sim_display.do
#   或命令行: vsim -c -do run_sim_display.do (自动退出)
#====================================================================

# 0. 清旧库
if {[file exists work]} { file delete -force work }

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件(display_adjust 独立, 无 ROM 依赖)与 TB
vlog ../src/display_adjust.v
vlog ../tb/tb_display_adjust.v

# 3. 启动仿真
vsim -t 1ps work.tb_display_adjust

# 4. 添加波形(仅 GUI 下有意义)
if {![batch_mode]} {
    add wave -divider "输入"
    add wave /tb_display_adjust/clk
    add wave /tb_display_adjust/rst
    add wave /tb_display_adjust/hs_i
    add wave /tb_display_adjust/vs_i
    add wave /tb_display_adjust/de_i
    add wave -radix hex /tb_display_adjust/data_i
    add wave /tb_display_adjust/menu_active
    add wave /tb_display_adjust/emerg
    add wave /tb_display_adjust/bmp_busy
    add wave -radix unsigned /tb_display_adjust/bri_level
    add wave -radix unsigned /tb_display_adjust/res_level
    add wave /tb_display_adjust/pic_manual
    add wave -radix unsigned /tb_display_adjust/ui_mode

    add wave -divider "输出"
    add wave /tb_display_adjust/hs_o
    add wave /tb_display_adjust/vs_o
    add wave /tb_display_adjust/de_o
    add wave -radix hex /tb_display_adjust/data_o

    add wave -divider "内部"
    add wave /tb_display_adjust/u_disp/menu_s
    add wave /tb_display_adjust/u_disp/emerg_s
    add wave /tb_display_adjust/u_disp/busy_s
    add wave -radix unsigned /tb_display_adjust/u_disp/lvl_s
    add wave -radix unsigned /tb_display_adjust/u_disp/fsm
    add wave -radix unsigned /tb_display_adjust/u_disp/alpha
    add wave -radix unsigned /tb_display_adjust/u_disp/bar_cnt
    add wave -radix hex /tb_display_adjust/u_disp/fo

    add wave -divider "统计"
    add wave -radix unsigned /tb_display_adjust/act_cnt
    add wave -radix unsigned /tb_display_adjust/c_uni
    add wave -radix unsigned /tb_display_adjust/c_bd
    add wave -radix unsigned /tb_display_adjust/c_fg
    add wave -radix unsigned /tb_display_adjust/c_bgs
    add wave -radix unsigned /tb_display_adjust/valid_cnt
    add wave -radix unsigned /tb_display_adjust/exp_uni
}

# 5. 运行仿真
run -all

# 6. 批处理模式直接退出
if {[batch_mode]} {
    quit -f
}
wave zoomfull
