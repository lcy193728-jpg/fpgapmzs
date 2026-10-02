`timescale 1ns/1ps

// Emergency elapsed timer (2026-10-01 改版, 用户要求).
//   原版: 本模块自带 KEY1/KEY2/KEY3 三路消抖, 在应急场景内选四类告警
//         (KEY1=顺序循环 / KEY2=减 / KEY3=加)。
//   改版: 四类告警的类型选择已**统一到全局 ui_key_ctrl** —— 应急场景下按键
//         语义与迎新场景完全一致(KEY1 调模式, KEY2/3 调参数), 其中模式0 =
//         告警类型环绕切换。因此本模块**退化为纯计时器**:
//     · 仅保留 alarm_en 期间的 1Hz BCD 秒/分累加;
//     · 复位清零; 进入应急场景(上升沿)清零; 离开场景(alarm_en=0)停止计数
//       并保留最后显示值 —— 因为应急画面只在 alarm_en 期间绘制, 且下次进入
//       会立刻归零, 所以每次进入应急都从 00:00 起算。
//   输出 elapsed_* 送 emergency_multi_overlay 的右上「持续时间 MM:SS」区。
module emergency_alarm_ctrl #(
    parameter integer CLK_HZ = 100_000_000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       alarm_en,
    output reg  [3:0] elapsed_m_tens,
    output reg  [3:0] elapsed_m_ones,
    output reg  [3:0] elapsed_s_tens,
    output reg  [3:0] elapsed_s_ones
);
    reg alarm_d;
    reg [26:0] second_count;

    always @(posedge clk) begin
        if (rst) begin
            alarm_d <= 1'b0;
            second_count <= 27'd0;
            elapsed_m_tens <= 4'd0; elapsed_m_ones <= 4'd0;
            elapsed_s_tens <= 4'd0; elapsed_s_ones <= 4'd0;
        end else begin
            alarm_d <= alarm_en;
            if (alarm_en && !alarm_d) begin
                // 进入应急场景: 清零计时
                second_count <= 27'd0;
                elapsed_m_tens <= 4'd0; elapsed_m_ones <= 4'd0;
                elapsed_s_tens <= 4'd0; elapsed_s_ones <= 4'd0;
            end else if (!alarm_en) begin
                second_count <= 27'd0;
            end else begin
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
