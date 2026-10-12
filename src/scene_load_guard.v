//====================================================================
// 场景加载提交保护
//
// scene_change_pulse 只表示“请求换场景”；img_busy 的下降沿只表示 SD/BMP
// 源端已经停止送像素。缩放器、异步 FIFO 和 SDRAM 写状态机仍可能在排空，
// 所以不能据此开始淡入。这里把 mem_clk 域的 write_finish 脉冲转换为 toggle
// 后同步到 sd_clk 域，并且只接受 img_busy 完整经历 1→0 后到达的提交事件。
//
// 在 img_busy=1 期间持续刷新 commit_base，可吞掉切场前一帧的迟到提交；
// img_busy=0 后只有新的 write_finish 才能释放 guard_busy。这样单缓冲 SDRAM
// 永远不会在半帧写入时被重新显示。
//====================================================================
`timescale 1ns/1ps

module scene_load_guard (
    input  wire mem_clk,
    input  wire rst_mem,
    input  wire write_finish,
    input  wire sd_clk,
    input  wire rst_sd,
    input  wire scene_change,
    input  wire img_busy,
    output reg  guard_busy
);
    reg commit_toggle_mem;
    reg commit_s0, commit_s1;
    reg commit_base;
    reg source_busy_seen;

    always @(posedge mem_clk or posedge rst_mem) begin
        if (rst_mem)
            commit_toggle_mem <= 1'b0;
        else if (write_finish)
            commit_toggle_mem <= ~commit_toggle_mem;
    end

    always @(posedge sd_clk or posedge rst_sd) begin
        if (rst_sd) begin
            commit_s0 <= 1'b0;
            commit_s1 <= 1'b0;
        end
        else begin
            commit_s0 <= commit_toggle_mem;
            commit_s1 <= commit_s0;
        end
    end

    always @(posedge sd_clk or posedge rst_sd) begin
        if (rst_sd) begin
            guard_busy       <= 1'b0;
            commit_base      <= 1'b0;
            source_busy_seen <= 1'b0;
        end
        else if (scene_change) begin
            guard_busy       <= 1'b1;
            commit_base      <= commit_s1;
            source_busy_seen <= img_busy;
        end
        else if (guard_busy) begin
            if (img_busy) begin
                // 目标源帧尚未结束；旧帧的迟到提交不能释放黑场。
                source_busy_seen <= 1'b1;
                commit_base      <= commit_s1;
            end
            else if (source_busy_seen && (commit_s1 != commit_base)) begin
                // 源帧已完整结束，且缩放/FIFO/SDRAM 也真正提交完毕。
                guard_busy       <= 1'b0;
                source_busy_seen <= 1'b0;
                commit_base      <= commit_s1;
            end
        end
    end
endmodule
