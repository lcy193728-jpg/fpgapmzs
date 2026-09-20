`timescale 1ns/1ps
// Public synchronous stereo PCM buffer. Inputs must share pixel_clk.
// Upstream retains valid and data until ready; this is NOT a CDC FIFO.
module audio_pcm_fifo(
    input wire clk, rst_n,
    input wire in_valid,
    output wire in_ready,
    input wire signed [15:0] in_left,in_right,
    output wire out_valid,
    input wire out_ready,
    output wire signed [15:0] out_left,out_right,
    output wire [6:0] level,
    output reg contract_error
);
    reg [31:0] mem [0:63];
    reg [5:0] wp,rp;
    reg [6:0] count;
    reg stalled;
    reg [31:0] held;
    wire pop=out_valid && out_ready;
    wire push=in_valid && in_ready;
    assign out_valid=count!=0;
    assign in_ready=count<64 || pop;
    assign {out_left,out_right}=mem[rp];
    assign level=count;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin wp<=0;rp<=0;count<=0;stalled<=0;held<=0;contract_error<=0;end
        else begin
            if(stalled && (!in_valid || {in_left,in_right}!=held)) contract_error<=1'b1;
            stalled<=in_valid && !in_ready;
            if(in_valid && !in_ready) held<={in_left,in_right};
            if(push) begin mem[wp]<={in_left,in_right};wp<=wp+1'b1;end
            if(pop) rp<=rp+1'b1;
            case({push,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:count<=count;
            endcase
        end
    end
endmodule
