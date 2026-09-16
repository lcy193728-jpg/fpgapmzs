//====================================================================
// 模块名 : ui_key_ctrl.v —— 全局统一人机交互控制器(2026-09-16 改版)
//
// 设计目标(全局统一样式, 与场景完全解耦: 四个场景下按键含义一致):
//   KEY1(A2) : 功能模式循环, 每按一次 +1: 0图片/切图→1亮度→2缩放→0
//   KEY2(B2) : 当前模式参数 减
//   KEY3(B1) : 当前模式参数 加
//   KEY4(C1) : **已释放(不使用)** —— 原"自动↔手动"改由模式0统一承担
//
// 各模式参数语义:
//   模式0 图片/切图 : 参数 = 图序号(0=自动轮播, N=手动第 N 张)
//     · 刚进模式0(上电/切场景/从别的模式切回来)一律 = **自动轮播**
//     · 模式0 内按 KEY3 = **下一张**, 并顺带**转入手动单张**(停自动计时)
//     · 模式0 内按 KEY2 = **上一张**; 已在第 1 张时改为**回到自动轮播**
//     · 离开模式0(去亮度/缩放) = **自动回到自动轮播**(该模式下 KEY2/KEY3
//       去调参数, 不应把底层图片冻住)
//     ※ 与旧版的区别: 不再需要 KEY4 先"进手动" —— 切图动作本身就完成转手动,
//       彻底消除"屏上卡显示手动、按 KEY2/3 却在调亮度"的模式歧义。
//   模式1 亮度  : 参数 = 亮度档 0..15(KEY3 加 / KEY2 减), 默认 8 (=×1.0)
//   模式2 缩放  : 参数 = 缩放档 0..7, 默认 4 (=100% 原始比例)
//                 0/1/2/3/4/5/6/7 → 25%/33%/50%/67%/100%/150%/200%/300%
//                 (真实生效: 送 bmp_scale 双线性插值缩放引擎重采样后写帧缓存)
//                 档位变化时给出 res_chg_pl 脉冲 → 重载当前图, 效果立即可见
//
// 其它约定:
//   · 按键统一"上拉高、按下拉低", 本模块内部两级同步 + 10ms 计数器消抖,
//     取"按下(下降沿)"单周期脉冲, 保证一次按键只加/减 1。
//   · KEY1~KEY3 只调参数, 与场景无关(场景由板载拨码 SW 决定, 见
//     scene_control), 不会进入/退出场景, 也不会触发应急。
//   · 场景切换(scene_chg)时图片参数复位为"自动轮播", 避免新场景一进来
//     就停在手动冻结态。
//   · 时钟域: sd_card_clk(100MHz), 与 scene_control/bmp 控制域一致,
//     输出电平/脉冲直接可用, 无需跨域。
// 语言: 纯 Verilog-2001。
//====================================================================

