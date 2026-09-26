//====================================================================
// 模块名 : ui_key_ctrl.v —— 全局统一人机交互控制器(2026-09-16 改版)
//
// 设计目标(全局统一样式, 与场景完全解耦: 四个场景下按键含义一致):
//   KEY1(A2) : 功能模式循环, 每按一次 +1: 0图片/切图→1亮度→2缩放→3周期→4会议计时→0
//   KEY2(B2) : 当前模式参数 减;  模式4 = 会议计时 开始/暂停/继续
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
//   模式3 周期  : 参数 = **自动轮播间隔档**(2/3/5/10/30 s, 默认 3s —— 与原
//                 固定参数 SLIDE_INTERVAL(3s@100MHz) 完全一致, 保证默认
//                 观感与行为不变)
//                 KEY3 加档 / KEY2 减档, 到端点**环绕**(0→1→2→3→4→0),
//                 与亮度/缩放的"边界钳位"不同(档位是离散枚举, 环绕更顺手)。
//                 输出 period_cycles(周期数) 送 bmp_read_auto 的运行时
//                 轮播间隔输入。进入本档同样回自动轮播(否则计时器不跑)。
//   模式4 会议  : 参数 = **无**(本模式不调任何显示参数; 进入本档自动回自动轮播)
//                 KEY2 = 会议计时 开始/暂停/继续, KEY3 = 当前项**重新计时**。
//                 仅导出消抖脉冲 key2_pl/key3_pl, 由顶层在"会议场景(latch=2)"
//                 下接到 meeting_ctrl.press[0] / press[3]; 其它场景/其它模式
//                 无副作用(会议计时器 en 由场景使能控制, 见 top.v)。
//                 ※ 这是把 dev_sim 会议场景三的 KEY1/KEY4 控制适配到本板
//                 "统一按键样式"的落地方式(原按键功能全部保留, 仅新增本模式)。
//
// 数码管"参数强显保持"(小鹅通第三讲 seg7_panel 的 HOLD 机制):
//   · 任何一次参数动作(亮度/缩放/周期 ±) → 输出 disp_hold 拉高 2 秒,
//     并锁存当时所在模式 disp_sel; 顶层据此让第2~4位临时显示该参数值,
//     2 秒后自动回到"当前模式"的常规显示。
//   · 默认观感不变: 在模式1/2/3 内本就在显示对应参数, 加不加保持都一样;
//     只有"调完参数立刻切回模式0"时, 参数值会多留 2 秒再回到图序号。
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
    parameter [2:0] MODE_PIC = 3'd0,       // 功能模式: 图片
    parameter [2:0] MODE_BRI = 3'd1,       // 功能模式: 亮度
    parameter [2:0] MODE_RES = 3'd2,       // 功能模式: 缩放
    parameter [2:0] MODE_PERIOD = 3'd3,    // 功能模式: 轮播周期(批次4 新增)
    parameter [2:0] MODE_MEET = 3'd4,      // 功能模式: 会议计时(会议场景, 2026-09-19 新增)
    // ---- 批次4 轮播周期档 ----
    parameter [2:0] PERIOD_NUM = 3'd5,     // 档位数(2/3/5/10/30 s)
    parameter [2:0] PERIOD_DEF = 3'd1,     // 默认档 = 3s(与原 SLIDE_INTERVAL 一致)
    parameter [31:0] CLK_FREQ_HZ      = 32'd100_000_000, // 本模块时钟=sd_card_clk
    parameter [31:0] DISP_HOLD_CYCLES = 32'd200_000_000  // 参数强显保持(2s@100MHz)
)(
    input               clk,               // sd_card_clk(100MHz)
    input               rst,               // 高有效复位
    // ---- 板载按键原始电平(上拉高、按下低) ----
    input               key1,              // 功能模式循环 0图片/切图→1亮度→2缩放→3周期→0
    input               key2,              // 当前模式参数 减
    input               key3,              // 当前模式参数 加
    input               key4,              // 会议场景当前议题重新计时
    input               control_lock,       // 1=按键由会议/应急场景接管，不改全局UI参数
    // ---- 上下文 ----
    input       [7:0]   img_no,            // bmp_read_auto 当前图序号(1..N; 0=空闲)
    input               scene_chg,         // 场景切换脉冲(清手动→自动)
    // ---- 输出 ----
    output reg  [2:0]   mode,              // 功能模式 0图片/1亮度/2缩放/3周期/4会议计时
    output reg  [3:0]   bri_level,         // 亮度档 0..15(模式1可调)
    output reg  [3:0]   res_level,         // 缩放档 0..7(模式2可调)
    output wire [7:0]   period_sec,        // 轮播间隔档(秒: 2/3/5/10/30, 模式3可调)
    output wire [31:0]  period_cycles,     // 轮播间隔(时钟周期) → bmp_read_auto
    output wire         disp_hold,         // 1=参数强显保持期(2 秒)
    output reg  [2:0]   disp_sel,          // 保持期显示的模式(产生动作时的 mode)
    output reg          pic_manual,        // 1=手动单张(冻结自动轮播) / 0=自动轮播
    output      [7:0]   pic_param,         // 显示用图片参数: 0=轮播, >0=手动第N张
    output              key_next_pl,       // 手动"下一张"单周期脉冲
    output              key_prev_pl,       // 手动"上一张"单周期脉冲
    output              res_chg_pl,        // 缩放档变化脉冲(1 拍) → 重载当前图
    // ---- 四键消抖脉冲导出(最终顶层在会议场景送入 meeting_ctrl) ----
    output              key1_pl,
    output              key2_pl,
    output              key3_pl,
    output              key4_pl
);

    //--------------------------------------------------------------
    // 按键消抖(两级同步 + 10ms 计数, 输出按下单周期脉冲)
    //--------------------------------------------------------------
    wire k1_p, k2_p, k3_p, k4_p;

    ui_key_dbnc u_k1 (.clk(clk), .rst(rst), .key_raw(key1), .press_pl(k1_p));  // 模式循环
    ui_key_dbnc u_k2 (.clk(clk), .rst(rst), .key_raw(key2), .press_pl(k2_p));  // 参数 减
    ui_key_dbnc u_k3 (.clk(clk), .rst(rst), .key_raw(key3), .press_pl(k3_p));  // 参数 加
    ui_key_dbnc u_k4 (.clk(clk), .rst(rst), .key_raw(key4), .press_pl(k4_p));  // 会议重新计时

    // 消抖后按键脉冲导出；是否由会议逻辑接管由最终顶层按场景决定。
    assign key1_pl = k1_p;
    assign key2_pl = k2_p;
    assign key3_pl = k3_p;
    assign key4_pl = k4_p;

    //--------------------------------------------------------------
    // 图片模式脉冲判定(模式0 内始终有效, 无需先"进手动"):
    //   下一张: KEY3(模式0) —— 动作同时把 pic_manual 置 1(见下方 pic_manual 段)
    //   上一张: KEY2(模式0, 当前不是第 1 张)
    //   ※ 这样"图模式里 KEY2/KEY3 就是上一张/下一张", 不会与亮度/缩放混淆
    //     (亮度/缩放要求 mode=1/2, 与 mode=0 互斥)。
    //--------------------------------------------------------------
    reg  [7:0] img_no_l;                   // 图序号锁存(仅非 0 时更新, 防扫描期抖动)

    assign key_next_pl = k3_p & ~control_lock & (mode == MODE_PIC);
    assign key_prev_pl = k2_p & ~control_lock & (mode == MODE_PIC) & (img_no_l > 8'd1);

    //--------------------------------------------------------------
    // 缩放档变化脉冲(模式2 且未到边界才真正变化 → 产生 1 拍脉冲)
    //--------------------------------------------------------------
    wire res_up_c = k3_p & ~control_lock & (mode == MODE_RES) & (res_level < RES_MAX);
    wire res_dn_c = k2_p & ~control_lock & (mode == MODE_RES) & (res_level > 4'd0);

    reg  res_chg_f;
    always @(posedge clk or posedge rst) begin
        if (rst)
            res_chg_f <= 1'b0;
        else
            res_chg_f <= res_up_c | res_dn_c;
    end
    assign res_chg_pl = res_chg_f;

    //--------------------------------------------------------------
    // 批次4 轮播周期档(模式3)
    //   档位环绕: KEY3 → idx+1(4→0), KEY2 → idx-1(0→4)
    //   档位→"秒"(显示用) 与 "周期数"(送 bmp_read_auto) 两条输出:
    //     · 秒:    2/3/5/10/30, 默认 3s(与原固定 SLIDE_INTERVAL 等价)
    //     · 周期数: localparam 常量选择器 + 输出寄存
    //   ※ 实测教训(2026-09-17): 直接写 `period_sec_r * CLK_FREQ_HZ` 会被 TD
    //     例化成 DSP 乘法器(MULT18 3.56ns), 且恰好落在
    //     "档位 mux → 乘法器 → 下游 32bit 比较器/CE" 一条链上,
    //     syn_1 实测 Setup slack 只剩 +17ps(全设计唯一瓶颈)。
    //     改为"localparam 折叠常量 + 寄存器输出"后: 链上只剩
    //     档位 mux(常量)→ 寄存器, 并省下一个 DSP(板上 DSP 已用 28/29)。
    //     30s@100MHz = 3.0e9 < 2^32, 32bit 无符号不溢出。
    //--------------------------------------------------------------
    localparam [31:0] PER_CYC_2S  = CLK_FREQ_HZ * 32'd2;
    localparam [31:0] PER_CYC_3S  = CLK_FREQ_HZ * 32'd3;
    localparam [31:0] PER_CYC_5S  = CLK_FREQ_HZ * 32'd5;
    localparam [31:0] PER_CYC_10S = CLK_FREQ_HZ * 32'd10;
    localparam [31:0] PER_CYC_30S = CLK_FREQ_HZ * 32'd30;

    reg [2:0]  period_idx;
    reg [7:0]  period_sec_r;
    reg [31:0] period_cycles_r;

    always @(*) begin
        case (period_idx)
            3'd0:    period_sec_r = 8'd2;
            3'd1:    period_sec_r = 8'd3;
            3'd2:    period_sec_r = 8'd5;
            3'd3:    period_sec_r = 8'd10;
            default: period_sec_r = 8'd30;
        endcase
    end
    assign period_sec = period_sec_r;

    always @(posedge clk or posedge rst) begin
        if (rst)
            period_cycles_r <= PER_CYC_3S;       // 复位默认 = 3s(与原固定间隔一致)
        else case (period_idx)
            3'd0:    period_cycles_r <= PER_CYC_2S;
            3'd1:    period_cycles_r <= PER_CYC_3S;
            3'd2:    period_cycles_r <= PER_CYC_5S;
            3'd3:    period_cycles_r <= PER_CYC_10S;
            default: period_cycles_r <= PER_CYC_30S;
        endcase
    end
    assign period_cycles = period_cycles_r;

    wire per_up_c = k3_p & ~control_lock & (mode == MODE_PERIOD);
    wire per_dn_c = k2_p & ~control_lock & (mode == MODE_PERIOD);

    //--------------------------------------------------------------
    // 参数强显保持(2 秒): 任一参数动作 → 重置保持计时并锁存"动作时的模式"
    //   · disp_hold 供顶层把数码管第2~4位临时改显该参数, 2 秒后自动返回
    //   · 计时器由参数动作重装(连按不断刷新), 归零后 disp_hold 落低
    //--------------------------------------------------------------
    wire bri_up_c  = k3_p & ~control_lock & (mode == MODE_BRI) & (bri_level < BRI_MAX);
    wire bri_dn_c  = k2_p & ~control_lock & (mode == MODE_BRI) & (bri_level > 4'd0);
    wire param_evt_all = res_up_c | res_dn_c | bri_up_c | bri_dn_c | per_up_c | per_dn_c;

    reg [31:0] hold_cnt;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hold_cnt <= 32'd0;
            disp_sel <= MODE_PIC;
        end
        else if (param_evt_all) begin
            hold_cnt <= DISP_HOLD_CYCLES;
            disp_sel <= mode;
        end
        else if (hold_cnt != 32'd0) begin
            hold_cnt <= hold_cnt - 32'd1;
        end
    end
    assign disp_hold = (hold_cnt != 32'd0);

    //--------------------------------------------------------------
    // 参数寄存器更新
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mode       <= MODE_PIC;
            bri_level  <= BRI_INIT;
            res_level  <= RES_INIT;
            period_idx <= PERIOD_DEF;
            pic_manual <= 1'b0;
            img_no_l   <= 8'd0;
        end
        else begin
            // ---- KEY1: 功能模式循环 0→1→2→3→4→0 ----
            if (k1_p && !control_lock)
                mode <= (mode == MODE_MEET) ? MODE_PIC : (mode + 3'd1);

            // ---- 模式1: 亮度 ± ----
            if (bri_up_c)
                bri_level <= bri_level + 4'd1;
            if (bri_dn_c)
                bri_level <= bri_level - 4'd1;

            // ---- 模式2: 缩放档 ± ----
            if (res_up_c)
                res_level <= res_level + 4'd1;
            if (res_dn_c)
                res_level <= res_level - 4'd1;

            // ---- 模式3: 轮播周期档 ± (环绕) ----
            if (per_up_c)
                period_idx <= (period_idx >= PERIOD_NUM - 3'd1) ? 3'd0
                                                               : (period_idx + 3'd1);
            if (per_dn_c)
                period_idx <= (period_idx == 3'd0) ? (PERIOD_NUM - 3'd1)
                                                   : (period_idx - 3'd1);

            // ---- 自动轮播 / 手动单张(模式0 内由切图动作自动转换, 无独立键) ----
            //   · 场景切换           → 回自动(新场景默认轮播)
            //   · 非模式0(亮度/缩放/周期) → 回自动(那几档 KEY2/3 去调参数, 别冻图)
            //   · 模式0 按 KEY3      → 转手动(切下一张 + 停自动计时)
            //   · 模式0 第1张按 KEY2 → 回自动(与"上一张"共用一键, 已在首张则退自动)
            if (scene_chg)
                pic_manual <= 1'b0;
            else if (mode != MODE_PIC)
                pic_manual <= 1'b0;
            else if (k3_p && !control_lock)
                pic_manual <= 1'b1;
            else if (k2_p && !control_lock && (img_no_l <= 8'd1))
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

    // 2026-09-21 布线拥塞专项修复(与 scene_control.v 的 key_debounce 同法):
    //   把"已到 DEB_MAX"的全等比较结果**单独打一拍** term_q, 断开
    //   "21bit 比较树 → 20 路清零/自增多路器"这条长组合路径(实测 18.7ns,
    //   87% 是线延迟, 曾是 sd_card_clk 最差路径)。代价是采纳时刻 +1 拍。
    reg [1:0]   key_sync;   // 两级同步器
    reg [19:0]  cnt;        // 稳定计时
    reg         term_q;     // 上一拍"已到 DEB_MAX"
    reg         level;      // 消抖后电平(1=高/释放)
    reg         level_d;    // 电平打拍(边沿检测)

    wire        term = (cnt == DEB_MAX);        // 终点比较(单点负载)

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key_sync <= 2'b11;
            cnt      <= 20'd0;
            term_q   <= 1'b0;
            level    <= 1'b1;
            level_d  <= 1'b1;
            press_pl <= 1'b0;
        end
        else begin
            key_sync <= {key_sync[0], key_raw};      // 两级同步
            term_q   <= term;

            if (key_sync[1] == level) begin
                cnt <= 20'd0;                        // 与消抖电平一致 → 计时清零
            end
            else if (term_q) begin                   // 上一拍已到终点 → 采纳
                level <= key_sync[1];                // 连续 10ms 偏离
                cnt   <= 20'd0;
            end
            else
                cnt <= cnt + 20'd1;

            level_d  <= level;
            press_pl <= level_d & ~level;            // 采纳"按下"时输出 1 拍脉冲
        end
    end

endmodule
