//====================================================================
// 模块名 : meeting_ctrl.v —— 会议场景「议程状态机 + 单场倒计时」
//          (2026-10-09j 新增; 2026-10-09o 增加"全部会议结束→空闲"停留态)
//
// 定位(用户 2026-10-09 指定, 产品化会议场景):
//   "无人值守智能会议议程屏" —— 会议场景(拨码 SW2 / scene_id==1)显示
//   预置在 TF 卡的 3 张议程图(MEET1..3.BMP), FPGA 在图上叠加「状态条 +
//   精确倒计时 + 进度条」, 每场会议 20s(演示缩短), 归零自动切下一场。
//
// 四个状态:
//   IDLE  空闲     —— 未开会 / 会议全部结束(倒计时 0, 绿条)
//   RUN   会议中   —— 红条, 倒计时 MEET_SEC→0 逐秒递减
//   WARN  即将结束 —— 黄条 + 提示音, 剩余 ≤ WARN_SEC(3s) 时进入
//   NEXT  切下一场 —— 归零瞬态(1 拍), 发 next_pl 后按场次决定去哪
//
// ★2026-10-09o 变更(用户需求: "会议全部走完 → 加一个空闲/无会议状态"):
//   · 本模块**自行计场次**(MEET_NUM 场, 默认 3, 与卡上 MEET1..3.BMP 一致):
//     每切一场(自动归零 / 手动切场)场次 +1;
//   · 走满 MEET_NUM 场后 → 回 S_IDLE **并停留**(绿条 + 00:00 + 停在末图),
//     不再自动开跑, 也不切图(这正是"没会议"的空闲态);
//   · 重新开始 = 拨码离开会议场景再拨回(scene_en 0→1 时重置场次并开跑第 1 场)。
//   ⚠ 只改本模块(新增计数 + S_IDLE 分流); osd/顶层接线一字未动 ——
//     IDLE 态在 meeting_osd 里本就是"绿条 + 显示当前秒数", sec=0 即 00:00。
//
// 关键点:
//   · 进入会议场景(scene_en 0→1)自动开跑第 1 场, 无需按键;
//   · 倒计时归零 → next_pl(1 拍脉冲) → 顶层驱动 bmp_read_auto 切下一张;
//   · 手动 KEY3(下一场)/KEY2(上一场) → 重置倒计时重新 20s 计, 也计入场次;
//   · 倒计时是【硬件计数器】(100MHz 逐拍计数), 帧级精确 —— 这正是
//     区别于"软件 timer"的 FPGA 优势落点(答辩"更确定的时序")。
//
// 时钟域: sd_card_clk(100MHz), 与 scene_control/ui_key_ctrl/sd_card_bmp 同域,
//   输出电平/脉冲直接可用, 无需跨域。
// 语言: 纯 Verilog-2001。
//====================================================================
`timescale 1ns/1ps

module meeting_ctrl #(
    parameter [5:0]  MEET_SEC   = 6'd20,          // 单场会议秒数(演示用 20s)
    parameter [5:0]  WARN_SEC   = 6'd3,           // 剩余 ≤ 该值进入 WARN(黄条+提示音)
    parameter [3:0]  MEET_NUM   = 4'd3,           // ★本模块时钟场次数(卡上 MEET1..3, 走完进空闲)
    parameter [31:0] CLK_FREQ   = 32'd100_000_000 // 本模块时钟 = sd_card_clk(100MHz)
)(
    input               clk,                       // sd_card_clk(100MHz)
    input               rst,                       // 高电平有效复位
    input               scene_en,                  // 1 = 会议场景(拨码 SW2, 顶层已寄存)
    input               key_next,                  // 手动下一场(KEY3, 单周期脉冲)
    input               key_prev,                  // 手动上一场(KEY2, 单周期脉冲)
    output reg  [1:0]   state,                     // 0=IDLE 1=RUN 2=WARN 3=NEXT
    output reg  [5:0]   sec_left,                  // 剩余秒数(0..MEET_SEC)
    output reg          next_pl,                   // 归零切下一场脉冲(1 拍)
    output reg          meet_active,               // 1 = 会议进行中(RUN/WARN)
    output wire         warn_active,               // 1 = WARN 期间(提示音, 组合逻辑)
    output reg          warn_tog,                  // ★进入 WARN 的 toggle(触发提示音, 2026-10-09l)
    output reg          wipe_trig                  // ★左→右 Wipe 转场触发(toggle, 每次切场翻转)
);

    localparam [1:0] S_IDLE = 2'd0,
                     S_RUN  = 2'd1,
                     S_WARN = 2'd2,
                     S_NEXT = 2'd3;

    assign warn_active = (state == S_WARN);

    // 1 秒节拍: 100MHz 下 0..99_999_999 计满 = 1s
    reg [31:0] tick_cnt;
    wire       tick_1s = (tick_cnt >= (CLK_FREQ - 32'd1));

    // ★2026-10-09o 场次计数: 已开过的场数(1..MEET_NUM)
    //   进入场景时重置为 1(第 1 场); 每切一场 +1; 达到 MEET_NUM 后
    //   再切就进 IDLE(空闲) —— 与卡上 MEET1..3.BMP 张数一致。
    reg [3:0]  meet_idx;
    // 场景使能上升沿检测(离开→回来 才重新开跑)
    reg        en_d;
    wire       en_rise = scene_en & ~en_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= S_IDLE;
            sec_left    <= 6'd0;
            tick_cnt    <= 32'd0;
            next_pl     <= 1'b0;
            meet_active <= 1'b0;
            warn_tog    <= 1'b0;
            wipe_trig   <= 1'b0;
            meet_idx    <= 4'd0;
            en_d        <= 1'b0;
        end
        else begin
            next_pl <= 1'b0;            // 脉冲默认 0, 只在切场瞬间拉 1 拍
            en_d    <= scene_en;

            if (!scene_en) begin
                // 离开会议场景(或不在会议): 回空闲, 倒计时归零, 场次清零
                state       <= S_IDLE;
                sec_left    <= 6'd0;
                tick_cnt    <= 32'd0;
                meet_active <= 1'b0;
                meet_idx    <= 4'd0;
            end
            else if (en_rise) begin
                // ★进入会议场景(scene_en 0→1): 重置并自动开跑第 1 场
                state       <= S_RUN;
                sec_left    <= MEET_SEC;
                tick_cnt    <= 32'd0;
                meet_active <= 1'b1;
                meet_idx    <= 4'd1;         // 第 1 场
            end
            else case (state)

            //---------------- 空闲: 会议全部结束(或刚复位) ----------------
            //   停留态: 不自动开跑。只有 scene_en 的 0→1 上升沿(上面 en_rise
            //   分支)才重新开始 —— 即"拨码离开再拨回"。
            S_IDLE: begin
                sec_left    <= 6'd0;
                meet_active <= 1'b0;
            end

            //---------------- 会议中: 倒计时递减, 剩 ≤WARN_SEC 转 WARN ----------------
            S_RUN: begin
                if (key_next || key_prev) begin
                    // 手动切议程: 重置倒计时(重新 20s), 计为下一场
                    sec_left    <= MEET_SEC;
                    tick_cnt    <= 32'd0;
                    meet_active <= 1'b1;
                    wipe_trig   <= ~wipe_trig;    // 切场 → 触发 Wipe 转场
                    if (meet_idx < MEET_NUM) meet_idx <= meet_idx + 4'd1;
                    else                     state    <= S_IDLE;  // 已到末场再切 → 空闲
                end
                else if (tick_1s) begin
                    tick_cnt <= 32'd0;
                    if (sec_left <= 6'd1) begin
                        // 归零 → 切下一场
                        state <= S_NEXT;
                    end
                    else begin
                        sec_left <= sec_left - 6'd1;
                        if ((sec_left - 6'd1) <= WARN_SEC) begin
                            state    <= S_WARN;      // 剩 ≤3s → 即将结束
                            warn_tog <= ~warn_tog;   // 进入 WARN → 触发提示音
                        end
                    end
                end
                else begin
                    tick_cnt <= tick_cnt + 32'd1;
                end
            end

            //---------------- 即将结束: 黄条 + 提示音, 继续倒计时 ----------------
            S_WARN: begin
                if (key_next || key_prev) begin
                    sec_left    <= MEET_SEC;
                    tick_cnt    <= 32'd0;
                    state       <= S_RUN;         // 手动切走 → 回 RUN
                    wipe_trig   <= ~wipe_trig;    // 切场 → 触发 Wipe 转场
                    if (meet_idx < MEET_NUM) meet_idx <= meet_idx + 4'd1;
                    else                     state    <= S_IDLE;  // 已到末场再切 → 空闲
                end
                else if (tick_1s) begin
                    tick_cnt <= 32'd0;
                    if (sec_left <= 6'd1) begin
                        state <= S_NEXT;          // 归零 → 切下一场
                    end
                    else begin
                        sec_left <= sec_left - 6'd1;
                    end
                end
                else begin
                    tick_cnt <= tick_cnt + 32'd1;
                end
            end

            //---------------- 切场: 1 拍脉冲, 按场次决定 → 下一场 或 → 空闲 ----------------
            //   ★2026-10-09o: 已走满 MEET_NUM 场 → 进 IDLE(空闲/无会议),
            //     不再切图(不发 next_pl); 否则切下一张并重新计时。
            S_NEXT: begin
                if (meet_idx >= MEET_NUM) begin
                    // 全部会议结束 → 空闲态, 停在末图, 发 00:00
                    state       <= S_IDLE;
                    sec_left    <= 6'd0;
                    tick_cnt    <= 32'd0;
                    meet_active <= 1'b0;
                end
                else begin
                    next_pl     <= 1'b1;              // 驱动 bmp_read_auto 下一张
                    sec_left    <= MEET_SEC;
                    tick_cnt    <= 32'd0;
                    state       <= S_RUN;
                    meet_active <= 1'b1;
                    meet_idx    <= meet_idx + 4'd1;   // 进入第 N+1 场
                    wipe_trig   <= ~wipe_trig;        // 切场 → 触发 Wipe 转场
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // WARN 期间提示音(顶层接 DDS; 其余状态静音)
    //   warn_active = (state == S_WARN), 组合逻辑(见上方 assign), 零延迟。

endmodule
