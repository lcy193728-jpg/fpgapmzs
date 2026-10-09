//====================================================================
// 模块名 : ui_key_ctrl.v —— 全局统一人机交互控制器(2026-09-16 改版)
//
// 设计目标(全局统一样式, 与场景基本解耦):
//   KEY1(A2) : 功能模式循环, 每按一次 +1。★2026-10-09f 起各场景序列不同:
//                · 迎新 : 0图片→1亮度→2缩放→3**轮播周期**→4**对比度**→5**音量**→0
//                · 抢答 : 0图片→1亮度→2缩放→3**对比度**→4**抢答计分**→5**音量**→0
//                · 应急 : 0图片→1亮度→2**对比度**→3**音量**→0
//                         (**无缩放档、无轮播周期档**, 故整体前移, 3 档直接回 0)
//   KEY2(B2) : 当前模式参数 减
//   KEY3(B1) : 当前模式参数 加
//   KEY4(C1) : ★2026-10-09e: **迎新场景模式0 = 自动轮播 ↔ 手动单张 切换**;
//              其余场景/模式不参与逻辑(顶层不采用其它用途)。
//
// 场景接管(2026-10-01 合入 dev_sim 会议改动; 2026-10-01 应急场景改交互):
//   · control_lock=1 时(会议场景 meeting_key_owner), 本模块
//     **冻结所有全局UI参数动作**(模式循环/亮度/缩放/周期/音量/切图), 只保留
//     消抖脉冲导出, 交给会议逻辑使用 → 同一次按键不会既切场景又调参数。
//   · 应急场景(alarm_scene=1)**不再冻结 UI**, 按键语义与迎新场景基本一致:
//       KEY1 = 模式循环(见上: 2=对比度 / 3=音量 / 无缩放档、无周期档)
//       KEY2/KEY3 = 当前模式参数 减/加
//     唯一区别: 模式0 在本场景中不再切换图片, 而是**四类告警环绕切换**
//       KEY3 = 下一类(0→1→2→3→0), KEY2 = 上一类(0→3→2→1→0);
//     其余模式(亮度/对比度/音量)语义与迎新场景完全相同(本场景无缩放档)。
//
// 各模式参数语义:
//   模式0 图片/切图 : 参数 = 图序号(0=自动轮播, N=手动第 N 张)
//     · 刚进模式0(上电/切场景/从别的模式切回来)一律 = **自动轮播**
//     · ★2026-10-09e: 按 KEY4 = **自动 ↔ 手动** 切换(独立开关, 仅迎新场景)
//     · 模式0 内按 KEY3 = **下一张**; 按 KEY2 = **上一张**
//       (均**不再**顺带改变"自动/手动"状态 —— 该状态只由 KEY4 控制)
//     · 离开模式0(去亮度/缩放) = **自动回到自动轮播**(该模式下 KEY2/KEY3
//       去调参数, 不应把底层图片冻住)
//     ※ 与旧版的区别: ★2026-10-09e "自动/手动"改由 **KEY4** 独立控制,
//       KEY2/KEY3 只做上一张/下一张, 不再有"按了切图就顺带换模式"的歧义。
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
//   模式3/4/5 按"档位身份"解释(★2026-10-09f 起应急去掉缩放档, 档位前移):
//     · 迎新场景 4 档 = 对比度(档 0..15, 默认 8=中性), 电平 con_level 送
//       display_adjust 的 out=(in-128)*k/128+128 (k=8+con*15)。
//     · 抢答场景 3 档 = 对比度; 4 档 = 抢答计分: KEY3 → score_up_lv(判对 +2) /
//       KEY2 → score_dn_lv(判错 -1), ★输出**电平**; 由顶层在抢答场景接
//       quiz_ctrl, 其余场景恒 0。
//     · 应急场景 2 档 = 对比度、3 档 = 音量(因该场景去掉了缩放档/周期档而
//       整体前移, 见 KEY1 说明); 音量档 0..15, 与 5 档音量完全同构(见下"模式5 音量")。
//   ★2026-10-09c 新增「对比度」档: 见上方 KEY1 说明。档位 0..15(默认 8),
//     输出电平 con_level 送 display_adjust, 并在该档弹"品红 16 档条"
//     (与亮度/音量条同构, 行位 y64..71)。
//   ★2026-10-09 起, 会议场景已整体删除(见 osd_scene.v v11 变更史),
//     原"会议计时"语义不再存在。
//   ★2026-10-09f: 应急场景无缩放档、无轮播周期档, 2/3 档改为对比度/音量(整体前移)。
//   模式5 音量  : 参数 = **音量档 0..15**(KEY3 加 / KEY2 减, 默认 8 = ×1.0)
//                 与模式1(亮度)完全同构, 只是作用对象换成音频末级增益。
//                 仅导出电平 vol_level, 由顶层在"音频链末级"按
//                 out = (in * vol) >>> 3 缩放(0=静音, 8=×1.0, 15≈×1.875)。
//                 ※ 2026-09-28 用户要求新增。
//                 ※ ★2026-10-09f: **仅迎新/抢答**场景的 5 档是音量;
//                   应急场景的音量在 3 档(见上), 5 档不被 KEY1 走到。
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
    parameter [3:0] VOL_INIT = 4'd8,       // 音量默认档(×1.0, 与亮度同口径)
    parameter [3:0] VOL_MAX  = 4'd15,      // 音量上限(≈×1.875)
    parameter [3:0] RES_INIT = 4'd4,       // 缩放默认档(4=100% 原始比例, 与原画一致)
    parameter [3:0] RES_MAX  = 4'd7,       // 缩放上限
    // ---- 对比度档(2026-10-09c 新增) ----
    //   与亮度同构(16 档, 默认 8=×1.0), 但在"对比度"档时, 该档位由**场景**决定
    //   对应哪个功能模式号(迎新→4 / 应急→2 / 抢答→3), 见下方 con_slot 段。
    parameter [3:0] CON_INIT = 4'd8,       // 对比度默认档(×1.0)
    parameter [3:0] CON_MAX  = 4'd15,      // 对比度上限(≈×1.9)
    parameter [2:0] MODE_PIC = 3'd0,       // 功能模式: 图片
    parameter [2:0] MODE_BRI = 3'd1,       // 功能模式: 亮度
    parameter [2:0] MODE_RES = 3'd2,       // 功能模式: 缩放
    parameter [2:0] MODE_PERIOD = 3'd3,    // 功能模式: 轮播周期(批次4 新增)
    parameter [2:0] MODE_MEET = 3'd4,      // 抢答场景: 抢答计分档; 迎新: 对比度档
    parameter [2:0] MODE_CON  = 3'd3,      // 抢答场景: 对比度档(替换原周期档)
    parameter [2:0] MODE_VOL  = 3'd5,      // 功能模式: 音量(2026-09-28 新增)
    // ---- 批次4 轮播周期档 ----
    parameter [2:0] PERIOD_NUM = 3'd5,     // 档位数(2/3/5/10/30 s)
    parameter [2:0] PERIOD_DEF = 3'd1,     // 默认档 = 3s(与原 SLIDE_INTERVAL 一致)
    parameter [31:0] CLK_FREQ_HZ      = 32'd100_000_000, // 本模块时钟=sd_card_clk
    parameter [31:0] DISP_HOLD_CYCLES = 32'd200_000_000  // 参数强显保持(2s@100MHz)
)(
    input               clk,               // sd_card_clk(100MHz)
    input               rst,               // 高有效复位
    // ---- 板载按键原始电平(上拉高、按下低) ----
    input               key1,              // 功能模式循环 0图片/切图→1亮度→2缩放→3周期→4会议→5音量→0
    input               key2,              // 当前模式参数 减
    input               key3,              // 当前模式参数 加
    input               key4,              // 会议场景当前议题重新计时(消抖脉冲导出)
    input               control_lock,      // 1=按键由会议场景接管, 不改全局UI参数
    input               alarm_scene,       // 1=处于应急场景(模式0 改为告警类型环绕切换)
    // ---- 上下文 ----
    input       [7:0]   img_no,            // bmp_read_auto 当前图序号(1..N; 0=空闲)
    input               scene_chg,         // 场景切换脉冲(清手动→自动)
    // ---- 场景号(2026-10-09c 新增; 用于"对比度档"的模式号重映射) ----
    //   0=迎新 1=预留(原会议) 2=抢答 3=应急, 由顶层 scene_control 给出。
    //   ★语义: 各场景"对比度档"的模式号不同 —— 抢答 3 / 迎新 4 / 应急 2,
    //     由本模块内部按 scene_id 在 con_slot 处解释(见下方), 输出的 mode
    //     编号本身不改写, 数码管第 5 位(模式号)直接显示按键切到的编号。
    input       [1:0]   scene_id,
    // ---- 输出 ----
    output reg  [2:0]   mode,              // 功能模式 0图片/1亮度/2缩放/3周期|对比度/4计分|对比度/5音量
                                           //   ★模式号含义随场景变: 抢答 3=对比度;
                                           //     迎新 4=对比度; 应急 2=对比度/3=音量。
                                           //     由本模块内部按 scene_id 重映射。
    output reg  [3:0]   bri_level,         // 亮度档 0..15(模式1可调)
    output reg  [3:0]   vol_level,         // 音量档 0..15(模式5可调, 默认8=×1.0)
    output reg  [3:0]   res_level,         // 缩放档 0..7(模式2可调)
    output reg  [3:0]   con_level,         // 对比度档 0..15(对比度档可调, 默认8=×1.0)
                                           //   ★2026-10-09c 新增; 送 display_adjust.con_level
    output reg  [1:0]   alarm_type,        // 应急告警类型 0火灾/1地震/2恶劣天气/3疏散(应急模式0可调)
    output wire [7:0]   period_sec,        // 轮播间隔档(秒: 2/3/5/10/30, 模式3可调)
    output wire [31:0]  period_cycles,     // 轮播间隔(时钟周期) → bmp_read_auto
    output wire         disp_hold,         // 1=参数强显保持期(2 秒)
    output reg  [2:0]   disp_sel,          // 保持期显示的模式(产生动作时的 mode)
    output reg          pic_manual,        // 1=手动单张(冻结自动轮播) / 0=自动轮播
    output      [7:0]   pic_param,         // 显示用图片参数: 0=轮播, >0=手动第N张
    output              key_next_pl,       // 手动"下一张"单周期脉冲
    output              key_prev_pl,       // 手动"上一张"单周期脉冲
    output              res_chg_pl,        // 缩放档变化脉冲(1 拍) → 重载当前图
    // ---- 四键消抖脉冲导出(顶层在会议场景送入 meeting_ctrl) ----
    output              key1_pl,           // KEY1 消抖"按下"脉冲(会议=开始/暂停/继续)
    output              key2_pl,           // KEY2 消抖"按下"脉冲(会议=下一项)
    output              key3_pl,           // KEY3 消抖"按下"脉冲(会议=上一项)
    output              key4_pl,           // KEY4 消抖"按下"脉冲(会议=当前项重新计时)
    // ---- 抢答计分: 电平输出(2026-10-09c 由"脉冲"改为"电平") ----
    //   原因: 顶层把本模块输出**跨域**送入 quiz_ctrl(其输入经两级同步)。
    //   原"单周期(10ns)脉冲"过两级同步器会被整段滤掉 → 实机按键无效。
    //   改为"消抖后按住电平": quiz_ctrl 侧电平采样 + 内部 100ms 节拍连判。
    //   ★仅当 mode==MODE_MEET(抢答场景的计分档)时该电平才被拉高(其余模式恒 0),
    //     不改变"亮度/对比度档按 KEY2/KEY3 不计分"的原有语义。
    output              score_up_lv,       // KEY3(计分档)按住电平 = 判对 +2
    output              score_dn_lv        // KEY2(计分档)按住电平 = 判错 -1
);

    //--------------------------------------------------------------
    // ★场景相关的模式号重映射(2026-10-09c 新增; ★2026-10-09e/09f 调整)
    //   需求(用户 2026-10-09 / 2026-10-09e / 2026-10-09f 指定):
    //     · 迎新场景: 模式 4 = **对比度**(该场景无抢答计分)
    //     · 抢答场景: 模式 3 = **对比度**, 模式 4 = **抢答计分**
    //     · 应急场景: **没有缩放、没有轮播周期档**, 故整体前移:
    //                 模式 2 = **对比度**, 模式 3 = **音量**
    //                 模式 4/5 = 空(不再被 KEY1 走到)
    //   ★关键推论: 应急场景下 KEY1 的循环**提前两档结束**(3→0),
    //     因为 4/5 档已无名目。抢答场景 5 档仍是音量, 不参与"不完整循环"。
    //   ⇒ 各场景 KEY1 实际可走到的模式号序列:
    //       迎新   : 0 → 1 → 2 → 3 → 4 → 5 → 0   (完整 6 档)
    //       抢答   : 0 → 1 → 2 → 3 → 4 → 5 → 0   (完整 6 档, 3/4 换功能)
    //       应急   : 0 → 1 → 2 → 3 → 0           (4/5 档跳过)
    //     数码管第 5 位显示的**模式号**天然就是用户要的编号, 无需额外查表。
    //   ※ 这样处理最小化改动: display_adjust / bmp_read_auto 等下游只认 mode
    //     编号, 不需要任何场景相关判断(周期档的秒数输出在抢答/应急场景自动失效)。
    //--------------------------------------------------------------
    wire scr_q;        // 1 = 抢答场景
    wire scr_e;        // 1 = 应急场景(2026-10-09e 新增)
    wire scr_m;        // 1 = 会议场景(2026-10-09j 新增)
    assign scr_q = (scene_id == 2'd2);
    assign scr_e = (scene_id == 2'd3);
    assign scr_m = (scene_id == 2'd1);
    // 四个"档位身份"判据(与 KEY1 循环无关, 只用于 KEY2/KEY3 的动作门控):
    //   ★2026-10-09f: 应急场景"没有缩放"—— 删掉缩放档后整体前移,
    //     最终 0图片/1亮度/2对比度/3音量(缩放、周期、计分三档全无)。
    //     故 con_slot 应急取 2 档、vol_slot 应急取 3 档。
    //   ★2026-10-09j: 会议场景"无轮播周期档"(倒计时驱动切场), 档位前移:
    //     0议程/1亮度/2缩放/3对比度/4音量 → con_slot 会议取 3 档、vol_slot 会议取 4 档。
    wire con_slot = scr_q ? (mode == MODE_CON)      // 抢答: 3 档 = 对比度
                  : scr_e ? (mode == MODE_RES)      // 应急: 2 档 = 对比度(去缩放后前移)
                  : scr_m ? (mode == MODE_PERIOD)   // 会议: 3 档 = 对比度(无周期档)
                  :         (mode == MODE_MEET);    // 迎新: 4 档 = 对比度
    wire per_slot = ~scr_q & ~scr_e & ~scr_m & (mode == MODE_PERIOD); // 周期档(仅迎新: 3 档)
    wire scc_slot =  scr_q & (mode == MODE_MEET);          // 计分档(仅抢答: 4 档)
    // 音量档: 迎新/抢答在 5 档; 应急无缩放/周期落在 3 档; 会议无周期档落在 4 档。
    wire vol_slot = scr_e ? (mode == MODE_PERIOD)   // 应急: 3 档 = 音量
                  : scr_m ? (mode == MODE_MEET)     // 会议: 4 档 = 音量
                          : (mode == MODE_VOL);     // 迎新/抢答: 5 档 = 音量


    //--------------------------------------------------------------
    // 按键消抖(两级同步 + 10ms 计数)
    //   输出两组: ① 按下**单周期脉冲**(press_pl, 供参数增减"一次一档")
    //             ② 消抖后**按住电平**(down_lv, 供跨域给 quiz_ctrl 用)
    //--------------------------------------------------------------
    wire k1_p, k2_p, k3_p, k4_p;
    wire k1_lv, k2_lv, k3_lv, k4_lv;

    ui_key_dbnc u_k1 (.clk(clk), .rst(rst), .key_raw(key1), .press_pl(k1_p), .down_lv(k1_lv));  // 模式循环
    ui_key_dbnc u_k2 (.clk(clk), .rst(rst), .key_raw(key2), .press_pl(k2_p), .down_lv(k2_lv));  // 参数 减
    ui_key_dbnc u_k3 (.clk(clk), .rst(rst), .key_raw(key3), .press_pl(k3_p), .down_lv(k3_lv));  // 参数 加
    ui_key_dbnc u_k4 (.clk(clk), .rst(rst), .key_raw(key4), .press_pl(k4_p), .down_lv(k4_lv));  // 会议重新计时

    // 消抖后按键脉冲导出; 是否由会议逻辑接管由最终顶层按场景决定。
    assign key1_pl = k1_p;
    assign key2_pl = k2_p;
    assign key3_pl = k3_p;
    assign key4_pl = k4_p;

    //--------------------------------------------------------------
    // 抢答计分: KEY2/KEY3 的**按住电平**输出(2026-10-09c 新增/改造)
    //   · 仅"抢答场景 且 计分档(mode==4)"时拉高, 其余模式恒 0
    //     → 在亮度/缩放/对比度/音量/周期档按 KEY2/KEY3 绝不会加分。
    //   · 顶层直接接到 quiz_ctrl.judge_up_lv / judge_dn_lv(跨域后电平采样)。
    //   ★为什么用电平: 原实现输出"按下单周期脉冲"(10ns@100MHz), 顶层把它送进
    //     quiz_ctrl 的输入(内部两级同步器)。同步器每拍只看一次采样点, 10ns
    //     脉冲极大概率整个落在两次采样之间被丢弃 ⇒ 实机"按键无反应"。
    //     改电平后, 只要按住就持续为高, 同步器必然采到; 重复判分改由
    //     quiz_ctrl 内部 100ms 节拍完成。
    //--------------------------------------------------------------
    assign score_up_lv = k3_lv & ~control_lock & scc_slot;
    assign score_dn_lv = k2_lv & ~control_lock & scc_slot;

    //--------------------------------------------------------------
    // 对比度档增减(2026-10-09c 新增): 边界钳位, 同亮度/音量
    //   档位身份由 con_slot 给出(抢答=3 档 / 迎新·应急=4 档)
    //--------------------------------------------------------------
    wire con_up_c = k3_p & ~control_lock & con_slot & (con_level < CON_MAX);
    wire con_dn_c = k2_p & ~control_lock & con_slot & (con_level > 4'd0);

    //--------------------------------------------------------------
    // 轮播周期档增减(仅"迎新/应急场景的 3 档"; 抢答场景该档改为对比度 → 恒无效)
    //   per_up_c/per_dn_c 在此统一声明, 供下方 param_evt_all 与 period_idx 使用。
    //--------------------------------------------------------------
    wire per_up_c = k3_p & ~control_lock & per_slot;
    wire per_dn_c = k2_p & ~control_lock & per_slot;

    //--------------------------------------------------------------
    // 图片模式脉冲判定(模式0 内始终有效, 无需先"进手动"):
    //   下一张: KEY3(模式0)   上一张: KEY2(模式0, 当前不是第 1 张)
    //   ★2026-10-09e: 两者**只切图, 不改"自动/手动"状态**(该状态由 KEY4 控制)。
    //   ※ 这样"图模式里 KEY2/KEY3 就是上一张/下一张", 不会与亮度/缩放混淆
    //     (亮度/缩放要求 mode=1/2, 与 mode=0 互斥)。
    //--------------------------------------------------------------
    reg  [7:0] img_no_l;                   // 图序号锁存(仅非 0 时更新, 防扫描期抖动)

    // 应急场景下模式0 不做图片切换(改为告警类型环绕切换, 见下), 故加 ~alarm_scene 门控。
    assign key_next_pl = k3_p & ~control_lock & ~alarm_scene & (mode == MODE_PIC);
    assign key_prev_pl = k2_p & ~control_lock & ~alarm_scene & (mode == MODE_PIC) & (img_no_l > 8'd1);

    //--------------------------------------------------------------
    // 应急场景 模式0: 四类告警环绕切换(KEY3=下一类, KEY2=上一类)
    //   2bit 自然回绕: +1 时 3→0, -1 时 0→3, 无需额外边界判断。
    //   ※ 仅在 alarm_scene & 模式0 有效; 其余模式沿用迎新场景语义。
    //--------------------------------------------------------------
    wire alarm_up_c = k3_p & ~control_lock & alarm_scene & (mode == MODE_PIC);
    wire alarm_dn_c = k2_p & ~control_lock & alarm_scene & (mode == MODE_PIC);

    //--------------------------------------------------------------
    // 缩放档变化脉冲(模式2 且未到边界才真正变化 → 产生 1 拍脉冲)
    //   ★2026-10-09f: 应急场景无缩放档(2 档改为对比度), 故加 ~scr_e 门控,
    //     避免应急的 2 档(对比度)按 KEY2/3 时顺带触发缩放。
    //--------------------------------------------------------------
    wire res_up_c = k3_p & ~control_lock & ~scr_e & (mode == MODE_RES) & (res_level < RES_MAX);
    wire res_dn_c = k2_p & ~control_lock & ~scr_e & (mode == MODE_RES) & (res_level > 4'd0);

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

    // ★周期档的增减脉冲 per_up_c/per_dn_c 已在文件上方(与 con/计分 同处)声明,
    //   且已按场景做门控(仅非抢答场景的"周期档"有效)。

    //--------------------------------------------------------------
    // 参数强显保持(2 秒): 任一参数动作 → 重置保持计时并锁存"动作时的模式"
    //   · disp_hold 供顶层把数码管第2~4位临时改显该参数, 2 秒后自动返回
    //   · 计时器由参数动作重装(连按不断刷新), 归零后 disp_hold 落低
    //--------------------------------------------------------------
    wire bri_up_c  = k3_p & ~control_lock & (mode == MODE_BRI) & (bri_level < BRI_MAX);
    wire bri_dn_c  = k2_p & ~control_lock & (mode == MODE_BRI) & (bri_level > 4'd0);
    // 音量档 ±(与亮度同构: 边界钳位, 不做环绕)
    //   ★2026-10-09e: 档位身份由 vol_slot 给出 —— 应急场景因去掉周期档而
    //     整体前移, 音量从固定的 5 档移到 **4 档**(见上方 vol_slot 段)。
    wire vol_up_c  = k3_p & ~control_lock & vol_slot & (vol_level < VOL_MAX);
    wire vol_dn_c  = k2_p & ~control_lock & vol_slot & (vol_level > 4'd0);
    wire param_evt_all = res_up_c | res_dn_c | bri_up_c | bri_dn_c |
                         per_up_c | per_dn_c | vol_up_c | vol_dn_c |
                         con_up_c | con_dn_c;

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
            vol_level  <= VOL_INIT;
            res_level  <= RES_INIT;
            con_level  <= CON_INIT;
            period_idx <= PERIOD_DEF;
            alarm_type <= 2'd0;
            pic_manual <= 1'b0;
            img_no_l   <= 8'd0;
        end
        else begin
            // ---- KEY1: 功能模式循环 ----
            //   ★2026-10-09c: 编号序列不变; "3/4 两档的含义"由 scene_id
            //     在 con_slot/per_slot/scc_slot/vol_slot 处解释。
            //   ★2026-10-09f: 应急场景"没有缩放、没有轮播周期档", 整体前移
            //     (2=对比度, 3=音量), 故其 KEY1 **提前两档结束**: 3 → 0。
            //     ⚠ 用 `mode >= MODE_PERIOD`(≥3) 而非 `==` 回 0: 从其它场景
            //       切进应急时 mode 可能残留 4/5(不在应急合法档 0..3 内),
            //       用 `==` 会把它带到 5/6/7 乱走; `>=` 保证任何 ≥3 都归一回 0。
            //       · 迎新   : 0→1→2→3→4→5→0(完整, 末档 5 回 0)
            //       · 抢答   : 0→1→2→3→4→5→0(完整, 3/4 换功能)
            //       · 应急   : 0→1→2→3→0    (3 直接回 0, 4/5 档无名目)
            if (k1_p && !control_lock) begin
                if (scr_e)
                    mode <= (mode >= MODE_PERIOD) ? MODE_PIC : (mode + 3'd1);
                else if (scr_m)
                    mode <= (mode >= MODE_MEET) ? MODE_PIC : (mode + 3'd1);  // 会议: 0→1→2→3→4→0
                else
                    mode <= (mode == MODE_VOL)  ? MODE_PIC : (mode + 3'd1);
            end

            // ---- 模式1: 亮度 ± ----
            if (bri_up_c)
                bri_level <= bri_level + 4'd1;
            if (bri_dn_c)
                bri_level <= bri_level - 4'd1;

            // ---- ★对比度档 ± (2026-10-09c 新增; 档位身份见 con_slot) ----
            if (con_up_c)
                con_level <= con_level + 4'd1;
            if (con_dn_c)
                con_level <= con_level - 4'd1;

            // ---- 模式5: 音量 ± ----
            if (vol_up_c)
                vol_level <= vol_level + 4'd1;
            if (vol_dn_c)
                vol_level <= vol_level - 4'd1;

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

            // ---- 应急场景 模式0: 四类告警环绕切换(KEY3=下一类 / KEY2=上一类) ----
            if (alarm_up_c)
                alarm_type <= alarm_type + 2'd1;      // 0→1→2→3→0
            if (alarm_dn_c)
                alarm_type <= alarm_type - 2'd1;      // 0→3→2→1→0
            // 切换场景(含进入应急)回到第 0 类(火灾); 放最后保证优先级最高
            if (scene_chg)
                alarm_type <= 2'd0;

            // ---- 自动轮播 / 手动单张 ----
            //   ★2026-10-09e 改动(用户指定): 新增**独立开关 KEY4** ——
            //     在迎新场景的模式 0 下按 KEY4 = **在"自动轮播 / 手动单张"之间切换**;
            //     KEY2/KEY3 在该模式下**只负责上一张 / 下一张**, 不再自动切换
            //     "自动↔手动"(旧实现: 按 KEY3 切下一张时顺带转手动, 已在首张
            //     按 KEY2 时顺带退回自动 —— 这两个副作用已删除, 避免与 KEY4 打架)。
            //   其余"回自动"的规则保持不变:
            //     · 场景切换            → 回自动(新场景默认轮播)
            //     · 非模式0(亮度/缩放…)  → 回自动(那几档 KEY2/3 去调参数, 别冻图)
            //     · 应急模式0           → 回自动(该模式 KEY2/3 去切告警类型, 不冻图)
            //   (KEY4 仅迎新场景模式 0 有效; 其余场景/模式按 KEY4 无任何动作)
            if (scene_chg)
                pic_manual <= 1'b0;
            else if (mode != MODE_PIC)
                pic_manual <= 1'b0;
            else if (alarm_scene)
                pic_manual <= 1'b0;
            else if (k4_p && !control_lock && ~scr_q && ~scr_e && ~scr_m)
                pic_manual <= ~pic_manual;    // ★KEY4: 自动 ↔ 手动 切换(仅迎新模式0)

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
    output reg          press_pl,        // 稳定后按下下降沿脉冲(1 拍)
    output wire         down_lv          // ★消抖后"按住"电平(1=按住) —— 2026-10-09c
                                         //   用途: 跨域送给 quiz_ctrl(电平采样),
                                         //   窄脉冲过同步器会被滤掉, 故必须用电平。
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

    // 消抖后"按住"电平: level 为消抖电平(1=释放), 取反即"按住"。
    assign down_lv = ~level;

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
