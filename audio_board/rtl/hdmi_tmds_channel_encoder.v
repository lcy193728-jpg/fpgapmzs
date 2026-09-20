`timescale 1ns/1ps

module hdmi_tmds_channel_encoder #(
    parameter integer CHANNEL = 0
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] mode,
    input  wire [7:0] video_data,
    input  wire [3:0] data_island_data,
    input  wire [1:0] control_data,
    output reg  [9:0] symbol
);
    localparam [2:0] MODE_VIDEO       = 3'd1;
    localparam [2:0] MODE_VIDEO_GUARD = 3'd2;
    localparam [2:0] MODE_DATA_ISLAND = 3'd3;
    localparam [2:0] MODE_DATA_GUARD  = 3'd4;

    reg signed [5:0] disparity;
    reg signed [5:0] next_disparity;
    reg [8:0] q_m;
    reg [9:0] video_symbol;
    reg [3:0] data_ones;
    reg [3:0] q_m_ones;
    reg signed [5:0] balance;
    reg use_xnor;
    integer index;

    wire [9:0] terc4_symbol;
    hdmi_terc4_encoder u_terc4 (
        .data(data_island_data),
        .symbol(terc4_symbol)
    );

    always @* begin
        data_ones = 4'd0;
        for (index = 0; index < 8; index = index + 1)
            data_ones = data_ones + video_data[index];

        use_xnor = data_ones > 4 ||
                   (data_ones == 4 && video_data[0] == 1'b0);
        q_m[0] = video_data[0];
        for (index = 1; index < 8; index = index + 1) begin
            if (use_xnor)
                q_m[index] = q_m[index - 1] ~^ video_data[index];
            else
                q_m[index] = q_m[index - 1] ^ video_data[index];
        end
        q_m[8] = !use_xnor;

        q_m_ones = 4'd0;
        for (index = 0; index < 8; index = index + 1)
            q_m_ones = q_m_ones + q_m[index];
        balance = $signed({1'b0, q_m_ones, 1'b0}) - 6'sd8;

        if (disparity == 0 || balance == 0) begin
            video_symbol[9] = !q_m[8];
            video_symbol[8] = q_m[8];
            video_symbol[7:0] = q_m[8] ? q_m[7:0] : ~q_m[7:0];
            next_disparity = q_m[8] ? disparity + balance :
                                     disparity - balance;
        end else if ((disparity > 0 && balance > 0) ||
                     (disparity < 0 && balance < 0)) begin
            video_symbol = {1'b1, q_m[8], ~q_m[7:0]};
            next_disparity = disparity - balance +
                             (q_m[8] ? 6'sd2 : 6'sd0);
        end else begin
            video_symbol = {1'b0, q_m[8], q_m[7:0]};
            next_disparity = disparity + balance -
                             (q_m[8] ? 6'sd0 : 6'sd2);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            symbol <= 10'b1101010100;
            disparity <= 6'sd0;
        end else begin
            case (mode)
                MODE_VIDEO: begin
                    symbol <= video_symbol;
                    disparity <= next_disparity;
                end
                MODE_VIDEO_GUARD: begin
                    symbol <= (CHANNEL == 1) ? 10'b0100110011 :
                                               10'b1011001100;
                    disparity <= 6'sd0;
                end
                MODE_DATA_ISLAND: begin
                    symbol <= terc4_symbol;
                    disparity <= 6'sd0;
                end
                MODE_DATA_GUARD: begin
                    if (CHANNEL == 0)
                        case (control_data)
                            2'b00: symbol <= 10'b1010001110;
                            2'b01: symbol <= 10'b1001110001;
                            2'b10: symbol <= 10'b0101100011;
                            default: symbol <= 10'b1011000011;
                        endcase
                    else
                        symbol <= 10'b0100110011;
                    disparity <= 6'sd0;
                end
                default: begin
                    case (control_data)
                        2'b00: symbol <= 10'b1101010100;
                        2'b01: symbol <= 10'b0010101011;
                        2'b10: symbol <= 10'b0101010100;
                        default: symbol <= 10'b1010101011;
                    endcase
                    disparity <= 6'sd0;
                end
            endcase
        end
    end
endmodule
