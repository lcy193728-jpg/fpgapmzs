`timescale 1ns/1ps

module pcm_test_tone #(
    parameter integer SAMPLE_DIV = 1000
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enable,
    output reg                sample_valid,
    input  wire               sample_ready,
    output reg signed [15:0]  sample_left,
    output reg signed [15:0]  sample_right,
    output reg  [3:0]         rom_index,
    output wire               sample_accepted
);
    localparam integer DIV_WIDTH = (SAMPLE_DIV <= 2) ? 1 : $clog2(SAMPLE_DIV);
    reg [DIV_WIDTH-1:0] div_count;

    assign sample_accepted = sample_valid && sample_ready;

    function signed [15:0] sine_sample;
        input [3:0] index;
        begin
            case (index)
                4'd0: sine_sample = 16'sd0;
                4'd1: sine_sample = 16'sd4592;
                4'd2: sine_sample = 16'sd8485;
                4'd3: sine_sample = 16'sd11087;
                4'd4: sine_sample = 16'sd12000;
                4'd5: sine_sample = 16'sd11087;
                4'd6: sine_sample = 16'sd8485;
                4'd7: sine_sample = 16'sd4592;
                4'd8: sine_sample = 16'sd0;
                4'd9: sine_sample = -16'sd4592;
                4'd10: sine_sample = -16'sd8485;
                4'd11: sine_sample = -16'sd11087;
                4'd12: sine_sample = -16'sd12000;
                4'd13: sine_sample = -16'sd11087;
                4'd14: sine_sample = -16'sd8485;
                default: sine_sample = -16'sd4592;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_valid <= 1'b0;
            sample_left <= 16'sd0;
            sample_right <= 16'sd0;
            rom_index <= 4'd0;
            div_count <= {DIV_WIDTH{1'b0}};
        end else if (!enable) begin
            sample_valid <= 1'b0;
            rom_index <= 4'd0;
            div_count <= {DIV_WIDTH{1'b0}};
        end else begin
            if (div_count == SAMPLE_DIV-1)
                div_count <= {DIV_WIDTH{1'b0}};
            else
                div_count <= div_count + 1'b1;

            if (sample_accepted) begin
                sample_valid <= 1'b0;
                rom_index <= rom_index + 1'b1;
            end

            if (!sample_valid && div_count == SAMPLE_DIV-1) begin
                sample_left <= sine_sample(rom_index);
                sample_right <= sine_sample(rom_index);
                sample_valid <= 1'b1;
            end
        end
    end
endmodule
