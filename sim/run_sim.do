#====================================================================
# ModelSim 仿真脚本：bmp_read_auto 分区自动轮播 + 场景分区重载
# 用法：在 ModelSim 命令行(Transcript)执行  do {本文件路径}
#   或先 File -> Change Directory 到 sim 目录，再执行  do run_sim.do
#====================================================================

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件
vlog ../src/bmp_read_auto.v
vlog ../tb/tb_bmp_read_auto.v

# 3. 启动仿真
vsim -t 1ps work.tb_bmp_read_auto

# 4. 添加波形
add wave -divider "时钟与复位"
add wave /tb_bmp_read_auto/clk
add wave /tb_bmp_read_auto/rst
add wave /tb_bmp_read_auto/sd_init_done

add wave -divider "输入(按键/使能/分区)"
add wave /tb_bmp_read_auto/key_trigger
add wave /tb_bmp_read_auto/key_prev
add wave /tb_bmp_read_auto/slide_en
add wave -radix unsigned /tb_bmp_read_auto/zone_start
add wave -radix unsigned /tb_bmp_read_auto/zone_wrap
add wave -radix unsigned /tb_bmp_read_auto/zone_max_img
add wave /tb_bmp_read_auto/zone_load

add wave -divider "状态机"
add wave -radix unsigned /tb_bmp_read_auto/state_code

add wave -divider "图序号/读入口(验证下一张/上一张)"
add wave -radix unsigned /tb_bmp_read_auto/img_no
add wave -radix unsigned /tb_bmp_read_auto/rd_base

add wave -divider "SD 读接口"
add wave /tb_bmp_read_auto/sd_sec_read
add wave -radix unsigned /tb_bmp_read_auto/sd_sec_read_addr
add wave /tb_bmp_read_auto/sd_sec_read_data_valid
add wave /tb_bmp_read_auto/sd_sec_read_end

add wave -divider "像素输出"
add wave /tb_bmp_read_auto/bmp_data_wr_en
add wave -radix hex /tb_bmp_read_auto/bmp_data

add wave -divider "内部状态"
add wave -radix unsigned /tb_bmp_read_auto/dut/state
add wave -radix unsigned /tb_bmp_read_auto/dut/hold_cnt
add wave -radix unsigned /tb_bmp_read_auto/dut/img_cnt
add wave -radix unsigned /tb_bmp_read_auto/dut/bmp_len_cnt
add wave /tb_bmp_read_auto/dut/found
add wave -radix unsigned /tb_bmp_read_auto/dut/z_start
add wave -radix unsigned /tb_bmp_read_auto/dut/z_wrap
add wave -radix unsigned /tb_bmp_read_auto/dut/z_max
add wave /tb_bmp_read_auto/dut/zone_pend
add wave /tb_bmp_read_auto/defer_hold_seen

# 5. 运行仿真
run -all
wave zoomfull
