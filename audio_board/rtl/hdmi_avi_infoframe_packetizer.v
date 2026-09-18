`timescale 1ns/1ps
// AVI v2: RGB, full range, 4:3, VIC=0 (25 MHz is a nonstandard VGA rate).
// HB={0x82,2,13}; PB={checksum 0x57,0,0x10,0x08,0,...}.
module hdmi_avi_infoframe_packetizer(
    input wire clk,rst_n,emit,
    output reg packet_valid,
    input wire packet_ready,
    output wire [23:0] packet_header,
    output wire [7:0] packet_header_ecc,
    output wire [223:0] packet_body,
    output wire [31:0] packet_body_ecc
);
    assign packet_header=24'h0d0282;
    assign packet_body={192'd0,8'h08,8'h10,8'h00,8'h57};
    // 0x82+0x02+0x0d+0x10+0x08+0x57=0x100: checksum is 0x57.
    wire [7:0] e0,e1,e2,e3;
    hdmi_bch8 #(.DATA_BYTES(3)) eh(.data(packet_header),.ecc(packet_header_ecc));
    hdmi_bch8 #(.DATA_BYTES(7)) eb0(.data(packet_body[55:0]),.ecc(e0));
    hdmi_bch8 #(.DATA_BYTES(7)) eb1(.data(packet_body[111:56]),.ecc(e1));
    hdmi_bch8 #(.DATA_BYTES(7)) eb2(.data(packet_body[167:112]),.ecc(e2));
    hdmi_bch8 #(.DATA_BYTES(7)) eb3(.data(packet_body[223:168]),.ecc(e3));
    assign packet_body_ecc={e3,e2,e1,e0};
    always @(posedge clk or negedge rst_n)
        if(!rst_n) packet_valid<=0;
        else if(packet_valid && packet_ready) packet_valid<=0;
        else if(emit) packet_valid<=1;
endmodule
