#====================================================================
# ModelSim 仿真脚本：迎新 WAV 音频链路端到端集成测试
# 用法：在 sim 目录执行  vsim -c -do "do run_sim_audio_e2e.do"
#====================================================================
onerror {quit -f}
if {[file exists work]} { file delete -force work }
vlib work
vmap work work

vlog ../audio_final/rtl/wav_stream_player.v
vlog ../src/audio_sd_arbiter.v
vlog ../audio_final/rtl/audio_src_sel.v
vlog ../audio_board/rtl/audio_src_mux.v
vlog ../sim/tb/tb_audio_chain_e2e.v

vsim -t 1ps work.tb_audio_chain_e2e

if {![batch_mode]} {
    add wave -divider "时钟/节拍"
    add wave /tb_audio_chain_e2e/video_clk
    add wave /tb_audio_chain_e2e/audio_rate_tick
    add wave /tb_audio_chain_e2e/sel_wav
    add wave -divider "WAV 播放器"
    add wave /tb_audio_chain_e2e/wav_primed
    add wave /tb_audio_chain_e2e/wav_valid
    add wave /tb_audio_chain_e2e/wav_ready
    add wave -radix decimal /tb_audio_chain_e2e/wav_left
    add wave -radix unsigned /tb_audio_chain_e2e/u_wav_player/rd_ptr
    add wave -radix unsigned /tb_audio_chain_e2e/u_wav_player/level_rd
    add wave -divider "切源/混音"
    add wave /tb_audio_chain_e2e/media_valid
    add wave /tb_audio_chain_e2e/media_ready
    add wave /tb_audio_chain_e2e/zero_valid
    add wave /tb_audio_chain_e2e/audio_pcm_valid
    add wave /tb_audio_chain_e2e/audio_pcm_ready
    add wave -radix decimal /tb_audio_chain_e2e/audio_left
    add wave -divider "SD"
    add wave /tb_audio_chain_e2e/sd_sec_read
    add wave /tb_audio_chain_e2e/wav_sec_req_raw
    add wave /tb_audio_chain_e2e/wav_sec_data_valid
    add wave /tb_audio_chain_e2e/wav_sec_end
}

run -all

if {[batch_mode]} {
    quit -f
}
wave zoomfull
