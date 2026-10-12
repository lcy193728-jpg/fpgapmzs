//====================================================================
// 抢答结束页专用完整帧提交保护
// write_finish 经 toggle + 2FF 跨到 sd_clk；q_end 后必须看到本次图片
// busy，并等 busy 结束且新的 SDRAM 整帧提交到达，才置 ready。
//====================================================================
`timescale 1ns/1ps
module quiz_end_commit_guard (
    input wire mem_clk,input wire rst_mem,input wire write_finish,
    input wire sd_clk,input wire rst_sd,input wire quiz_en,
    input wire q_end,input wire img_busy,output reg ready
);
    reg commit_toggle_mem;
    reg commit_s0,commit_s1;
    reg qend_d,source_busy_seen,commit_base;

    always @(posedge mem_clk or posedge rst_mem) begin
        if(rst_mem) commit_toggle_mem<=1'b0;
        else if(write_finish) commit_toggle_mem<=~commit_toggle_mem;
    end
    always @(posedge sd_clk or posedge rst_sd) begin
        if(rst_sd)begin commit_s0<=1'b0;commit_s1<=1'b0;end
        else begin commit_s0<=commit_toggle_mem;commit_s1<=commit_s0;end
    end
    always @(posedge sd_clk or posedge rst_sd) begin
        if(rst_sd)begin
            ready<=1'b0;qend_d<=1'b0;source_busy_seen<=1'b0;commit_base<=1'b0;
        end else begin
            qend_d<=q_end;
            if(!quiz_en || !q_end)begin
                ready<=1'b0;source_busy_seen<=1'b0;commit_base<=commit_s1;
            end else if(!qend_d)begin
                // 事务开始时只锁一次基线；busy 期间不刷新，避免吞掉目标提交。
                ready<=1'b0;source_busy_seen<=img_busy;commit_base<=commit_s1;
            end else if(!ready)begin
                if(img_busy) source_busy_seen<=1'b1;
                if(source_busy_seen && !img_busy && (commit_s1!=commit_base))begin
                    ready<=1'b1;source_busy_seen<=1'b0;
                end
            end
        end
    end
endmodule
