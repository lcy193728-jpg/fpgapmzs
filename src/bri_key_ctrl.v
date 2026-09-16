//====================================================================
// 模块名 : bri_key_ctrl.v —— 显示亮度档按键控制器
// 功能   : 在 sd_card_clk(100MHz)域对板载 key2/key3 做
//          两级同步 + 20ms 计数器消抖, 提取"按下"下降沿脉冲:
//            key_up   (key2 按下) → bri_level +1(上限 15)
//            key_dn   (key3 按下) → bri_level -1(下限 0)
//          亮度档输出给 display_adjust(视频域两级同步后做亮度增益)。
//          bri_level 是纯寄存器电平, 不会给视频域带来毛刺。
// 约定     : 全项目按键统一"上拉高、按下拉低"、下降沿为触发。
//          场景选择仍由拨码 SW 承担, 本模块只管亮度档。
// 语言     : 纯 Verilog-2001。
//====================================================================

`timescale 1ns/1ps

module bri_key_ctrl #(
    parameter [3:0] INIT = 4'd8,       // 默认档(×1.0)
    parameter [3:0] MAX  = 4'd15,
    parameter [3:0] MIN  = 4'd0
)(
    input               clk,           // sd_card_clk(100MHz)
    input               rst,           // 高有效复位
    input               key_up,        // key2 原始电平(上拉高/按下低)
    input               key_dn,        // key3 原始电平
    output reg  [3:0]   bri_level      // 亮度档 0..15
);

    wire up_p, dn_p;

    key_dbnc #(.DEB_MAX(21'd2_000_000)) u_up (
        .clk      (clk),
        .rst      (rst),
        .key_raw  (key_up),
        .press_pl (up_p)
    );
    key_dbnc #(.DEB_MAX(21'd2_000_000)) u_dn (
        .clk      (clk),
        .rst      (rst),
        .key_raw  (key_dn),
        .press_pl (dn_p)
    );

    always @(posedge clk or posedge rst) begin
        if (rst)
            bri_level <= INIT;
        else if (up_p && (bri_level < MAX))
            bri_level <= bri_level + 4'd1;
        else if (dn_p && (bri_level > MIN))
            bri_level <= bri_level - 4'd1;
    end

endmodule


//====================================================================
// 子模块 : key_dbnc —— 机械按键 20ms 消抖(两级同步 + 计数器)
// 输入原始电平(上拉高), 输出按下(下降沿)单周期脉冲
//====================================================================
module key_dbnc #(
    parameter [20:0] DEB_MAX = 21'd2_000_000   // 20ms@100MHz
)(
    input               clk,
    input               rst,            // 高有效复位
    input               key_raw,        // 原始电平(1=释放/高, 0=按下/低)
    output reg          press_pl        // 稳定后按下下降沿脉冲(1 拍)
);

    reg [1:0]   key_sync;   // 两级同步器
    reg [20:0]  cnt;        // 稳定计时
    reg         level;      // 消抖后电平(1=高/释放)
    reg         level_d;    // 电平打拍(边沿)

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key_sync <= 2'b11;
            cnt      <= 21'd0;
            level    <= 1'b1;
            level_d  <= 1'b1;
            press_pl <= 1'b0;
        end
        else begin
            key_sync <= {key_sync[0], key_raw};         // 两级同步
            if (key_sync[1] != key_sync[0])
                cnt <= 21'd0;                            // 输入变化重计
            else if (cnt == DEB_MAX) begin
                level <= key_sync[1];                    // 稳定 20ms 更新
                cnt   <= cnt;                            // 保持
            end
            else
                cnt <= cnt + 21'd1;

            level_d  <= level;
            press_pl <= level_d & ~level;               // 下降沿(按下)
        end
    end

endmodule
