`timescale 1ns/1ps

// Emergency subtype selector and elapsed timer.
// 2026-09-21 改版(用户要求): 场景四不再占用 KEY4, 四类应急告警改由
//   KEY1 = 选择(循环 0火灾→1地震→2恶劣天气→3疏散→0)
//   KEY2 = 减(上一类, 环绕)
//   KEY3 = 加(下一类, 环绕)
// 按键含义仅在 alarm_en(应急场景)期间有效; 顶层在 alarm_en 时把 KEY1~KEY3
// 从 ui_key_ctrl 上"截走"(门控), 避免同一按键既选告警又调亮度/缩放, 见
// top_final.v 的 ui_key1/key2/key3 门控注释。
// 输入电平: 上拉高、按下低。
module emergency_alarm_ctrl #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer DEBOUNCE_CYCLES = 1_000_000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       alarm_en,
    input  wire       key1_raw,
    input  wire       key2_raw,
    input  wire       key3_raw,
    output reg  [1:0] alarm_type,
    output reg  [3:0] elapsed_m_tens,
    output reg  [3:0] elapsed_m_ones,
    output reg  [3:0] elapsed_s_tens,
    output reg  [3:0] elapsed_s_ones
);
    // ---- 三路独立消抖(KEY1 选择 / KEY2 减 / KEY3 加) ----
    wire k1_press, k2_press, k3_press;

    alarm_key_dbnc #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_dbnc_k1 (
        .clk(clk), .rst(rst), .key_raw(key1_raw), .key_press(k1_press));
    alarm_key_dbnc #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_dbnc_k2 (
        .clk(clk), .rst(rst), .key_raw(key2_raw), .key_press(k2_press));
    alarm_key_dbnc #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_dbnc_k3 (
        .clk(clk), .rst(rst), .key_raw(key3_raw), .key_press(k3_press));

    reg alarm_d;
    reg [26:0] second_count;

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
                // 进入应急场景: 默认火灾(0)并清零计时
                alarm_type <= 2'b00;
                second_count <= 27'd0;
                elapsed_m_tens <= 4'd0; elapsed_m_ones <= 4'd0;
                elapsed_s_tens <= 4'd0; elapsed_s_ones <= 4'd0;
            end else if (!alarm_en) begin
                second_count <= 27'd0;
            end else begin
                // KEY1 = 选择(顺序循环), KEY2 = 减, KEY3 = 加(均环绕)
                if (k1_press)      alarm_type <= alarm_type + 2'd1;
                else if (k2_press) alarm_type <= alarm_type - 2'd1;
                else if (k3_press) alarm_type <= alarm_type + 2'd1;

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

// 单键消抖: 两级同步 + 计数稳定 + 按下(下降沿)单周期脉冲
module alarm_key_dbnc #(
    parameter integer DEBOUNCE_CYCLES = 1_000_000
)(
    input  wire clk,
    input  wire rst,
    input  wire key_raw,
    output wire key_press
);
    reg key_meta, key_sync, key_stable, key_prev;
    reg [19:0] debounce_count;
    assign key_press = key_prev & ~key_stable;

    always @(posedge clk) begin
        if (rst) begin
            key_meta <= 1'b1; key_sync <= 1'b1;
            key_stable <= 1'b1; key_prev <= 1'b1;
            debounce_count <= 20'd0;
        end else begin
            key_meta <= key_raw;
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
endmodule
