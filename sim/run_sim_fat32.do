#====================================================================
# ModelSim 仿真脚本：fat32_lookup  FAT32 文件名寻址层(v11)
# 用法：在 ModelSim 命令行(Transcript)执行  do {本文件路径}
#   或批处理: vsim -c -do "do run_sim_fat32.do"
# 说明: 纯控制逻辑, 无 BRAM/厂商原语依赖, 不需要 EG_LOGIC_BRAM 行为模型。
#       用 tb 内构造的【假卡镜像】驱动扇区读口(见 tb 头部几何说明)。
#
# ★ 整段用 catch 包住 + 末尾无条件 quit -f：
#   若编译失败(如 RTL 语法错), 不让 ModelSim 掉回交互式提示符挂住批处理。
#====================================================================

if {[catch {

    # 0. 清旧库(不同 ModelSim 生成的库格式可能不兼容)
    if {[file exists work]} { file delete -force work }

    # 1. 建立工作库
    vlib work
    vmap work work

    # 2. 编译源文件(DUT + TB)
    vlog ../src/fat32_lookup.v
    vlog ./tb/tb_fat32_lookup.v

    # 3. 启动仿真
    vsim -t 1ps work.tb_fat32_lookup

    # 4. 添加波形(仅 GUI 下有意义)
    if {![batch_mode]} {
        add wave -divider "时钟/复位"
        add wave /tb_fat32_lookup/clk
        add wave /tb_fat32_lookup/rst
        add wave /tb_fat32_lookup/sd_init_done
        add wave -radix unsigned /tb_fat32_lookup/zone_sel
        add wave /tb_fat32_lookup/start_req

        add wave -divider "SD 扇区读口"
        add wave /tb_fat32_lookup/sd_sec_read
        add wave -radix hex /tb_fat32_lookup/sd_sec_read_addr
        add wave /tb_fat32_lookup/sd_dvalid
        add wave /tb_fat32_lookup/sd_end

        add wave -divider "结果"
        add wave -radix hex /tb_fat32_lookup/zone_start
        add wave -radix hex /tb_fat32_lookup/zone_wrap
        add wave -radix unsigned /tb_fat32_lookup/zone_max_img
        add wave /tb_fat32_lookup/tbl_ready
        add wave /tb_fat32_lookup/zone_err

        add wave -divider "内部"
        add wave -radix unsigned /tb_fat32_lookup/dut/state
        add wave -radix unsigned /tb_fat32_lookup/dut/pfx
        add wave -radix hex /tb_fat32_lookup/dut/part_entry
        add wave -radix hex /tb_fat32_lookup/dut/data_start
        add wave -radix hex /tb_fat32_lookup/dut/root_lba
        add wave -radix unsigned /tb_fat32_lookup/dut/cnt
        add wave -radix hex /tb_fat32_lookup/dut/mn
        add wave -radix hex /tb_fat32_lookup/dut/mx
    }

    # 5. 运行仿真(tb 内置看门狗, 异常时会自行 $finish)
    run -all

    if {![batch_mode]} { wave zoomfull }

} err]} {
    echo "### SCRIPT ERROR: $err"
}

# 6. 无条件退出(供命令行自动化用)
quit -f