`timescale 1ns/1ps

module ui_key_ctrl #(
    parameter [3:0] BRI_INIT = 4'd8,       // 亮度默认档(×1.0)
    parameter [3:0] BRI_MAX  = 4'd15,      // 亮度上限
    parameter [3:0] RES_INIT = 4'd4,       // 缩放默认档(4=100% 原始比例, 与原画一致)
    parameter [3:0] RES_MAX  = 4'd7,       // 缩放上限
    parameter [1:0] MODE_PIC = 2'd0,       // 功能模式: 图片
    parameter [1:0] MODE_BRI = 2'd1,       // 功能模式: 亮度
    parameter [1:0] MODE_RES = 2'd2        // 功能模式: 缩放
)(
    input               clk,               // sd_card_clk(100MHz)
    input               rst,               // 高有效复位
    // ---- 板载按键原始电平(上拉高、按下低) ----
    input               key1,              // 功能模式循环 0图片/切图→1亮度→2缩放→0
    input               key2,              // 当前模式参数 减
    input               key3,              // 当前模式参数 加
    // ---- 上下文 ----
    input       [7:0]   img_no,            // bmp_read_auto 当前图序号(1..N; 0=空闲)
    input               scene_chg,         // 场景切换脉冲(清手动→自动)
    // ---- 输出 ----
    output reg  [1:0]   mode,              // 功能模式 0图片/1亮度/2缩放
    output reg  [3:0]   bri_level,         // 亮度档 0..15(模式1可调)
    output reg  [3:0]   res_level,         // 缩放档 0..7(模式2可调)
    output reg          pic_manual,        // 1=手动单张(冻结自动轮播) / 0=自动轮播
    output      [7:0]   pic_param,         // 显示用图片参数: 0=轮播, >0=手动第N张
    output              key_next_pl,       // 手动"下一张"单周期脉冲
    output              key_prev_pl,       // 手动"上一张"单周期脉冲
    output              res_chg_pl         // 缩放档变化脉冲(1 拍) → 重载当前图
);

    //--------------------------------------------------------------
    // 按键消抖(两级同步 + 10ms 计数, 输出按下单周期脉冲)
    //   ※ KEY4 已释放: 不再例化对应消抖器(该键暂不参与逻辑)
    //--------------------------------------------------------------
    wire k1_p, k2_p, k3_p;

    ui_key_dbnc u_k1 (.clk(clk), .rst(rst), .key_raw(key1), .press_pl(k1_p));  // 模式循环
    ui_key_dbnc u_k2 (.clk(clk), .rst(rst), .key_raw(key2), .press_pl(k2_p));  // 参数 减
    ui_key_dbnc u_k3 (.clk(clk), .rst(rst), .key_raw(key3), .press_pl(k3_p));  // 参数 加

    //--------------------------------------------------------------
    // 图片模式脉冲判定(模式0 内始终有效, 无需先"进手动"):
    //   下一张: KEY3(模式0) —— 动作同时把 pic_manual 置 1(见下方 pic_manual 段)
    //   上一张: KEY2(模式0, 当前不是第 1 张)
    //   ※ 这样"图模式里 KEY2/KEY3 就是上一张/下一张", 不会与亮度/缩放混淆
    //     (亮度/缩放要求 mode=1/2, 与 mode=0 互斥)。
    //--------------------------------------------------------------
    reg  [7:0] img_no_l;                   // 图序号锁存(仅非 0 时更新, 防扫描期抖动)

    assign key_next_pl = k3_p & (mode == MODE_PIC);
    assign key_prev_pl = k2_p & (mode == MODE_PIC) & (img_no_l > 8'd1);

    //--------------------------------------------------------------
    // 缩放档变化脉冲(模式2 且未到边界才真正变化 → 产生 1 拍脉冲)
    //--------------------------------------------------------------
    wire res_up_c = k3_p & (mode == MODE_RES) & (res_level < RES_MAX);
    wire res_dn_c = k2_p & (mode == MODE_RES) & (res_level > 4'd0);

    reg  res_chg_f;
    always @(posedge clk or posedge rst) begin
        if (rst)
            res_chg_f <= 1'b0;
        else
            res_chg_f <= res_up_c | res_dn_c;
    end
    assign res_chg_pl = res_chg_f;

    //--------------------------------------------------------------
    // 参数寄存器更新
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mode       <= MODE_PIC;
            bri_level  <= BRI_INIT;
            res_level  <= RES_INIT;
            pic_manual <= 1'b0;
            img_no_l   <= 8'd0;
        end
        else begin
            // ---- KEY1: 功能模式循环 0→1→2→0 ----
            if (k1_p)
                mode <= (mode == MODE_RES) ? MODE_PIC : (mode + 2'd1);

            // ---- 模式1: 亮度 ± ----
            if (k3_p && (mode == MODE_BRI) && (bri_level < BRI_MAX))
                bri_level <= bri_level + 4'd1;
            if (k2_p && (mode == MODE_BRI) && (bri_level > 4'd0))
                bri_level <= bri_level - 4'd1;

            // ---- 模式2: 缩放档 ± ----
            if (res_up_c)
                res_level <= res_level + 4'd1;
            if (res_dn_c)
                res_level <= res_level - 4'd1;

            // ---- 自动轮播 / 手动单张(模式0 内由切图动作自动转换, 无独立键) ----
            //   · 场景切换           → 回自动(新场景默认轮播)
            //   · 非模式0(亮度/缩放) → 回自动(那两种模式 KEY2/3 去调参数, 别冻图)
            //   · 模式0 按 KEY3      → 转手动(切下一张 + 停自动计时)
            //   · 模式0 第1张按 KEY2 → 回自动(与"上一张"共用一键, 已在首张则退自动)
            if (scene_chg)
                pic_manual <= 1'b0;
            else if (mode != MODE_PIC)
                pic_manual <= 1'b0;
            else if (k3_p)
                pic_manual <= 1'b1;
            else if (k2_p && (img_no_l <= 8'd1))
                pic_manual <= 1'b0;

            // ---- 图序号锁存 ----
            if (img_no != 8'd0)
                img_no_l <= img_no;
        end
    end

    // 显示参数: 手动时显示当前图序号, 自动时为 0
    assign pic_param = pic_manual ? img_no_l : 8'd0;

endmodule


//====================================================================
// 子模块 : ui_key_dbnc —— 机械按键消抖(两级同步 + 计数器), 输出"按下"脉冲
// 输入原始电平(上拉高、按下低), 输出稳定按下时的单周期脉冲(下降沿)
//
// 消抖算法(2026-09-16 重修, 修"偶发失灵"):
//   以"消抖后电平" level 为唯一基准 —— 同步后的输入只要与 level 一致就
//   把计数器清零; 一旦偏离且**连续 DEB_MAX 拍(10ms)都不回来**才采纳新电平。
//   · 旧版缺陷: 判据用 key_sync[1]!=key_sync[0](只在输入跳变那一拍成立),
//     加上 20ms 的 DEB_MAX —— 一次快速点按(接触抖动 3~5ms + 稳定段不足
//     20ms)会导致计数器到不了 DEB_MAX, level 永不翻低 → 整次按键丢失,
//     表现为"有时按了没反应"。
//   · 新版: 10ms 定值(机械按键抖动典型 ≤5ms, 人手点按稳定段 ≥30ms), 且
//     抖动会被连续清零, 既不误触发也几乎不丢按键。
//====================================================================
module ui_key_dbnc #(
    parameter [19:0] DEB_MAX = 20'd1_000_000    // 10ms@100MHz(周期数-1)
)(
    input               clk,
    input               rst,             // 高有效复位
    input               key_raw,         // 原始电平(1=释放/高, 0=按下/低)
    output reg          press_pl         // 稳定后按下下降沿脉冲(1 拍)
);

    reg [1:0]   key_sync;   // 两级同步器
    reg [19:0]  cnt;        // 稳定计时
    reg         level;      // 消抖后电平(1=高/释放)
    reg         level_d;    // 电平打拍(边沿检测)

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key_sync <= 2'b11;
            cnt      <= 20'd0;
            level    <= 1'b1;
            level_d  <= 1'b1;
            press_pl <= 1'b0;
        end
        else begin
            key_sync <= {key_sync[0], key_raw};      // 两级同步

            if (key_sync[1] == level) begin
                cnt <= 20'd0;                        // 与消抖电平一致 → 计时清零
            end
            else if (cnt == DEB_MAX) begin
                level <= key_sync[1];                // 连续 10ms 偏离 → 采纳新电平
                cnt   <= 20'd0;
            end
            else
                cnt <= cnt + 20'd1;

            level_d  <= level;
            press_pl <= level_d & ~level;            // 采纳"按下"时输出 1 拍脉冲
        end
    end

endmodule
