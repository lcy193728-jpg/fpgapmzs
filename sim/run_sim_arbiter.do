#====================================================================
# ModelSim 仿真脚本：audio_sd_arbiter SD 扇区读总线仲裁器
# 用法：在 ModelSim 命令行(Transcript)执行  do {本文件路径}
#   或批处理: vsim -c -do "do run_sim_arbiter.do"
# 说明: 纯控制逻辑, 无 BRAM/厂商原语依赖, 不需要 EG_LOGIC_BRAM 行为模型。
#====================================================================

# 0. 清旧库(不同 ModelSim 生成的库格式可能不兼容)
if {[file exists work]} { file delete -force work }

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件(DUT + TB)
vlog ../src/audio_sd_arbiter.v
vlog ../sim/tb/tb_audio_sd_arbiter.v

# 3. 启动仿真
vsim -t 1ps work.tb_audio_sd_arbiter

# 4. 添加波形(仅 GUI 下有意义)
if {![batch_mode]} {
    add wave -divider "被测控制面"
    add wave /tb_audio_sd_arbiter/clk
    add wave /tb_audio_sd_arbiter/rst
    add wave /tb_audio_sd_arbiter/a_req
    add wave -radix hex /tb_audio_sd_arbiter/a_addr
    add wave /tb_audio_sd_arbiter/b_req
    add wave -radix hex /tb_audio_sd_arbiter/b_addr

    add wave -divider "SD 控制器侧"
    add wave /tb_audio_sd_arbiter/sd_sec_read
    add wave -radix hex /tb_audio_sd_arbiter/sd_sec_read_addr
    add wave /tb_audio_sd_arbiter/sd_sec_read_data_valid
    add wave /tb_audio_sd_arbiter/sd_sec_read_end
    add wave -radix hex /tb_audio_sd_arbiter/sd_data

    add wave -divider "路由结果"
    add wave /tb_audio_sd_arbiter/a_data_valid
    add wave /tb_audio_sd_arbiter/a_end
    add wave /tb_audio_sd_arbiter/b_data_valid
    add wave /tb_audio_sd_arbiter/b_end

    add wave -divider "内部"
    add wave -radix unsigned /tb_audio_sd_arbiter/dut/owner
    add wave -radix unsigned /tb_audio_sd_arbiter/dut/act
    add wave -radix unsigned /tb_audio_sd_arbiter/st
}

# 5. 运行仿真
run -all

# 6. 批处理模式直接退出(供命令行自动化用)
if {[batch_mode]} {
    quit -f
}
wave zoomfull
