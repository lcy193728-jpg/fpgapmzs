`timescale 1ns/1ps

module hdmi_audio_packet_scheduler (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         acr_valid,
    output wire         acr_ready,
    input  wire [23:0]  acr_header,
    input  wire [7:0]   acr_header_ecc,
    input  wire [223:0] acr_body,
    input  wire [31:0]  acr_body_ecc,
    input  wire         info_valid,
    output wire         info_ready,
    input  wire [23:0]  info_header,
    input  wire [7:0]   info_header_ecc,
    input  wire [223:0] info_body,
    input  wire [31:0]  info_body_ecc,
    input  wire         audio_valid,
    output wire         audio_ready,
    input  wire [23:0]  audio_header,
    input  wire [7:0]   audio_header_ecc,
    input  wire [223:0] audio_body,
    input  wire [31:0]  audio_body_ecc,
    output wire         packet_valid,
    input  wire         packet_lock,
    input  wire         packet_ready,
    output reg  [1:0]   packet_source,
    output reg  [23:0]  packet_header,
    output reg  [7:0]   packet_header_ecc,
    output reg  [223:0] packet_body,
    output reg  [31:0]  packet_body_ecc
);
    reg locked;
    reg [1:0] locked_source;
    wire [1:0] selected_source = locked ? locked_source :
                                      acr_valid ? 2'd0 :
                                      info_valid ? 2'd1 : 2'd2;

    assign packet_valid = locked ?
                          ((locked_source == 2'd0) ? acr_valid :
                           (locked_source == 2'd1) ? info_valid : audio_valid) :
                          (acr_valid || info_valid || audio_valid);
    assign acr_ready = packet_ready && packet_valid &&
                       selected_source == 2'd0;
    assign info_ready = packet_ready && packet_valid &&
                        selected_source == 2'd1;
    assign audio_ready = packet_ready && packet_valid &&
                         selected_source == 2'd2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            locked <= 1'b0;
            locked_source <= 2'd0;
        end else if (locked) begin
            if (packet_ready || !packet_valid)
                locked <= 1'b0;
        end else if (packet_lock &&
                     (acr_valid || info_valid || audio_valid)) begin
            if (!(packet_ready && packet_valid)) begin
                locked <= 1'b1;
                locked_source <= acr_valid ? 2'd0 :
                                 info_valid ? 2'd1 : 2'd2;
            end
        end
    end

    always @* begin
        packet_source = 2'd0;
        packet_header = 24'd0;
        packet_header_ecc = 8'd0;
        packet_body = 224'd0;
        packet_body_ecc = 32'd0;
        if (selected_source == 2'd0 && acr_valid) begin
            packet_source = 2'd0;
            packet_header = acr_header;
            packet_header_ecc = acr_header_ecc;
            packet_body = acr_body;
            packet_body_ecc = acr_body_ecc;
        end else if (selected_source == 2'd1 && info_valid) begin
            packet_source = 2'd1;
            packet_header = info_header;
            packet_header_ecc = info_header_ecc;
            packet_body = info_body;
            packet_body_ecc = info_body_ecc;
        end else if (selected_source == 2'd2 && audio_valid) begin
            packet_source = 2'd2;
            packet_header = audio_header;
            packet_header_ecc = audio_header_ecc;
            packet_body = audio_body;
            packet_body_ecc = audio_body_ecc;
        end
    end
endmodule
