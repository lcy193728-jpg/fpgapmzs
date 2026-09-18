`timescale 1ns/1ps
`include "../../src/reset_sync.v"
// Independent HDMI smoke test: no TF card, SDRAM, switches or buttons required.
module top(
    input wire clk,
    output wire HDMI_CLK_P,HDMI_D0_P,HDMI_D1_P,HDMI_D2_P
);
    // Test profiles are compile-time; no existing board controls are changed.
    localparam integer AUDIO_PROFILE=0; // 0 stereo, 1 left only, 2 right only
    reg [19:0] por=0;
    always @(posedge clk) if(!por[19]) por<=por+1'b1;
    wire pixel_clk,serial_clk,pll_locked;
    video_pll video_pll_m0(.refclk(clk),.reset(!por[19]),
        .clk0_out(pixel_clk),.clk1_out(serial_clk),.locked(pll_locked));
    wire ext_rst_n=por[19] && pll_locked;
    wire rst_n_vid,rst_n_ser;
    reset_sync u_rst_vid(.clk(pixel_clk),.rst_n_async(ext_rst_n),.rst_n_sync(rst_n_vid));
    reset_sync u_rst_ser(.clk(serial_clk),.rst_n_async(ext_rst_n),.rst_n_sync(rst_n_ser));
    reg [9:0] x,y;
    always @(posedge pixel_clk or negedge rst_n_vid) begin
        if(!rst_n_vid) begin x<=0;y<=0;end
        else if(x==799) begin x<=0;y<=y==524 ? 10'd0 : y+1'b1;end
        else x<=x+1'b1;
    end
    wire hs=!(x>=656 && x<752);
    wire vs=!(y>=490 && y<492);
    wire de=x<640 && y<480;
    reg [23:0] rgb;
    wire timing_locked,timing_error,sequence_error,pcm_contract_error,tone_overflow;
    wire [6:0] fifo_level;
    wire [31:0] generated_samples,accepted_samples;
    // Eight standard bars. First 16 rows are green if no sticky errors.
    always @* begin
        case(x/80)
            0:rgb=24'hffffff;1:rgb=24'hffff00;2:rgb=24'h00ffff;3:rgb=24'h00ff00;
            4:rgb=24'hff00ff;5:rgb=24'hff0000;6:rgb=24'h0000ff;default:rgb=0;
        endcase
        if(y<16) begin
            if(timing_error) rgb=24'hff00ff;
            else if(sequence_error) rgb=24'hff0000;
            else if(tone_overflow) rgb=24'h0000ff;
            else if(pcm_contract_error) rgb=24'hff8000;
            else rgb=timing_locked ? 24'h00ff00 : 24'h00ffff;
        end
    end
    wire valid,ready;
    wire signed [15:0] left,right;
    audio_pcm_tone #(.PROFILE(AUDIO_PROFILE)) u_test_tone(.clk(pixel_clk),.rst_n(rst_n_vid),.enable(1'b1),
        .sample_valid(valid),.sample_ready(ready),.sample_left(left),.sample_right(right),
        .overflow(tone_overflow),.sample_count(generated_samples));
    audio_hdmi_output u_audio(.pixel_clk(pixel_clk),.serial_clk(serial_clk),
        .pixel_rst_n(rst_n_vid),.serial_rst_n(rst_n_ser),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .pcm_valid(valid),.pcm_ready(ready),.pcm_left(left),.pcm_right(right),
        .HDMI_CLK_P(HDMI_CLK_P),.HDMI_D0_P(HDMI_D0_P),.HDMI_D1_P(HDMI_D1_P),.HDMI_D2_P(HDMI_D2_P),
        .timing_locked(timing_locked),.timing_error(timing_error),.sequence_error(sequence_error),
        .pcm_contract_error(pcm_contract_error),.fifo_level(fifo_level),.accepted_samples(accepted_samples));
endmodule
