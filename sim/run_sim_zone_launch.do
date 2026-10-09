#====================================================================
# ModelSim 仿真脚本：zone_launch  FAT32 查表「停车/交棒」握手时序(v11)
# 用法：命令行  vsim -c -do "do run_sim_zone_launch.do"
# 说明: 纯控制逻辑, 无 BRAM/厂商原语依赖。
#       被测 src/zone_launch.v + 真实 src/audio_sd_arbiter.v;
#       BMP 主设备 / 查表桩 / SD 控制器均为 tb 内行为模型
#       (协议按 bmp_read_auto 与 sd_card_sec_read_write 的源码逐条对齐)。
#
# ★ 整段用 catch 包住 + 末尾无条件 quit -f：
#   若编译失败(如 RTL 语法错), 不让 ModelSim 掉回交互式提示符挂住批处理。
#====================================================================

if {[catch {

    if {[file exists work]} { file delete -force work }
    vlib work
    vmap work work

    vlog ../src/zone_launch.v
    vlog ../src/audio_sd_arbiter.v
    vlog ./tb/tb_zone_launch.v

    vsim -t 1ps work.tb_zone_launch

    if {![batch_mode]} {
        add wave -divider "时钟/复位"
        add wave /tb_zone_launch/clk
        add wave /tb_zone_launch/rst
        add wave /tb_zone_launch/naive_mode

        add wave -divider "请求/交棒"
        add wave /tb_zone_launch/lu_req
        add wave /tb_zone_launch/lu_start
        add wave /tb_zone_launch/bmp_go
        add wave /tb_zone_launch/bus_free
        add wave /tb_zone_launch/pend_n
        add wave /tb_zone_launch/u_dut/pend
        add wave /tb_zone_launch/zone_load
        add wave /tb_zone_launch/first_tbl_done_c

        add wave -divider "A 侧请求(必须互斥)"
        add wave /tb_zone_launch/bmp_sec_read
        add wave /tb_zone_launch/lu_sec_read
        add wave /tb_zone_launch/a_req
        add wave -radix unsigned /tb_zone_launch/a_addr

        add wave -divider "仲裁器"
        add wave -radix unsigned /tb_zone_launch/u_arb/owner
        add wave /tb_zone_launch/sd_sec_read
        add wave -radix unsigned /tb_zone_launch/sd_sec_read_addr
        add wave /tb_zone_launch/b_req
        add wave -radix unsigned /tb_zone_launch/b_addr

        add wave -divider "SD 控制器模型"
        add wave -radix unsigned /tb_zone_launch/st
        add wave -radix unsigned /tb_zone_launch/cur_lba
        add wave /tb_zone_launch/sd_data_valid
        add wave /tb_zone_launch/sd_end

        add wave -divider "查表桩"
        add wave -radix unsigned /tb_zone_launch/lu_st
        add wave /tb_zone_launch/lu_busy
        add wave /tb_zone_launch/lu_ready
        add wave -radix unsigned /tb_zone_launch/lu_left

        add wave -divider "违例计数"
        add wave -radix unsigned /tb_zone_launch/viol_a1
        add wave -radix unsigned /tb_zone_launch/viol_a2
        add wave -radix unsigned /tb_zone_launch/viol_a3
        add wave -radix unsigned /tb_zone_launch/viol_a4
    }

    run -all

    if {![batch_mode]} { wave zoomfull }

} err]} {
    echo "### SCRIPT ERROR: $err"
}

quit -f
