if {[file exists work]} { file delete -force work }
vlib work
vmap work work
vlog ../src/uart_rx_byte.v
vlog ../src/uart_tx_byte.v
vlog ../src/welcome_uart_controller.v
vlog ../src/welcome_cfg_frame_commit.v
vlog ../tb/tb_welcome_uart.v
vsim -t 1ps work.tb_welcome_uart
run -all
if {[batch_mode]} { quit -f }
