#====================================================================
# ModelSim 仿真脚本：scene_control 场景仲裁
#   (SW 直选 + 应急最高 + 无应急时"先触发先锁定" + 运行时长 BCD)
# 用法：在 ModelSim 命令行(Transcript)执行  do {本文件路径}
#   或命令行: vsim -c -do run_sim_scene.do (自动退出)
#====================================================================

# 0. 清旧库
if {[file exists work]} { file delete -force work }

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件
vlog ../src/scene_control.v
vlog ../tb/tb_scene_control.v

# 3. 启动仿真
vsim -t 1ps work.tb_scene_control

# 4. 添加波形(仅 GUI 下有意义)
if {![batch_mode]} {
    add wave -divider "输入"
    add wave /tb_scene_control/clk
    add wave /tb_scene_control/rst
    add wave -radix binary /tb_scene_control/sw_raw

    add wave -divider "输出"
    add wave /tb_scene_control/menu_active
    add wave -radix unsigned /tb_scene_control/latch_sw
    add wave /tb_scene_control/emergency
    add wave -radix unsigned /tb_scene_control/scene_id
    add wave /tb_scene_control/slideshow_en
    add wave /tb_scene_control/scene_change_pulse
    add wave /tb_scene_control/emergency_pulse
    add wave /tb_scene_control/alarm_clr_pulse

    add wave -divider "运行时长"
    add wave /tb_scene_control/sec_tick
    add wave -radix hex /tb_scene_control/run_hh
    add wave -radix hex /tb_scene_control/run_mm
    add wave -radix hex /tb_scene_control/run_ss

    add wave -divider "内部(拨码极性/仲裁)"
    add wave /tb_scene_control/uut/sw1_on
    add wave /tb_scene_control/uut/sw2_on
    add wave /tb_scene_control/uut/sw3_on
    add wave /tb_scene_control/uut/sw4_on
    add wave -radix unsigned /tb_scene_control/uut/lock_scene
    add wave -radix unsigned /tb_scene_control/uut/sw_on_d
    add wave -radix unsigned /tb_scene_control/uut/sel_scene
    add wave -radix unsigned /tb_scene_control/uut/scene_sel
    add wave /tb_scene_control/uut/scene_valid
    add wave /tb_scene_control/uut/emerg_now
}

# 5. 运行仿真
run -all

# 6. 批处理模式直接退出
if {[batch_mode]} {
    quit -f
}
wave zoomfull
