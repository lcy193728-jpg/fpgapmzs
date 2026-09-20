`timescale 1ns/1ps
// Drain BOTH sources at the same sample index, so the unselected test tone
// never stalls or accumulates stale data. One registered output holds on stall.
// During 256-sample transitions only: test + (media-test)*gain/256.
// Serial shift/add uses zero extra DSP blocks (integrated baseline uses 29/29).
module audio_src_mux(
    input wire clk,rst_n,
    input wire test_valid,media_valid,
    output wire test_ready,media_ready,
    input wire signed [15:0] test_left,test_right,media_left,media_right,
    input wire [8:0] media_gain,
    output reg sample_valid,input wire sample_ready,
    output reg signed [15:0] sample_left,sample_right,
    output reg [31:0] accepted_pairs
);
    reg busy;
    reg [3:0] bit_index;
    reg [8:0] weight;
    reg signed [26:0] term_l,term_r,acc_l,acc_r;
    reg signed [15:0] base_l,base_r;
    wire launch=!busy && (!sample_valid || sample_ready) && test_valid && media_valid;
    assign test_ready=launch;
    assign media_ready=launch;
    wire signed [16:0] diff_l=$signed({media_left[15],media_left})-$signed({test_left[15],test_left});
    wire signed [16:0] diff_r=$signed({media_right[15],media_right})-$signed({test_right[15],test_right});
    wire signed [26:0] sum_l=acc_l+(weight[0] ? term_l:27'sd0);
    wire signed [26:0] sum_r=acc_r+(weight[0] ? term_r:27'sd0);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            sample_valid<=0;sample_left<=0;sample_right<=0;busy<=0;
            bit_index<=0;weight<=0;term_l<=0;term_r<=0;acc_l<=0;acc_r<=0;
            base_l<=0;base_r<=0;accepted_pairs<=0;
        end else begin
            if(sample_valid && sample_ready) sample_valid<=0;
            if(launch) begin
                busy<=1;bit_index<=0;weight<=media_gain;acc_l<=0;acc_r<=0;
                term_l<=diff_l;term_r<=diff_r;base_l<=test_left;base_r<=test_right;
                accepted_pairs<=accepted_pairs+1'b1;
            end else if(busy) begin
                acc_l<=sum_l;acc_r<=sum_r;weight<=weight>>1;
                term_l<=term_l<<<1;term_r<=term_r<<<1;
                if(bit_index==8) begin
                    sample_left<=base_l+(sum_l>>>8);sample_right<=base_r+(sum_r>>>8);
                    sample_valid<=1;busy<=0;
                end else bit_index<=bit_index+1'b1;
            end
        end
    end
endmodule
