`timescale 1ns/1ps

// 小鹅通第九讲 toggle CDC：多位配置在源域保持稳定，只在视频帧边界提交。
module emergency_cfg_frame_commit(
    input wire src_clk,input wire src_rst_n,input wire src_commit,
    input wire [223:0] src_ids,input wire [5:0] src_length,
    input wire [5:0] src_speed,input wire src_pause,input wire src_override,
    input wire dst_clk,input wire dst_rst_n,input wire frame_start,
    output reg [223:0] dst_ids,output reg [5:0] dst_length,
    output reg [5:0] dst_speed,output reg dst_pause,output reg dst_override
);
    reg commit_toggle,commit_sync1,commit_sync2,commit_seen;
    always @(posedge src_clk or negedge src_rst_n)
      if(!src_rst_n) commit_toggle<=0; else if(src_commit) commit_toggle<=~commit_toggle;
    always @(posedge dst_clk or negedge dst_rst_n) begin
      if(!dst_rst_n) begin
        // dst_ids is masked by dst_override after reset and receives a complete
        // frame-boundary commit before it can be displayed.  Leaving this wide
        // data bank unreset avoids 224 unnecessary reset loads/control pins.
        commit_sync1<=0;commit_sync2<=0;commit_seen<=0;
        dst_length<=0;dst_speed<=1;dst_pause<=0;dst_override<=0;
      end else begin
        commit_sync1<=commit_toggle;commit_sync2<=commit_sync1;
        if(frame_start && commit_sync2!=commit_seen) begin
          dst_ids<=src_ids;dst_length<=src_length;dst_speed<=src_speed;
          dst_pause<=src_pause;dst_override<=src_override;commit_seen<=commit_sync2;
        end
      end
    end
endmodule
