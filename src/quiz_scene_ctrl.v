//====================================================================
// 模块名 : quiz_scene_ctrl.v —— 抢答场景「题目/队伍/结束」跳图桥接控制器
// 功能   (位于 quiz_ctrl 之后、sd_card_bmp/display_adjust 之前):
//   把 quiz_ctrl 的抢答流程状态, 翻译成两路下游动作:
//     ① 图片跳转 : 题目页 → 跳当前题图; 锁定 → 跳对应队伍图;
//                   结束 → 跳结束页;
//     ② 转场触发 : 与图片跳转同拍发出中心扩散(iris)转场请求。
//
//   ★布局约定(2026-10-09 用户重排, 卡上 QUIZ 连排 8 张):
//     QUIZ1.BMP = 第 1 题        (jump_idx 0)
//     QUIZ2.BMP = 第 2 题        (jump_idx 1)
//     QUIZ3.BMP = 第 3 题        (jump_idx 2)
//     QUIZ4.BMP = 1 号队伍图(红) (jump_idx 3)
//     QUIZ5.BMP = 2 号队伍图(蓝) (jump_idx 4)
//     QUIZ6.BMP = 3 号队伍图(绿) (jump_idx 5)
//     QUIZ7.BMP = 4 号队伍图(黄) (jump_idx 6)
//     QUIZ8.BMP = 比赛结束页      (jump_idx 7)
//   → 题目: jump_idx = q_idx (0..Q_TOTAL-1)
//     队伍: jump_idx = winner + 3 (3..6)
//     结束: jump_idx = 7
//
//   ★为何用"绝对跳图"(bmp_read_auto.key_jump)而不是重新 zone_load:
//     重新 zone_load 会触发 fat32_lookup 重扫根目录(MBR+BPB+32 扇区),
//     期间 bmp_go=0 冻结画面数十 µs, 与"反应速度尽可能小"冲突。
//     QUIZ 分区一次查表即得全部 8 张的 min/max/count(z_max=8), 跳转
//     只需在这 8 张里跳序号 → 零额外查表、切换即时。
//
//   ★时序: 本模块与 quiz_ctrl/bmp_read_auto 同在 sd_card_clk(100MHz)域,
//     无跨时钟域问题, 纯同步逻辑。
//   ★iris_trig 为什么是"电平翻转(toggle)"而不是"单拍脉冲":
//     本模块在 100MHz 域, 而 display_adjust 在 ~25MHz 像素域。单拍脉冲
//     (10ns) 窄于 25MHz 采样周期, 过域时可能整个被漏采(经典 CDC 丢脉冲)。
//     故采用小鹅通第十讲的标准做法: 用 toggle 电平, 每次事件翻转一次;
//     下游 2FF 同步后检测电平变化 → 产生该域的单拍事件。
//     (jump_req 仍用单拍脉冲: 它留在 100MHz 同域, 不经跨域。)
//
//   ★防重入: jump_req / iris_trig 只在"目标图序号发生变化"那一拍发出,
//     同一张图持续显示期间不重复发。
//====================================================================

`timescale 1ns/1ps

module quiz_scene_ctrl (
    input               clk,          // sd_card_clk (100MHz)
    input               rst,          // 高有效复位
    // ---- 抢答状态(来自 quiz_ctrl, 同域) ----
    input               en,           // 1=当前处于抢答场景
    input       [1:0]   qstate,       // 0=IDLE 1=RUN 2=LOCK 3=TIMEUP
    input       [1:0]   winner,       // 0..3 (胜者; 仅 LOCK 时有效)
    input       [3:0]   q_idx,        // 当前题号 0..Q_TOTAL-1
    input               q_end,        // 1=已到结束页(跳 QUIZ8)
    // ---- 输出: 图片跳转 ----
    output reg          jump_req,     // 单拍脉冲 → bmp_read_auto.key_jump
    output reg  [3:0]   jump_idx,     // 目标图序号(0 基; 见上方布局约定)
    // ---- 输出: 转场(toggle 电平, 下游 2FF 同步后取边沿) ----
    output reg          iris_trig,    // 电平翻转 → display_adjust.iris_trig
    // ---- 输出: 状态观测(供调试/数码管扩展) ----
    output reg          locked        // 1=已在队伍图态
);

    localparam [1:0] Q_IDLE = 2'd0, Q_RUN = 2'd1, Q_LOCK = 2'd2, Q_TIMEUP = 2'd3;

    // ---- 目标图序号组合计算 ----
    //   优先级: 结束页 > 锁定(队伍图) > 题目图
    wire [3:0] tgt_idx = q_end                  ? 4'd7 :
                         (qstate == Q_LOCK)     ? ({2'b0, winner} + 4'd3) :
                                                   q_idx;

    reg [3:0] tgt_d;                    // 上一拍目标索引(用于边沿检测)
    reg       end_d;
    reg       lock_d;
    reg       en_d;                     // 上一拍场景使能(进入场景检测)

    wire idx_chg = (tgt_idx != tgt_d);  // 目标图变化 → 需跳图
    // ★进入抢答场景的"首屏对齐": en 由 0→1 时, 目标索引未必变化(都是 0),
    //   若不强制跳一次, 底层可能仍停在上一场景的残留图。故场景进入沿也发跳图。
    wire en_rise = en && ~en_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tgt_d     <= 4'd0;
            end_d     <= 1'b0;
            lock_d    <= 1'b0;
            en_d      <= 1'b0;
            jump_req  <= 1'b0;
            jump_idx  <= 4'd0;
            iris_trig <= 1'b0;
            locked    <= 1'b0;
        end
        else begin
            tgt_d    <= tgt_idx;
            end_d    <= q_end;
            lock_d   <= (qstate == Q_LOCK);
            en_d     <= en;
            jump_req <= 1'b0;      // 默认拉低(单拍脉冲)

            // 抢答场景内: 目标图变化 或 刚进入场景 → 跳图
            if (en && (idx_chg || en_rise)) begin
                jump_idx  <= tgt_idx;
                jump_req  <= 1'b1;
                iris_trig <= ~iris_trig;    // 翻转 → 下游取边沿
            end

            // locked 观测: 进入锁定(队伍图)置位, 离开(下一题/结束/复位)清零
            if (!en)
                locked <= 1'b0;
            else if (qstate == Q_LOCK)
                locked <= 1'b1;
            else if (idx_chg)
                locked <= 1'b0;
        end
    end

endmodule
