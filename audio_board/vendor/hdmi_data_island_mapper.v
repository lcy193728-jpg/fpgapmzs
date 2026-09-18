`timescale 1ns/1ps

module hdmi_data_island_mapper (
    input  wire [4:0]   pixel_index,
    input  wire         hsync,
    input  wire         vsync,
    input  wire [23:0]  packet_header,
    input  wire [7:0]   packet_header_ecc,
    input  wire [223:0] packet_body,
    input  wire [31:0]  packet_body_ecc,
    output wire [3:0]   channel0_terc4,
    output wire [3:0]   channel1_terc4,
    output wire [3:0]   channel2_terc4
);
    wire [31:0] header_block;
    wire [63:0] body_block0;
    wire [63:0] body_block1;
    wire [63:0] body_block2;
    wire [63:0] body_block3;
    wire [5:0] even_bit;
    wire [5:0] odd_bit;

    assign header_block = {packet_header_ecc, packet_header};
    assign body_block0 = {packet_body_ecc[7:0], packet_body[55:0]};
    assign body_block1 = {packet_body_ecc[15:8], packet_body[111:56]};
    assign body_block2 = {packet_body_ecc[23:16], packet_body[167:112]};
    assign body_block3 = {packet_body_ecc[31:24], packet_body[223:168]};
    assign even_bit = {pixel_index, 1'b0};
    assign odd_bit = {pixel_index, 1'b1};

    // D3 is the allowed packet-sync don't-care value, held at one for a
    // deterministic stream. D2 carries the header BCH block; D1/D0 carry
    // VSYNC/HSYNC throughout the Data Island and its guard bands.
    assign channel0_terc4 = {1'b1, header_block[pixel_index], vsync, hsync};
    assign channel1_terc4 = {
        body_block3[even_bit], body_block2[even_bit],
        body_block1[even_bit], body_block0[even_bit]
    };
    assign channel2_terc4 = {
        body_block3[odd_bit], body_block2[odd_bit],
        body_block1[odd_bit], body_block0[odd_bit]
    };
endmodule
