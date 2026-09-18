#====================================================================
# ModelSim 仿真脚本：bmp_scale 双线性插值缩放引擎
#   档位配置表(默认 640x480) + 数据流(100%/50%/25%/300% 四档)
# 用法：在 ModelSim 命令行(Transcript)执行  do {本文件路径}
#====================================================================

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件
vlog ../src/bmp_scale.v
vlog ../tb/tb_bmp_scale.v

# 3. 启动仿真
vsim -t 1ps work.tb_bmp_scale

# 4. 添加波形
add wave -divider "输入"
add wave /tb_bmp_scale/clk
add wave /tb_bmp_scale/rst
add wave -radix unsigned /tb_bmp_scale/scale_sel
add wave /tb_bmp_scale/frame_start
add wave /tb_bmp_scale/in_en
add wave -radix hex /tb_bmp_scale/in_data

add wave -divider "输出"
add wave /tb_bmp_scale/out_en
add wave -radix hex /tb_bmp_scale/out_data
add wave -radix unsigned /tb_bmp_scale/out_cnt
add wave -radix unsigned /tb_bmp_scale/err_pix

add wave -divider "内部(状态机/坐标)"
add wave -radix unsigned /tb_bmp_scale/dut/state
add wave -radix unsigned /tb_bmp_scale/dut/out_row
add wave -radix unsigned /tb_bmp_scale/dut/out_col
add wave -radix unsigned /tb_bmp_scale/dut/wr_row
add wave -radix unsigned /tb_bmp_scale/dut/wr_col
add wave -radix unsigned /tb_bmp_scale/dut/sy0_r
add wave -radix unsigned /tb_bmp_scale/dut/sy1_r
add wave -radix unsigned /tb_bmp_scale/dut/sx0_r
add wave -radix unsigned /tb_bmp_scale/dut/sx1_r
add wave -radix unsigned /tb_bmp_scale/dut/buf_vld

add wave -divider "档位配置(默认尺寸实例)"
add wave -radix unsigned /tb_bmp_scale/u_cfg/cfg_k
add wave -radix unsigned /tb_bmp_scale/u_cfg/cfg_dstw
add wave -radix unsigned /tb_bmp_scale/u_cfg/cfg_dsth
add wave -radix decimal /tb_bmp_scale/u_cfg/cfg_x0
add wave -radix decimal /tb_bmp_scale/u_cfg/cfg_y0

# 5. 运行仿真
run -all
wave zoomfull
