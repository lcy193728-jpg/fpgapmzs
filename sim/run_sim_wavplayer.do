#====================================================================
# ModelSim 仿真脚本：wav_stream_player（TF 卡 WAV 流式播放器）
# 用法：在 ModelSim 命令行(Transcript)执行  do {本文件路径}
#   或批处理: vsim -c -do "do run_sim_wavplayer.do"
# 说明：纯 RTL 单元测试，无 BRAM 原语依赖（循环缓冲是 reg 数组，行为级即可）；
#       双时钟激励：写域 100MHz（sd_card_clk）+ 读域 25MHz（video_clk）。
#====================================================================

# 0. 清旧库(不同 ModelSim 生成的库格式可能不兼容)
if {[file exists work]} { file delete -force work }

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件
vlog ../audio_final/rtl/wav_stream_player.v
vlog ../sim/tb/tb_wav_stream_player.v

# 3. 启动仿真
vsim -t 1ps work.tb_wav_stream_player

# 4. 添加波形(仅 GUI 下有意义)
if {![batch_mode]} {
    add wave -divider "写域(100MHz)"
    add wave /tb_wav_stream_player/wr_clk
    add wave /tb_wav_stream_player/play_enable
    add wave -radix hex /tb_wav_stream_player/start_lba
    add wave -radix unsigned /tb_wav_stream_player/total_sectors
    add wave /tb_wav_stream_player/sd_req
    add wave -radix hex /tb_wav_stream_player/sd_lba
    add wave /tb_wav_stream_player/sd_valid
    add wave -radix hex /tb_wav_stream_player/sd_byte
    add wave /tb_wav_stream_player/sd_done
    add wave -radix unsigned /tb_wav_stream_player/dut/wstate
    add wave -radix unsigned /tb_wav_stream_player/dut/level_wr
    add wave -radix unsigned /tb_wav_stream_player/dut/wr_ptr
    add wave -radix unsigned /tb_wav_stream_player/dut/sectors_read

    add wave -divider "读域(25MHz)"
    add wave /tb_wav_stream_player/rd_clk
    add wave /tb_wav_stream_player/sample_tick
    add wave /tb_wav_stream_player/sample_ready
    add wave /tb_wav_stream_player/sample_valid
    add wave /tb_wav_stream_player/primed
    add wave -radix unsigned /tb_wav_stream_player/dut/level_rd
    add wave -radix unsigned /tb_wav_stream_player/dut/rd_ptr
    add wave -radix unsigned /tb_wav_stream_player/sample_counter
    add wave -radix hex /tb_wav_stream_player/sample_out
}

# 5. 运行仿真
run -all

# 6. 批处理模式直接退出(供命令行自动化用)
if {[batch_mode]} {
    quit -f
}
wave zoomfull
