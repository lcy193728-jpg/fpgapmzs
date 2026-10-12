//====================================================================
// 上电首帧显示门控
//
// SDRAM 初始化完成只表示“可以访问”，不表示地址 0 已经有完整图像。
// 在第一次 frame_write_finish 之前把背景像素压黑；完成信号同步到
// video_clk 域后，仅在 VS 上升沿放行，保证不会在一帧中途切换。
//====================================================================
`timescale 1ns/1ps

module video_first_frame_gate (
    input  wire        mem_clk,
    input  wire        rst_mem,
    input  wire        frame_write_finish,
    input  wire        video_clk,
    input  wire        rst_video,
    input  wire        video_vs,
    input  wire [23:0] data_i,
    output wire [23:0] data_o,
    output wire        frame_ready
);
    reg ready_mem;
    reg ready_s0, ready_s1;
    reg vs_d;
    reg ready_frame;

    // 一旦首帧完整写入便保持有效，直到系统重新复位。
    always @(posedge mem_clk or posedge rst_mem) begin
        if (rst_mem)
            ready_mem <= 1'b0;
        else if (frame_write_finish)
            ready_mem <= 1'b1;
    end

    // 单比特电平跨域同步。
    always @(posedge video_clk or posedge rst_video) begin
        if (rst_video) begin
            ready_s0 <= 1'b0;
            ready_s1 <= 1'b0;
        end
        else begin
            ready_s0 <= ready_mem;
            ready_s1 <= ready_s0;
        end
    end

    // 只在新视频帧边界放行，避免一帧上半部黑、下半部为图像。
    always @(posedge video_clk or posedge rst_video) begin
        if (rst_video) begin
            vs_d        <= 1'b0;
            ready_frame <= 1'b0;
        end
        else begin
            vs_d <= video_vs;
            if (video_vs && !vs_d && ready_s1)
                ready_frame <= 1'b1;
        end
    end

    assign frame_ready = ready_frame;
    assign data_o = ready_frame ? data_i : 24'h000000;

endmodule
