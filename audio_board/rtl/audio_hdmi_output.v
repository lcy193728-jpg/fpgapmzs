`timescale 1ns/1ps
// Public bottom layer: final VGA video + signed 16-bit stereo PCM -> HDMI.
// Fixed 25 MHz / 800 pixels per line / negative sync / 48 kHz / RGB888.
// Caller supplies uninterrupted 48-kHz PCM, including zeros during silence.
module audio_hdmi_output(
    input wire pixel_clk,serial_clk,pixel_rst_n,serial_rst_n,
    input wire hs,vs,de,
    input wire [23:0] rgb,
    input wire pcm_valid,
    output wire pcm_ready,
    input wire signed [15:0] pcm_left,pcm_right,
    output wire HDMI_CLK_P,HDMI_D0_P,HDMI_D1_P,HDMI_D2_P,
    output wire timing_locked,timing_error,sequence_error,pcm_contract_error,
    output wire [6:0] fifo_level,
    output reg [31:0] accepted_samples
);
    wire qhs,qvs,qde;
    wire [23:0] qrgb;
    wire [9:0] qx;
    audio_video_phase u_phase(.clk(pixel_clk),.rst_n(pixel_rst_n),
        .hs_i(hs),.vs_i(vs),.de_i(de),.rgb_i(rgb),
        .hs_o(qhs),.vs_o(qvs),.de_o(qde),.rgb_o(qrgb),.x_o(qx),
        .locked(timing_locked),.timing_error(timing_error));
    wire valid,ready,core_ready;
    assign ready=core_ready && timing_locked;
    wire signed [15:0] left,right;
    audio_pcm_fifo u_fifo(.clk(pixel_clk),.rst_n(pixel_rst_n),
        .in_valid(pcm_valid),.in_ready(pcm_ready),.in_left(pcm_left),.in_right(pcm_right),
        .out_valid(valid),.out_ready(ready),.out_left(left),.out_right(right),
        .level(fifo_level),.contract_error(pcm_contract_error));
    always @(posedge pixel_clk or negedge pixel_rst_n)
        if(!pixel_rst_n) accepted_samples<=0;
        else if(valid && ready && timing_locked) accepted_samples<=accepted_samples+1'b1;
    wire [9:0] c0,c1,c2;
    hdmi_audio_symbol_core u_core(.pixel_clk(pixel_clk),.rst_n(pixel_rst_n && timing_locked),
        .video_hsync(qhs),.video_vsync(qvs),.video_de(qde),.video_x(qx),.video_rgb(qrgb),
        .sample_valid(valid),.sample_ready(core_ready),.sample_left(left),.sample_right(right),
        .channel0_symbol(c0),.channel1_symbol(c1),.channel2_symbol(c2),.sequence_error(sequence_error));
    audio_eg4_phy u_phy(.pixel_clk(pixel_clk),.serial_clk(serial_clk),
        .pixel_rst_n(pixel_rst_n),.serial_rst_n(serial_rst_n),.c0(c0),.c1(c1),.c2(c2),
        .clk_p(HDMI_CLK_P),.d0_p(HDMI_D0_P),.d1_p(HDMI_D1_P),.d2_p(HDMI_D2_P));
endmodule
