onerror {quit -f}
if {[file exists work]} { file delete -force work }
vlib work
vmap work work
vlog ../src/video_first_frame_gate.v
vlog ./tb/tb_video_first_frame_gate.v
vsim -t 1ps work.tb_video_first_frame_gate
run -all
if {[batch_mode]} { quit -f }
