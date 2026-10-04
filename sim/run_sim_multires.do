#====================================================================
# ModelSim 仿真脚本：bmp_read_auto 多分辨率自适应(小鹅通第十三讲)
#   320×240 / 640×480 / 1024×768 → 统一产出 640 列
#   (1280×960 由 run_sim_2x_decim.do 覆盖)
# 用法(GUI)  : ModelSim Transcript 里  do run_sim_multires.do
# 用法(批处理): vsim -c -do run_sim_multires.do   (cwd 必须是本 sim 目录)
# 说明: 三档都做**逐输出像素**比对(流式, 不存整帧) + 整帧像素数精确核对。
#       320 用例按 4 拍/字节喂(≈12 拍/源像素): RTL 的 up_st 二次/三次发射需
#       源像素间隔 ≥4 拍, 详见 bmp_read_auto.v 的"发射节拍"说明。
#====================================================================

# 0. 出错即退出(避免批处理挂起)
onerror {quit -f}

# 1. 清旧库 + 建工作库
if {[file exists work]} { file delete -force work }
vlib work
vmap work work

# 2. 编译源文件(单模块, 无 include 依赖, 不会重复定义)
#   -sv: 让 fork...join_none 等 SystemVerilog 语法可用(FAT32 化后 tb 用了 join_none)
vlog -sv ../src/bmp_read_auto.v
vlog -sv ../tb/tb_bmp_multires.v

# 3. 启动仿真
vsim -t 1ps work.tb_bmp_multires

# 4. 添加波形
add wave -divider "时钟/复位/握手"
add wave /tb_bmp_multires/clk
add wave /tb_bmp_multires/rst
add wave /tb_bmp_multires/casemode
add wave /tb_bmp_multires/byte_div
add wave /tb_bmp_multires/sd_init_done
add wave /tb_bmp_multires/write_req
add wave /tb_bmp_multires/write_req_ack

add wave -divider "状态/结果"
add wave -radix unsigned /tb_bmp_multires/state_code
add wave -radix unsigned /tb_bmp_multires/bmp_error
add wave /tb_bmp_multires/img_res
add wave /tb_bmp_multires/img_v2x
add wave -radix unsigned /tb_bmp_multires/chk_n
add wave -radix unsigned /tb_bmp_multires/chk_col
add wave -radix unsigned /tb_bmp_multires/chk_row
add wave -radix unsigned /tb_bmp_multires/cmp_err

add wave -divider "缩放器内部"
add wave -radix unsigned /tb_bmp_multires/dut/dcol
add wave -radix unsigned /tb_bmp_multires/dut/res_r
add wave -radix unsigned /tb_bmp_multires/dut/src_w_r
add wave -radix unsigned /tb_bmp_multires/dut/src_h_r
add wave /tb_bmp_multires/dut/m_hdown
add wave /tb_bmp_multires/dut/m_hup2
add wave /tb_bmp_multires/dut/m_vdown
add wave /tb_bmp_multires/dut/m_v2x
add wave -radix unsigned /tb_bmp_multires/dut/hacc
add wave -radix unsigned /tb_bmp_multires/dut/vacc
add wave /tb_bmp_multires/dut/row_sel
add wave -radix unsigned /tb_bmp_multires/dut/hcnt_pix
add wave -radix unsigned /tb_bmp_multires/dut/acnt
add wave -radix unsigned /tb_bmp_multires/dut/n_emit
add wave -radix unsigned /tb_bmp_multires/dut/up_st
add wave /tb_bmp_multires/dut/up_more

add wave -divider "像素输出"
add wave /tb_bmp_multires/bmp_data_wr_en
add wave -radix hex /tb_bmp_multires/bmp_data
add wave -radix hex /tb_bmp_multires/expv

# 5. 运行仿真
run -all
wave zoomfull
