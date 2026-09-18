`timescale 1ns/1ps

module hdmi_audio_acr_packetizer #(
    parameter integer INTERVAL_CYCLES = 25000,
    parameter [19:0] ACR_N = 20'd6144,
    parameter [19:0] ACR_CTS = 20'd25000
) (
    input  wire         clk,
    input  wire         rst_n,
    output reg          packet_valid,
    input  wire         packet_ready,
    output wire [23:0]  packet_header,
    output wire [7:0]   packet_header_ecc,
    output wire [223:0] packet_body,
    output wire [31:0]  packet_body_ecc
);
    localparam integer COUNT_WIDTH =
        (INTERVAL_CYCLES <= 2) ? 1 : $clog2(INTERVAL_CYCLES);
    reg [COUNT_WIDTH-1:0] interval_count;
    wire [55:0] acr_subpacket;
    wire [7:0] ecc0, ecc1, ecc2, ecc3;

    assign packet_header = 24'h000001;
    assign acr_subpacket = {
        8'h00,
        ACR_N[7:0],
        ACR_N[15:8],
        {4'h0, ACR_N[19:16]},
        ACR_CTS[7:0],
        ACR_CTS[15:8],
        {4'h0, ACR_CTS[19:16]}
    };
    assign packet_body = {acr_subpacket, acr_subpacket,
                          acr_subpacket, acr_subpacket};

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
            interval_count <= {COUNT_WIDTH{1'b0}};
            packet_valid <= 1'b0;
        end else begin
            if (packet_valid) begin
                if (packet_ready)
                    packet_valid <= 1'b0;
            end else if (interval_count == INTERVAL_CYCLES-1) begin
                interval_count <= {COUNT_WIDTH{1'b0}};
                packet_valid <= 1'b1;
            end else begin
                interval_count <= interval_count + 1'b1;
            end
        end
    end
endmodule
