`timescale 1ns/1ps

// M06-owned boundary used by the current player project.
// The media-specific source may change its melody, volume or content policy,
// but it must present the frozen PCM valid/ready contract to M07.
module m06_pcm_contract_adapter (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               source_valid,
    output wire               source_ready,
    input  wire signed [15:0] source_left,
    input  wire signed [15:0] source_right,
    output wire               pcm_valid,
    input  wire               pcm_ready,
    output wire signed [15:0] pcm_left,
    output wire signed [15:0] pcm_right,
    output reg                contract_error
);
    reg hold_active;
    reg signed [15:0] held_left;
    reg signed [15:0] held_right;

    assign source_ready = pcm_ready;
    assign pcm_valid = source_valid;
    assign pcm_left = source_left;
    assign pcm_right = source_right;

    // A producer must keep both channels stable while valid is asserted and
    // ready is low. This is the M06 contract that M07 consumes.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_active <= 1'b0;
            held_left <= 16'sd0;
            held_right <= 16'sd0;
            contract_error <= 1'b0;
        end else if (source_valid && !source_ready) begin
            if (hold_active &&
                (source_left !== held_left || source_right !== held_right))
                contract_error <= 1'b1;
            if (!hold_active) begin
                held_left <= source_left;
                held_right <= source_right;
                hold_active <= 1'b1;
            end
        end else begin
            hold_active <= 1'b0;
        end
    end
endmodule
