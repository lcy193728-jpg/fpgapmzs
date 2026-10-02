#====================================================================
# ModelSim 仿真脚本：1280×960(2× 源) → 640×480 降采样专项验证
#   针对 2026-10-02 修复的"均值位宽截断"缺陷 (bmp_read_auto.v 的 ha_r/g/b)
#   用例喂入"通道和 ≥ 256"的像素对, 修复前必然 FAIL, 修复后应全 PASS
# 用法(GUI): ModelSim Transcript 里  do run_sim_2x_decim.do
# 用法(批处理): vsim -c -do run_sim_2x_decim.do     (cwd 必须是本 sim 目录)
#====================================================================

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件(单模块, 无 include 依赖, 不会重复定义)
vlog ../src/bmp_read_auto.v
vlog ../tb/tb_bmp_2x_decim.v

# 3. 启动仿真
vsim -t 1ps work.tb_bmp_2x_decim

# 4. 添加波形
add wave -divider "时钟/复位"
add wave /tb_bmp_2x_decim/clk
add wave /tb_bmp_2x_decim/rst
add wave /tb_bmp_2x_decim/sd_init_done

add wave -divider "状态"
add wave -radix unsigned /tb_bmp_2x_decim/state_code
add wave -radix unsigned /tb_bmp_2x_decim/sd_sec_read_addr
add wave /tb_bmp_2x_decim/img_res
add wave /tb_bmp_2x_decim/img_v2x
add wave -radix unsigned /tb_bmp_2x_decim/bmp_error
add wave -radix unsigned /tb_bmp_2x_decim/img_no

add wave -divider "像素输出(重点)"
add wave /tb_bmp_2x_decim/bmp_data_wr_en
add wave -radix hex /tb_bmp_2x_decim/bmp_data
add wave -radix unsigned /tb_bmp_2x_decim/out_n

add wave -divider "缩放内部(多分辨率, 2026-10-02)"
add wave -radix unsigned /tb_bmp_2x_decim/dut/dcol
add wave -radix unsigned /tb_bmp_2x_decim/dut/res_r
add wave -radix unsigned /tb_bmp_2x_decim/dut/src_w_r
add wave -radix unsigned /tb_bmp_2x_decim/dut/src_h_r
add wave /tb_bmp_2x_decim/dut/m_hdown
add wave /tb_bmp_2x_decim/dut/m_hup2
add wave /tb_bmp_2x_decim/dut/m_vdown
add wave /tb_bmp_2x_decim/dut/m_v2x
add wave -radix unsigned /tb_bmp_2x_decim/dut/hacc
add wave -radix unsigned /tb_bmp_2x_decim/dut/vacc
add wave /tb_bmp_2x_decim/dut/row_sel
add wave -radix unsigned /tb_bmp_2x_decim/dut/hcnt_pix
add wave -radix unsigned /tb_bmp_2x_decim/dut/up_st
add wave /tb_bmp_2x_decim/dut/up_more
add wave -radix hex /tb_bmp_2x_decim/dut/asm_data
add wave -radix hex /tb_bmp_2x_decim/dut/bmp_data

add wave -divider "计数"
add wave -radix unsigned /tb_bmp_2x_decim/dut/pixel_cnt
add wave -radix unsigned /tb_bmp_2x_decim/dut/pix_cnt_tgt
add wave -radix unsigned /tb_bmp_2x_decim/dut/bmp_len_cnt

# 5. 运行仿真
run -all
wave zoomfull

# 6. 批处理模式自动退出(交互模式忽略)
quit -f
