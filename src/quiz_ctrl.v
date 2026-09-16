//====================================================================
// 模块名 : quiz_ctrl.v —— 抢答场景控制(4 路并行仲裁 + 倒计时)
// 来源   : 移植 dev_sim 分支 quiz_arbiter_4ch / quiz_timer / quiz_ctrl
//          三个仿真模块, 按本工程约定(纯 Verilog-2001 / 现有消抖风格 /
//          BCD 输出便于 2× 数字叠加)合并为单模块。
//
// 功能:
//   · 4 路选手键(player_raw, 上拉高/按下低)同步采样 + 20ms 消抖;
//   · 片内硬件**并行仲裁**: 同一采样周期内多路同时有效时按
//     player1 > player2 > player3 > player4 的预定义优先级裁定,
//     锁存胜者后**后续按键一律忽略**(先到先得);
//   · 倒计时 TIME_SEC 秒(BCD 输出 tens/ones), 归零即判"时间到";
//   · 状态机: 0=等待开始 1=抢答中 2=已锁定 3=超时。
//
// 按键链路(与工程统一电平约定一致): 两级同步 → 计数器消抖
//   (复用 scene_control.v 内的 key_debounce 子模块, 全工程唯一实例定义)
//   → 取"按下(下降沿)"单周期脉冲。
//
// 键位(抢答台, 经 2×40Pin 外扩口接入, 引脚见 top.adc):
//   player_raw[3:0] = 4 路选手抢答键(对应屏显 1~4 号)
//   start_raw       = 开始/下一轮(抢答中再按=重开本轮计时)
//   clear_raw       = 复位/清除(回到"等待开始")
//
// 场景门控 en: 仅在抢答场景(latch_sw==3)且非应急时为 1;
//   en=0 时强制回"等待开始"并清零胜者, 选手按键完全无效。
//
// 时钟域 : sd_card_clk(100MHz), 与 scene_control / bmp 控制域一致。
// 语言   : 纯 Verilog-2001(兼容 TD EDA 前台与 ModelSim)。
//====================================================================

`timescale 1ns/1ps

module quiz_ctrl #(
    parameter [20:0] DEB_MAX     = 21'd2_000_000,   // 消抖 20ms@100MHz
    parameter [26:0] SEC_CNT_MAX = 27'd99_999_999,  // 1 秒@100MHz
    parameter [7:0]  TIME_SEC    = 8'd10            // 倒计时秒数(0~99)
)(
    input               clk,            // sd_card_clk(100MHz)
    input               rst,            // 高有效复位
    input               en,             // 1=抢答场景生效(否则强制空闲)
    // ---- 抢答台输入(外扩口, 上拉高/按下低) ----
    input       [3:0]   player_raw,     // 4 路选手抢答键
    input               start_raw,      // 开始/下一轮
    input               clear_raw,      // 复位/清除
    // ---- 状态输出(供 osd_scene 叠加显示) ----
    output reg  [1:0]   qstate,         // 0=等待开始 1=抢答中 2=已锁定 3=超时
    output reg  [1:0]   winner,         // 胜者 0..3(屏显 +1 = 1~4 号)
    output reg  [3:0]   t_tens,         // 剩余秒 BCD 十位
    output reg  [3:0]   t_ones          // 剩余秒 BCD 个位
);

    //--------------------------------------------------------------
    // 状态编码 与 倒计时初值(BCD, 常量折叠)
    //--------------------------------------------------------------
    localparam [1:0] Q_IDLE = 2'd0,     // 等待开始
                     Q_RUN  = 2'd1,     // 抢答中
                     Q_LOCK = 2'd2,     // 已锁定
                     Q_TIMEUP = 2'd3;   // 时间到

    localparam [3:0] TS_TENS = TIME_SEC / 8'd10;
    localparam [3:0] TS_ONES = TIME_SEC % 8'd10;

    //--------------------------------------------------------------
    // 6 路输入消抖(4 选手 + 开始 + 复位)
    //   raw6 位序: [5]=clear [4]=start [3:0]=player
    //--------------------------------------------------------------
    wire [5:0] raw6 = {clear_raw, start_raw, player_raw};
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
    wire       pl_clear  = pl6[5];

    //--------------------------------------------------------------
    // 并行仲裁: 仅"抢答中"窗口内采样; 同拍多路有效按 1>2>3>4 裁定
    //--------------------------------------------------------------
    wire       q_run = en & (qstate == Q_RUN);
    wire [3:0] hit   = pl_player & {4{q_run}};
    wire       hit_any = |hit;

    reg [1:0] hit_sel;
    always @(*) begin
        if      (hit[0]) hit_sel = 2'd0;   // 选手 1 号最高优先
        else if (hit[1]) hit_sel = 2'd1;
        else if (hit[2]) hit_sel = 2'd2;
        else             hit_sel = 2'd3;
    end

    wire st_pl = pl_start & en;
    wire cl_pl = pl_clear & en;

    //--------------------------------------------------------------
    // 1Hz 计时基准(以"开始"沿重新起计, 保证首秒完整)
    //--------------------------------------------------------------
    reg [26:0] sec_cnt;
    reg        tick;
    wire       timer_rst = st_pl & (qstate != Q_RUN);

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
    // 状态机 + BCD 倒计时
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            qstate <= Q_IDLE;
            winner <= 2'd0;
            t_tens <= TS_TENS;
            t_ones <= TS_ONES;
        end
        else if (!en) begin                      // 离开抢答场景: 强制空闲
            qstate <= Q_IDLE;
            winner <= 2'd0;
            t_tens <= TS_TENS;
            t_ones <= TS_ONES;
        end
        else begin
            case (qstate)
                Q_IDLE: begin
                    winner <= 2'd0;
                    t_tens <= TS_TENS;
                    t_ones <= TS_ONES;
                    if (st_pl)
                        qstate <= Q_RUN;
                end

                Q_RUN: begin
                    if (st_pl) begin             // 抢答中再按开始 = 重开本轮
                        t_tens <= TS_TENS;
                        t_ones <= TS_ONES;
                    end
                    else if (hit_any) begin      // 先到先得, 锁存胜者
                        qstate <= Q_LOCK;
                        winner <= hit_sel;
                    end
                    else if (tick) begin         // 倒计时递减
                        if (t_ones == 4'd0) begin
                            if (t_tens == 4'd0)
                                qstate <= Q_TIMEUP;          // 已到 00
                            else begin
                                t_tens <= t_tens - 4'd1;
                                t_ones <= 4'd9;
                            end
                        end
                        else if ((t_tens == 4'd0) && (t_ones == 4'd1)) begin
                            qstate <= Q_TIMEUP;              // 1 → 0 即超时
                            t_ones <= 4'd0;
                        end
                        else
                            t_ones <= t_ones - 4'd1;
                    end
                end

                default: begin                   // Q_LOCK / Q_TIMEUP
                    if (cl_pl) begin             // 复位 → 等待开始
                        qstate <= Q_IDLE;
                        winner <= 2'd0;
                        t_tens <= TS_TENS;
                        t_ones <= TS_ONES;
                    end
                    else if (st_pl) begin        // 开始 → 下一轮
                        qstate <= Q_RUN;
                        winner <= 2'd0;
                        t_tens <= TS_TENS;
                        t_ones <= TS_ONES;
                    end
                end
            endcase
        end
    end

endmodule
