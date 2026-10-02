#====================================================================
# ModelSim 仿真脚本：audio_src_sel（按场景 DDS/WAV 切源）
# 用法：在 ModelSim 命令行(Transcript)执行  do {本文件路径}
#   或批处理: vsim -c -do "do run_sim_srcsel.do"
# 说明：纯组合模块，无需时钟/BRAM 模型。
#====================================================================

if {[file exists work]} { file delete -force work }
vlib work
vmap work work

vlog ../audio_final/rtl/audio_src_sel.v
vlog ../sim/tb/tb_audio_src_sel.v

vsim -t 1ps work.tb_audio_src_sel

if {![batch_mode]} {
    add wave -divider "选择"
    add wave /tb_audio_src_sel/sel_wav
    add wave -divider "DDS 侧"
    add wave /tb_audio_src_sel/dds_valid
    add wave /tb_audio_src_sel/dds_ready
    add wave -radix hex /tb_audio_src_sel/dds_left
    add wave -radix unsigned /tb_audio_src_sel/dds_gain
    add wave -divider "WAV 侧"
    add wave /tb_audio_src_sel/wav_valid
    add wave /tb_audio_src_sel/wav_ready
    add wave -radix hex /tb_audio_src_sel/wav_left
    add wave -divider "媒体口"
    add wave /tb_audio_src_sel/media_valid
    add wave /tb_audio_src_sel/media_ready
    add wave -radix hex /tb_audio_src_sel/media_left
    add wave -radix unsigned /tb_audio_src_sel/media_gain
    add wave /tb_audio_src_sel/drain_tick
}

run -all

if {[batch_mode]} {
    quit -f
}
wave zoomfull
