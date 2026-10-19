//====================================================================
// welcome_mosaic.v -- 迎新照片 16x16 流式马赛克
//
// 设计边界:
//   * 插在原始背景与 OSD 之间，只处理照片；字幕/HUD 保持清晰。
//   * 每个 16x16 块取左上角像素并量化为 RGB565 作为块颜色。每个块行只缓存 40 个样本，
//     不增加帧缓存，也不改变 SDRAM 读写协议。
//   * enable_req 两级同步后，仅在一帧第一个有效像素原子提交，防止半屏切换。
//   * 关闭时 BRAM 完全不读写，数据路径逐拍透传；开启时 BRAM 每 16 个像素
//     才读一次，每 16 行才写一行，体现 FPGA 的并行流处理与低活动率特点。
//
// 固定输入规格 640x480；横向 640/16=40 块，使用一片 9K BRAM 的小部分。
// 整体固定延迟 2 个 video_clk，hs/vs/de/坐标与像素同步延迟；第二拍用于
// 对齐 BRAM 同步读数据，避免块边界首像素错用上一块颜色。
//====================================================================
`timescale 1ns/1ps

module welcome_mosaic #(
    parameter DATA_W = 24
)(
    input                   video_clk,
    input                   rst,
    input                   enable_req,
    input                   hs_i,
    input                   vs_i,
    input                   de_i,
    input      [DATA_W-1:0] data_i,
    input      [11:0]       px_x,
    input      [11:0]       px_y,
    output reg              hs_o,
    output reg              vs_o,
    output reg              de_o,
    output reg [DATA_W-1:0] data_o,
    output reg [11:0]       px_x_o,
    output reg [11:0]       px_y_o
);

    reg en_s0, en_s1, en_frame;
    wire frame_first = de_i && (px_x == 12'd0) && (px_y == 12'd0);
    wire en_input = frame_first ? en_s1 : en_frame;
    wire top_block_row = (px_y[3:0] == 4'd0);
    wire block_first   = (px_x[3:0] == 4'd0);
    wire sample_wr = en_input && de_i &&  top_block_row && block_first;
    wire sample_rd = en_input && de_i && ~top_block_row && block_first;
    wire [5:0] block_col = px_x[9:4];

    wire [15:0] pixel565 = {data_i[23:19],data_i[15:10],data_i[7:3]};
    wire [15:0] sample_q;
    reg  [15:0] top_row_hold;
    reg         hs1,vs1,de1;
    reg  [23:0] data1;
    reg  [11:0] x1,y1;

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(8),  .ADDR_WIDTH_B(8),
        .DATA_DEPTH_A(256),.DATA_DEPTH_B(256),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K")
    ) u_mosaic_line (
        .doa(), .dob(sample_q),
        .dia(pixel565), .dib(16'd0),
        .cea(sample_wr), .ocea(1'b1), .clka(video_clk), .wea(sample_wr),
        .rsta(1'b0), .bea(1'b0),
        .ceb(sample_rd), .oceb(1'b1), .clkb(video_clk), .web(1'b0),
        .rstb(1'b0), .beb(1'b0),
        .addra({2'b0,block_col}), .addrb({2'b0,block_col})
    );

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            en_s0        <= 1'b0;
            en_s1        <= 1'b0;
            en_frame     <= 1'b0;
            top_row_hold <= 16'd0;
            hs1          <= 1'b0;
            vs1          <= 1'b0;
            de1          <= 1'b0;
            data1        <= 24'd0;
            x1           <= 12'd0;
            y1           <= 12'd0;
            hs_o         <= 1'b0;
            vs_o         <= 1'b0;
            de_o         <= 1'b0;
            data_o       <= {DATA_W{1'b0}};
            px_x_o       <= 12'd0;
            px_y_o       <= 12'd0;
        end else begin
            en_s0 <= enable_req;
            en_s1 <= en_s0;
            if (frame_first)
                en_frame <= en_s1;
            if (sample_wr)
                top_row_hold <= pixel565;

            hs1   <= hs_i;
            vs1   <= vs_i;
            de1   <= de_i;
            data1 <= data_i;
            x1    <= px_x;
            y1    <= px_y;

            hs_o   <= hs1;
            vs_o   <= vs1;
            de_o   <= de1;
            px_x_o <= x1;
            px_y_o <= y1;

            if (!de1)
                data_o <= data1;
            else if (!en_frame)
                data_o <= data1;
            else if (y1[3:0] == 4'd0)
                data_o <= rgb565_to_888((x1[3:0] == 4'd0) ?
                                        {data1[23:19],data1[15:10],data1[7:3]} : top_row_hold);
            else
                data_o <= rgb565_to_888(sample_q);
        end
    end

    // 位复制扩展比乘法缩放更省逻辑，同时覆盖 0..255 全范围。
    function [23:0] rgb565_to_888;
        input [15:0] c;
        begin
            rgb565_to_888 = {{c[15:11],c[15:13]},
                             {c[10:5], c[10:9]},
                             {c[4:0],  c[4:2]}};
        end
    endfunction

endmodule
