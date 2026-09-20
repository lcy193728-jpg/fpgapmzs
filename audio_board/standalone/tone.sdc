# 25 MHz / 125 MHz are RELATED clocks: never false-path the symbol transfer.
create_clock -name clk -period 20.000 [get_ports {clk}]
create_generated_clock -name video_clk -source [get_ports {clk}] -master_clock clk -divide_by 2 [get_pins {video_pll_m0/pll_inst.clkc[0]}]
create_generated_clock -name hdmi_5x_clk -source [get_ports {clk}] -master_clock clk -multiply_by 2.5 [get_pins {video_pll_m0/pll_inst.clkc[1]}]
set_false_path -to [get_regs -hier {*/sync_ff[0]}]
set_false_path -from [get_pins {video_pll_m0/pll_inst.extlock}]
set_clock_uncertainty -hold 0.050 [get_clocks {clk video_clk hdmi_5x_clk}]
set_max_delay -from [get_clocks {hdmi_5x_clk}] -to [get_ports {HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P}] 8.000 -datapath_only
