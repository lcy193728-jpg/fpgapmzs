#====================================================================
# ModelSim 仿真脚本：bmp_read_auto 自动轮播 + 按键手动切图
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

add wave -divider "按键"
add wave /tb_bmp_read_auto/key_trigger

add wave -divider "状态机"
add wave -radix unsigned /tb_bmp_read_auto/state_code

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

# 5. 运行仿真
run -all
wave zoomfull
