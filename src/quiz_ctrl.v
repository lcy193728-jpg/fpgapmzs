//====================================================================
// 模块名 : quiz_ctrl.v —— 抢答场景控制(流程状态机 + 4 路仲裁 + 倒计时 + 计分)
//
// 变更史 : 2026-10-09 按用户新流程大改。原版只有
//          IDLE/RUN/LOCK/TIMEUP 四态, 无判定/无计分/无题号;
//          本版新增: 题号推进、评委判对错计分、结束页钳位。
//
// 新流程(用户 2026-10-09 定稿):
//   Q_IDLE  : 显示当前题图(QUIZ[题号]), 等待评委按【白色按钮】开始
//   白色按钮(start_raw) → Q_RUN(倒计时, 显示剩余秒)
//   Q_RUN   : 选手按抢答键 → Q_LOCK(跳对应队伍图); 倒计时归零 → Q_TIMEUP
//   Q_LOCK  : 评委用板载 KEY2/KEY3 在「抢答计分」模式判错(-1)/判对(+2);
//             分数板弹 1 秒; 评委按【黑色按钮】播报下一题
//   Q_TIMEUP: 无人抢答; 评委按【黑色按钮】播报下一题
//   下一题: 题号 +1; 若还有题 → 回 Q_IDLE 显示新题图;
//           若 Q_TOTAL 题已完 → 进 Q_END(跳结束页 QUIZ8, 累计总分)
//   Q_END   : 显示结束页; 此时白/黑按钮均不再有任何动作(钳位)
//
// ★为何用独立的 3bit 内部状态 fs 而不是复用 2bit qstate:
//   2bit qstate 只有 4 个编码, 已被 IDLE/RUN/LOCK/TIMEUP 占满, 无法再表达
//   "已经走到结束页"这一终态。若把结束态折回 Q_IDLE, 下游 quiz_scene_ctrl
//   的 enter_idle 边沿检测会误判为"回内容图" → 跳到 QUIZ1 而不是结束页。
//   故本模块内部用 3bit fs 完整表达 5 个状态, qstate 仅作为兼容输出
//   (Q_END 对外呈现为 Q_IDLE, 由独立的 q_end 标志区分)。
//
// 计分: 答对 +2 / 答错 -1, 4 队分数**累计**。以 8bit 有符号保存
//       (3 题内范围约 -3..+6, 8bit 充裕)。判分只在 Q_LOCK 态有效,
//       由「计分」模式档的 KEY3(+/判对) / KEY2(-/判错) 驱动。
//
// 键位:
//   外扩口(上拉高/按下低):
//     player_raw[3:0] = 4 路选手抢答键(对应屏显 1~4 号)
//     start_raw       = 【白色按钮】开始抢答
//     next_raw        = 【黑色按钮】播报下一题
//   板载(经 ui_key_ctrl 消抖后的**电平**, 已同步到 sd_card_clk 域):
//     judge_up_lv     = KEY3 在「计分」档的按下电平 → 判对(+SC_UP)
//     judge_dn_lv     = KEY2 在「计分」档的按下电平 → 判错(SC_DN)
//     按住时本模块按 100ms 节拍重复判定(见下方 REPEAT 节拍说明)。
//
// 场景门控 en: 仅在抢答场景(latch_sw==3)且非应急时为 1;
//   en=0 时强制回 Q_IDLE / 题号清 0 / 分数清 0, 选手与评委按键全部无效。
//
// 时钟域 : sd_card_clk(100MHz), 与 scene_control / bmp 控制域一致。
// 语言   : 纯 Verilog-2001(兼容 TD EDA 前台与 ModelSim)。
//====================================================================

