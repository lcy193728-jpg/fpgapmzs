`timescale 1ns/1ps

module hdmi_audio_sample_packetizer (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_valid,
    output wire               sample_ready,
    input  wire signed [15:0] sample_left,
    input  wire signed [15:0] sample_right,
    output reg                packet_valid,
    input  wire               packet_ready,
    output reg  [23:0]        packet_header,
    output wire [7:0]         packet_header_ecc,
    output reg  [223:0]       packet_body,
    output wire [31:0]        packet_body_ecc,
    output reg  [7:0]         packet_frame_base
);
    reg [1:0] collect_count;
    reg [7:0] next_audio_frame_base;
    reg signed [15:0] left0, left1, left2;
    reg signed [15:0] right0, right1, right2;
    wire [7:0] ecc0, ecc1, ecc2, ecc3;

    assign sample_ready = !packet_valid;

    function [55:0] make_subpacket;
        input signed [15:0] left_sample;
        input signed [15:0] right_sample;
        input [7:0] frame_index;
        reg [23:0] left_word;
        reg [23:0] right_word;
        reg channel_status;
        reg left_parity;
        reg right_parity;
        begin
            // 16-bit LPCM is left-justified in the 24-bit IEC 60958 sample
            // word. C[25]=1 declares 48 kHz and C[33]=1 declares 16-bit;
            // all other bits in this minimal consumer status block are zero.
            left_word = {left_sample, 8'h00};
            right_word = {right_sample, 8'h00};
            channel_status = (frame_index == 8'd25) ||
                             (frame_index == 8'd33);
            left_parity = ^{left_word, channel_status};
            right_parity = ^{right_word, channel_status};
            make_subpacket[7:0] = left_word[7:0];
            make_subpacket[15:8] = left_word[15:8];
            make_subpacket[23:16] = left_word[23:16];
            make_subpacket[31:24] = right_word[7:0];
            make_subpacket[39:32] = right_word[15:8];
            make_subpacket[47:40] = right_word[23:16];
            // Control nibble order is P/C/U/V for right then left.
            make_subpacket[55:48] =
                {right_parity, channel_status, 2'b00,
                 left_parity, channel_status, 2'b00};
        end
    endfunction

    hdmi_bch8 #(.DATA_BYTES(3)) u_header_bch (
        .data(packet_header), .ecc(packet_header_ecc)
    );
    hdmi_bch8 #(.DATA_BYTES(7)) u_body0_bch (
        .data(packet_body[55:0]), .ecc(ecc0)
    );
    hdmi_bch8 #(.DATA_BYTES(7)) u_body1_bch (
        .data(packet_body[111:56]), .ecc(ecc1)
    );
    hdmi_bch8 #(.DATA_BYTES(7)) u_body2_bch (
        .data(packet_body[167:112]), .ecc(ecc2)
    );
    hdmi_bch8 #(.DATA_BYTES(7)) u_body3_bch (
        .data(packet_body[223:168]), .ecc(ecc3)
    );
    assign packet_body_ecc = {ecc3, ecc2, ecc1, ecc0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            collect_count <= 2'd0;
            packet_valid <= 1'b0;
            packet_header <= 24'd0;
            packet_body <= 224'd0;
            packet_frame_base <= 8'd0;
            next_audio_frame_base <= 8'd0;
            left0 <= 16'sd0;
            left1 <= 16'sd0;
            left2 <= 16'sd0;
            right0 <= 16'sd0;
            right1 <= 16'sd0;
            right2 <= 16'sd0;
        end else if (packet_valid) begin
            if (packet_ready)
                packet_valid <= 1'b0;
        end else if (sample_valid) begin
            case (collect_count)
                2'd0: begin
                    left0 <= sample_left;
                    right0 <= sample_right;
                    collect_count <= 2'd1;
                end
                2'd1: begin
                    left1 <= sample_left;
                    right1 <= sample_right;
                    collect_count <= 2'd2;
                end
                2'd2: begin
                    left2 <= sample_left;
                    right2 <= sample_right;
                    collect_count <= 2'd3;
                end
                default: begin
                    // Low byte is HB0. Layout=0 and all four subpackets are
                    // present. HB2.B0 marks the first IEC status block frame.
                    packet_header <=
                                      {(next_audio_frame_base == 0) ?
                                            8'h10 : 8'h00,
                                       8'h0f, 8'h02};
                    packet_body <= {
                        make_subpacket(sample_left, sample_right,
                                       next_audio_frame_base + 8'd3),
                        make_subpacket(left2, right2,
                                       next_audio_frame_base + 8'd2),
                        make_subpacket(left1, right1,
                                       next_audio_frame_base + 8'd1),
                        make_subpacket(left0, right0,
                                       next_audio_frame_base)
                    };
                    packet_frame_base <= next_audio_frame_base;
                    packet_valid <= 1'b1;
                    collect_count <= 2'd0;
                    if (next_audio_frame_base == 8'd188)
                        next_audio_frame_base <= 8'd0;
                    else
                        next_audio_frame_base <=
                            next_audio_frame_base + 8'd4;
                end
            endcase
        end
    end
endmodule
