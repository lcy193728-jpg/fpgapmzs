`timescale 1ns/1ps
// Recover active-origin full-line x (0..799), including vertical blanking.
// VGA negative HS falls at x=656, rises at x=752. All inputs are FINAL video.
// Register x AND the entire video bundle together, avoiding a one-pixel skew.
module audio_video_phase(
    input wire clk,rst_n,hs_i,vs_i,de_i,
    input wire [23:0] rgb_i,
    output reg hs_o,vs_o,de_o,
    output reg [23:0] rgb_o,
    output reg [9:0] x_o,
    output reg locked,
    output reg timing_error
);
    reg hs_d,de_d;
    reg [9:0] next_x;
    wire hs_fall=hs_d && !hs_i;
    wire hs_rise=!hs_d && hs_i;
    wire de_rise=!de_d && de_i;
    wire [9:0] this_x=hs_fall ? 10'd656 : next_x;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            // Baseline video starts HS low during reset. Wait for a real high
            // level then a falling edge instead of declaring a synthetic lock.
            hs_d<=0;de_d<=0;next_x<=0;x_o<=0;
            hs_o<=1;vs_o<=1;de_o<=0;rgb_o<=0;locked<=0;timing_error<=0;
        end else begin
            hs_d<=hs_i;de_d<=de_i;
            hs_o<=hs_i;vs_o<=vs_i;de_o<=de_i;rgb_o<=rgb_i;x_o<=this_x;
            next_x<=this_x==799 ? 10'd0 : this_x+1'b1;
            if(hs_fall) begin
                if(locked && next_x!=656) timing_error<=1'b1;
                locked<=1'b1;
            end
            if(locked && hs_rise && this_x!=752) timing_error<=1'b1;
            if(locked && de_rise && this_x!=0) timing_error<=1'b1;
        end
    end
endmodule
