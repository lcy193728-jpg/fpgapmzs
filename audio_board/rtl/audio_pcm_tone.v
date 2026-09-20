`timescale 1ns/1ps
// 48 kHz, signed stereo PCM. Fractional enable is NOT a generated clock.
// profile 0: stereo; 1: left only; 2: right only. No physical keys changed.
module audio_pcm_tone #(
    parameter integer CLOCK_HZ = 25000000,
    parameter integer SAMPLE_HZ = 48000,
    parameter [31:0] PHASE_INC = 32'd89478485, // round(1000*2^32/48000)
    parameter integer PROFILE = 0
)(
    input wire clk, rst_n, enable,
    output wire sample_valid,
    input wire sample_ready,
    output wire signed [15:0] sample_left, sample_right,
    output reg overflow,
    output reg [31:0] sample_count
);
    reg [31:0] rate_acc, phase;
    reg signed [15:0] sine_q;
    reg [15:0] fifo [0:31];
    reg [4:0] wp, rp;
    reg [5:0] count;
    // Gain rises to 1 in 512 samples (~10.7 ms); peak 4096 (~-18 dBFS).
    reg [9:0] gain;
    wire tick = rate_acc >= CLOCK_HZ-SAMPLE_HZ;
    wire pop = sample_valid && sample_ready;
    wire push = tick && (count < 32 || pop);
    wire signed [15:0] raw = sine_q;
    wire signed [26:0] product = raw * $signed({1'b0,gain});
    wire signed [15:0] scaled = product >>> 9;
    assign sample_valid = count != 0;
    assign sample_left = PROFILE == 2 ? 16'sd0 : fifo[rp];
    assign sample_right = PROFILE == 1 ? 16'sd0 : fifo[rp];
    // Generated constant lookup; no external file or RAM initialization needed.
    `include "audio_sine_init.vh"
    always @(posedge clk) sine_q <= audio_sine(phase[31:24]);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rate_acc<=0; phase<=0; wp<=0; rp<=0; count<=0;
            gain<=0; overflow<=0; sample_count<=0;
        end else begin
            if (tick) begin
                rate_acc<=rate_acc+SAMPLE_HZ-CLOCK_HZ;
                phase<=phase+PHASE_INC;
                sample_count<=sample_count+1'b1;
                if (enable && gain<512) gain<=gain+1'b1;
                else if (!enable && gain!=0) gain<=gain-1'b1;
                if (!push) overflow<=1'b1;
            end else rate_acc<=rate_acc+SAMPLE_HZ;
            if (push) begin fifo[wp]<=scaled; wp<=wp+1'b1; end
            if (pop) rp<=rp+1'b1;
            case ({push,pop})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default: count<=count;
            endcase
        end
    end
endmodule
