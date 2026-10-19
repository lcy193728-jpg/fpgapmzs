`timescale 1ns/1ps

// Xiaoe lesson-9 style toggle CDC; the multi-bit source bus remains stable until
// the next command and is committed only at a video frame boundary.
module welcome_cfg_frame_commit(
    input wire src_clk,input wire src_rst_n,input wire src_commit,
    input wire [191:0] src_ids,input wire [5:0] src_length,input wire [5:0] src_speed,
    input wire src_pause,input wire dst_clk,input wire dst_rst_n,input wire frame_start,
    output reg [191:0] dst_ids,output reg [5:0] dst_length,output reg [5:0] dst_speed,
    output reg dst_pause
);
    localparam [191:0] DEFAULT_IDS=192'h0000000000000000003ce34c00b2802480041c0185103081;
    reg commit_toggle,commit_sync1,commit_sync2,commit_seen;
    always @(posedge src_clk or negedge src_rst_n)
      if(!src_rst_n) commit_toggle<=0; else if(src_commit) commit_toggle<=~commit_toggle;
    always @(posedge dst_clk or negedge dst_rst_n) begin
      if(!dst_rst_n) begin
        commit_sync1<=0;commit_sync2<=0;commit_seen<=0;
        dst_ids<=DEFAULT_IDS;
        dst_length<=20;dst_speed<=1;dst_pause<=0;
      end else begin
        commit_sync1<=commit_toggle;commit_sync2<=commit_sync1;
        if(frame_start && commit_sync2!=commit_seen) begin
          dst_ids<=src_ids;dst_length<=src_length;dst_speed<=src_speed;dst_pause<=src_pause;
          commit_seen<=commit_sync2;
        end
      end
    end
endmodule