`timescale 1ns/1ps

module quiz_ctrl #(
    parameter [20:0] DEB_MAX     = 21'd2_000_000,   // 消抖 20ms@100MHz
    parameter [26:0] SEC_CNT_MAX = 27'd99_999_999,  // 1 秒@100MHz
    parameter [7:0]  TIME_SEC    = 8'd10,           // 倒计时秒数(0~99)
    parameter [3:0]  Q_TOTAL     = 4'd3,            // 题目总数(与卡上题目图张数一致)
    parameter signed [7:0] SC_UP  = 8'sd2,          // 答对加分
    parameter signed [7:0] SC_DN  = -8'sd1,         // 答错扣分
    // 评委判分"按住连判"节拍: 100ms@100MHz → 10_000_000-1
    parameter [23:0] RPT_MAX = 24'd9_999_999
)(
    input               clk,            // sd_card_clk(100MHz)
    input               rst,            // 高有效复位
    input               en,             // 1=抢答场景生效(否则强制空闲)
    // ---- 外扩口输入(上拉高/按下低) ----
    input       [3:0]   player_raw,     // 4 路选手抢答键
    input               start_raw,      // 【白色按钮】开始抢答
    input               next_raw,       // 【黑色按钮】播报下一题
    // ---- 板载评委判定脉冲(来自 ui_key_ctrl「计分」档, 已在同域) ----
    //   改由 **按下电平(judge_up_lv/judge_dn_lv)** + 本模块内部 100ms 节拍
    //   产生判定: 在 F_LOCK 态按住即按 **每 100ms 一次** 连续判分(首判为按下
    //   瞬间), 松开即停。原"单次按下 1 拍脉冲"的写法在跨域后只剩 10ns,
    //   硬件上必然丢失(见 top_final 跨域说明), 故改电平握手。
    //   ★repeat 未在本模块实现(原工程即未实现), 本次仅把"判定"改为电平节拍。
    input               judge_up_lv,    // KEY3 → 判对(+SC_UP) 电平
    input               judge_dn_lv,    // KEY2 → 判错(SC_DN) 电平
    // ---- 状态输出(供 osd_scene / quiz_scene_ctrl 使用) ----
    output reg  [1:0]   qstate,         // 0=待开始 1=抢答中 2=已锁定 3=超时
    output reg  [1:0]   winner,         // 胜者 0..3(屏显 +1 = 1~4 号)
    output reg  [3:0]   t_tens,         // 剩余秒 BCD 十位
    output reg  [3:0]   t_ones,         // 剩余秒 BCD 个位
    // ---- 题目/结束 状态 ----
    output reg  [3:0]   q_idx,          // 当前题号 0..Q_TOTAL-1
    output reg          q_end,          // 1=已到结束页(不再跳转)
    // ---- 计分(4 队累计, 8bit 有符号) ----
    output reg signed [7:0] sc0, sc1, sc2, sc3,
    // ---- 分数板触发(toggle 电平, 每次判分翻转一次, 供 HUD 弹 1 秒) ----
    //   ★为何用 toggle 而不是单拍脉冲: 本模块在 100MHz 域, 分数板 HUD 在
    //     ~25MHz 像素域。单拍脉冲(10ns) 窄于像素域采样周期(40ns), 直接过域
    //     有大概率被漏采(经典 CDC 丢脉冲)。用 toggle 电平(每次判分翻转一次),
    //     下游 2FF 同步后检测变化 → 必然采到一次, 天然免疫脉宽问题。
    //     (与 quiz_scene_ctrl 的 iris_trig 同一做法, 见小鹅通第十讲。)
    output reg          score_tog,      // 判分电平翻转(每次判分翻转一次)
    output reg  [1:0]   score_team      // 本次被判队伍 0..3
);

    //--------------------------------------------------------------
    // 内部状态编码(3bit, 5 态)
    //--------------------------------------------------------------
    localparam [2:0] F_IDLE  = 3'd0,    // 待开始(显示题目)
                     F_RUN   = 3'd1,    // 抢答中(倒计时)
                     F_LOCK  = 3'd2,    // 已锁定(显示队伍图, 等判定)
                     F_TIMEUP= 3'd3,    // 无人抢答
                     F_END   = 3'd4;    // 结束页(钳位)

    localparam [1:0] Q_IDLE = 2'd0, Q_RUN = 2'd1, Q_LOCK = 2'd2, Q_TIMEUP = 2'd3;

    localparam [3:0] TS_TENS = TIME_SEC / 8'd10;
    localparam [3:0] TS_ONES = TIME_SEC % 8'd10;

    reg [2:0] fs;                        // 内部状态

    //--------------------------------------------------------------
    // 3 路外扩口输入消抖(4 选手 + 开始 + 下一题)
    //   raw6 位序: [5]=next [4]=start [3:0]=player
    //--------------------------------------------------------------
    wire [5:0] raw6 = {next_raw, start_raw, player_raw};
    wire [5:0] pl6;                     // 按下(下降沿)单周期脉冲

    generate
        genvar g;
        for (g = 0; g < 6; g = g + 1) begin : G_DB
            key_debounce #(.DEB_MAX(DEB_MAX)) u_dbg (
                .clk            (clk),
                .rst            (rst),
                .key_raw        (raw6[g]),
                .key_low_stable (),
                .negedge_pulse  (pl6[g])
            );
        end
    endgenerate

    wire [3:0] pl_player = pl6[3:0];
    wire       pl_start  = pl6[4];
    wire       pl_next   = pl6[5];

    //--------------------------------------------------------------
    // 并行仲裁: 仅"抢答中"窗口内采样; 同拍多路有效按 1>2>3>4 裁定
    //--------------------------------------------------------------
    wire       q_run  = en & (fs == F_RUN);
    wire [3:0] hit    = pl_player & {4{q_run}};
    wire       hit_any = |hit;

    reg [1:0] hit_sel;
    always @(*) begin
        if      (hit[0]) hit_sel = 2'd0;   // 选手 1 号最高优先
        else if (hit[1]) hit_sel = 2'd1;
        else if (hit[2]) hit_sel = 2'd2;
        else             hit_sel = 2'd3;
    end

    wire st_pl = pl_start & en & (fs == F_IDLE);       // 白色按钮: 仅待开始态有效
    wire nx_pl = pl_next  & en & ((fs == F_LOCK) || (fs == F_TIMEUP)); // 黑色按钮: 锁定/超时后

    //--------------------------------------------------------------
    // 评委判定: 按下**电平**(judge_up_lv/judge_dn_lv) + 100ms 节拍
    //   · 本模块时钟 = sd_card_clk(100MHz) → REPEAT_MAX = 10_000_000 - 1
    //   · 节拍计数器与"是否有键按住"绑定: 有键按住才跑, 一松开立刻清零
    //     ⇒ 下次按下时计数器 = 0 → 首判在按下当拍产生(按键响应无延迟)
    //   · 在 F_LOCK 态: 每 100ms 判一次(按住可连按, 手感同键盘重复)
    //   · 已判过一队后(状态机离开 F_LOCK)节拍自然失效, 不会重复加分
    //   ★为什么改电平: 原端口吃的是"按下单周期脉冲"(10ns), 由顶层从
    //     ui_key_ctrl(sd_card_clk 域)直接跨到本模块 —— 虽然同频同源, 但
    //     两级同步器会把 10ns 窄脉冲整个滤掉(采样不到) ⇒ 实机按键无效。
    //     改用电平后无窄脉冲跨域问题, 且顺带获得"按住连判"能力。
    //--------------------------------------------------------------
    wire        judge_any = judge_up_lv | judge_dn_lv;
    reg  [23:0] rpt_cnt;
    wire        rpt_tick = (rpt_cnt == RPT_MAX);
    always @(posedge clk or posedge rst) begin
        if (rst)
            rpt_cnt <= 24'd0;
        else if (~judge_any)
            rpt_cnt <= 24'd0;                  // 松开 → 重置(下次按下即首判)
        else if (rpt_tick)
            rpt_cnt <= 24'd0;
        else
            rpt_cnt <= rpt_cnt + 24'd1;
    end

    wire ju_pl = judge_up_lv & en & (fs == F_LOCK) & rpt_tick;   // 判对
    wire jd_pl = judge_dn_lv & en & (fs == F_LOCK) & rpt_tick;   // 判错

    //--------------------------------------------------------------
    // 1Hz 计时基准(以"开始"沿重新起计, 保证首秒完整)
    //--------------------------------------------------------------
    reg [26:0] sec_cnt;
    reg        tick;
    wire       timer_rst = st_pl & (fs != F_RUN);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sec_cnt <= 27'd0;
            tick    <= 1'b0;
        end
        else if (timer_rst) begin
            sec_cnt <= 27'd0;
            tick    <= 1'b0;
        end
        else if (sec_cnt >= SEC_CNT_MAX) begin
            sec_cnt <= 27'd0;
            tick    <= 1'b1;
        end
        else begin
            sec_cnt <= sec_cnt + 27'd1;
            tick    <= 1'b0;
        end
    end

    //--------------------------------------------------------------
    // 状态机 + BCD 倒计时 + 题号 + 计分
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fs <= F_IDLE;
            winner <= 2'd0;
            t_tens <= TS_TENS;
            t_ones <= TS_ONES;
            q_idx  <= 4'd0;
            q_end  <= 1'b0;
            sc0 <= 8'sd0; sc1 <= 8'sd0; sc2 <= 8'sd0; sc3 <= 8'sd0;
            score_tog  <= 1'b0;
            score_team <= 2'd0;
        end
        else if (!en) begin                  // 离开抢答场景: 全部复位
            fs <= F_IDLE;
            winner <= 2'd0;
            t_tens <= TS_TENS;
            t_ones <= TS_ONES;
            q_idx  <= 4'd0;
            q_end  <= 1'b0;
            sc0 <= 8'sd0; sc1 <= 8'sd0; sc2 <= 8'sd0; sc3 <= 8'sd0;
            score_tog  <= 1'b0;
            score_team <= 2'd0;
        end
        else begin

            case (fs)
                //----------------------------------------------
                // 待开始: 显示当前题图, 等白色按钮
                //----------------------------------------------
                F_IDLE: begin
                    winner <= 2'd0;
                    t_tens <= TS_TENS;
                    t_ones <= TS_ONES;
                    if (st_pl)
                        fs <= F_RUN;
                end

                //----------------------------------------------
                // 抢答中: 倒计时 / 选手抢答
                //----------------------------------------------
                F_RUN: begin
                    if (hit_any) begin           // 先到先得, 锁存胜者
                        fs     <= F_LOCK;
                        winner <= hit_sel;
                    end
                    else if (tick) begin         // 倒计时递减
                        if (t_ones == 4'd0) begin
                            if (t_tens == 4'd0)
                                fs <= F_TIMEUP;              // 已到 00
                            else begin
                                t_tens <= t_tens - 4'd1;
                                t_ones <= 4'd9;
                            end
                        end
                        else if ((t_tens == 4'd0) && (t_ones == 4'd1)) begin
                            fs     <= F_TIMEUP;              // 1 → 0 即超时
                            t_ones <= 4'd0;
                        end
                        else
                            t_ones <= t_ones - 4'd1;
                    end
                end

                //----------------------------------------------
                // 已锁定: 显示队伍图, 等评委判定 + 黑色按钮下一题
                //----------------------------------------------
                F_LOCK: begin
                    if (ju_pl || jd_pl) begin
                        score_team <= winner;
                        score_tog  <= ~score_tog;   // 翻转 → 下游取边沿
                        case (winner)
                            2'd0: sc0 <= sc0 + (ju_pl ? SC_UP : SC_DN);
                            2'd1: sc1 <= sc1 + (ju_pl ? SC_UP : SC_DN);
                            2'd2: sc2 <= sc2 + (ju_pl ? SC_UP : SC_DN);
                            default: sc3 <= sc3 + (ju_pl ? SC_UP : SC_DN);
                        endcase
                    end
                    else if (nx_pl) begin        // 黑色按钮 = 下一题
                        winner <= 2'd0;
                        t_tens <= TS_TENS;
                        t_ones <= TS_ONES;
                        if (q_idx >= (Q_TOTAL - 4'd1)) begin
                            fs    <= F_END;      // 题已答完 → 结束页
                            q_end <= 1'b1;
                        end
                        else begin
                            q_idx <= q_idx + 4'd1;
                            fs    <= F_IDLE;
                        end
                    end
                end

                //----------------------------------------------
                // 超时(无人抢答): 等黑色按钮下一题
                //----------------------------------------------
                F_TIMEUP: begin
                    if (nx_pl) begin
                        winner <= 2'd0;
                        t_tens <= TS_TENS;
                        t_ones <= TS_ONES;
                        if (q_idx >= (Q_TOTAL - 4'd1)) begin
                            fs    <= F_END;
                            q_end <= 1'b1;
                        end
                        else begin
                            q_idx <= q_idx + 4'd1;
                            fs    <= F_IDLE;
                        end
                    end
                end

                //----------------------------------------------
                // 结束页: 钳位, 任何键都不再动作
                //----------------------------------------------
                default: begin                   // F_END
                    fs <= F_END;
                end
            endcase
        end
    end

    //--------------------------------------------------------------
    // qstate 兼容输出(供 osd_scene 判状态)
    //   F_END 对外呈现为 Q_IDLE(结束页画面由 q_end 独立驱动跳图)
    //--------------------------------------------------------------
    always @(*) begin
        case (fs)
            F_IDLE  : qstate = Q_IDLE;
            F_RUN   : qstate = Q_RUN;
            F_LOCK  : qstate = Q_LOCK;
            F_TIMEUP: qstate = Q_TIMEUP;
            default : qstate = Q_IDLE;       // F_END
        endcase
    end

endmodule
