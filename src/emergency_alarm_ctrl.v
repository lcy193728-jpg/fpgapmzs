`timescale 1ns/1ps

// Emergency subtype selector and elapsed timer.
// KEY4 is unused by the existing UI, so it is dedicated to alarm selection
// only while the emergency scene is active. Inputs are active low.
module emergency_alarm_ctrl #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer DEBOUNCE_CYCLES = 1_000_000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       alarm_en,
    input  wire       key4_raw,
    output reg  [1:0] alarm_type,
    output reg  [3:0] elapsed_m_tens,
    output reg  [3:0] elapsed_m_ones,
    output reg  [3:0] elapsed_s_tens,
    output reg  [3:0] elapsed_s_ones
);
    reg key_meta, key_sync, key_stable, key_prev;
    reg [19:0] debounce_count;
    reg alarm_d;
    reg [26:0] second_count;
    wire key_press = key_prev & ~key_stable;

    always @(posedge clk) begin
        if (rst) begin
            key_meta <= 1'b1; key_sync <= 1'b1;
            key_stable <= 1'b1; key_prev <= 1'b1;
            debounce_count <= 20'd0;
        end else begin
            key_meta <= key4_raw;
            key_sync <= key_meta;
            if (key_sync == key_stable) begin
                debounce_count <= 20'd0;
            end else if (debounce_count == DEBOUNCE_CYCLES-1) begin
                key_stable <= key_sync;
                debounce_count <= 20'd0;
            end else begin
                debounce_count <= debounce_count + 1'b1;
            end
            key_prev <= key_stable;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            alarm_type <= 2'b00;
            alarm_d <= 1'b0;
            second_count <= 27'd0;
            elapsed_m_tens <= 4'd0; elapsed_m_ones <= 4'd0;
            elapsed_s_tens <= 4'd0; elapsed_s_ones <= 4'd0;
        end else begin
            alarm_d <= alarm_en;
            if (alarm_en && !alarm_d) begin
                alarm_type <= 2'b00;
                second_count <= 27'd0;
                elapsed_m_tens <= 4'd0; elapsed_m_ones <= 4'd0;
                elapsed_s_tens <= 4'd0; elapsed_s_ones <= 4'd0;
            end else if (!alarm_en) begin
                second_count <= 27'd0;
            end else begin
                if (key_press)
                    alarm_type <= alarm_type + 2'd1;
                if (second_count == CLK_HZ-1) begin
                    second_count <= 27'd0;
                    if (elapsed_s_ones == 4'd9) begin
                        elapsed_s_ones <= 4'd0;
                        if (elapsed_s_tens == 4'd5) begin
                            elapsed_s_tens <= 4'd0;
                            if (elapsed_m_ones == 4'd9) begin
                                elapsed_m_ones <= 4'd0;
                                if (elapsed_m_tens != 4'd9)
                                    elapsed_m_tens <= elapsed_m_tens + 1'b1;
                            end else elapsed_m_ones <= elapsed_m_ones + 1'b1;
                        end else elapsed_s_tens <= elapsed_s_tens + 1'b1;
                    end else elapsed_s_ones <= elapsed_s_ones + 1'b1;
                end else second_count <= second_count + 1'b1;
            end
        end
    end
endmodule
