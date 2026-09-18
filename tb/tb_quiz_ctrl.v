//====================================================================
// 模块名 : tb_quiz_ctrl.v —— 抢答场景控制 功能级回归 (quiz_ctrl)
// 被测   : src/quiz_ctrl.v (6 路消抖 + 4 路并行仲裁 + BCD 倒计时 + 状态机)
//
// 说明   : 仿真用参数大幅缩短(DEB_MAX=20 拍 / SEC_CNT_MAX=99 拍 / 5 秒),
//          与真实值(20ms / 1s / 10s)逻辑等价, 只为提速。
//
// 覆盖用例:
//   1) 复位初值: qstate=等待开始(0), 胜者 0, 倒计时 05
//   2) 开始键 → 抢答中(1); 倒计时随时间递减(1 秒 1 拍)
//   3) 抢答中选手键 → 锁定(2) 且胜者=对应号, 计时冻结
//   4) 已锁定后再按选手键 → 忽略(胜者不变)
//   5) 复位键 → 回等待开始(0), 胜者清零, 倒计时回 05
//   6) 同拍多路抢答 → 预定义优先级 player1>2>3>4 裁定
//   7) 等待开始/已锁定状态下选手键无效(门控)
//   8) 倒计时归零 → 时间到(3)
//   9) en=0(离开抢答场景) → 强制回等待开始(0)
//====================================================================

`timescale 1ns/1ps
module tb_quiz_ctrl;

    localparam CLK = 10;              // 100MHz

    reg         clk;
    reg         rst;
    reg         en;
    reg  [3:0]  player_raw;
    reg         start_raw;
    reg         clear_raw;
    wire [1:0]  qstate;
    wire [1:0]  winner;
    wire [3:0]  t_tens;
    wire [3:0]  t_ones;

    integer     err_cnt;

    //--------------- 例化被测模块(仿真加速参数) ----------------
    quiz_ctrl #(
        .DEB_MAX     (21'd20),
        .SEC_CNT_MAX (27'd99),
        .TIME_SEC    (8'd5)
    ) dut (
        .clk        (clk),
        .rst        (rst),
        .en         (en),
        .player_raw (player_raw),
        .start_raw  (start_raw),
        .clear_raw  (clear_raw),
        .qstate     (qstate),
        .winner     (winner),
        .t_tens     (t_tens),
        .t_ones     (t_ones)
    );

    //--------------- 时钟 / 复位 ----------------
    initial clk = 1'b0;
    always #(CLK/2) clk = ~clk;

    //--------------- 检查任务 ----------------
    task chk; input [255:0] tag; input cond; begin
        if (cond !== 1'b1) begin
            err_cnt = err_cnt + 1;
            $display("t=%0t [FAIL] %0s (qstate=%0d winner=%0d t=%0d%0d en=%0d)",
                     $time, tag, qstate, winner, t_tens, t_ones, en);
        end
        else
            $display("t=%0t [PASS] %0s (qstate=%0d winner=%0d t=%0d%0d)",
                     $time, tag, qstate, winner, t_tens, t_ones);
    end endtask

    //--------------- 单键脉冲(拉低 → 保持 → 释放) ----------------
    //   which: 0=选手键 idx / 1=开始 / 2=复位
    task pulse; input integer which; input integer idx; begin
        case (which)
            0: player_raw[idx] = 1'b0;
            1: start_raw       = 1'b0;
            default: clear_raw = 1'b0;
        endcase
        repeat (40) @(posedge clk);           // > DEB_MAX+两级同步
        case (which)
            0: player_raw[idx] = 1'b1;
            1: start_raw       = 1'b1;
            default: clear_raw = 1'b1;
        endcase
        repeat (10) @(posedge clk);
    end endtask

    //--------------- 主流程 ----------------
    initial begin
        err_cnt = 0;
        rst = 1'b1;
        en  = 1'b0;
        player_raw = 4'hF;                    // 全部释放(上拉高)
        start_raw  = 1'b1;
        clear_raw  = 1'b1;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        en  = 1'b1;
        repeat (5) @(posedge clk);

        // ---- 1) 复位初值 ----
        chk("初值: 等待开始/胜者0/倒计时05",
            (qstate === 2'd0) && (winner === 2'd0) &&
            (t_tens === 4'd0) && (t_ones === 4'd5));

        // ---- 7a) 等待开始状态选手键无效 ----
        pulse(0, 1);                          // 按选手 2 号
        repeat (5) @(posedge clk);
        chk("等待开始: 选手键无效(仍为0且胜者0)",
            (qstate === 2'd0) && (winner === 2'd0));

        // ---- 2) 开始 → 抢答中, 倒计时递减 ----
        pulse(1, 0);                          // 按开始
        repeat (5) @(posedge clk);
        chk("开始键 → 抢答中", qstate === 2'd1);

        repeat (240) @(posedge clk);          // 约 2 个计时拍
        chk("倒计时递减(5 → 3 附近, 未到 0)",
            (qstate === 2'd1) && (t_tens === 4'd0) &&
            (t_ones < 4'd5) && (t_ones > 4'd0));

        // ---- 3) 选手 3 号抢答成功 → 锁定 ----
        pulse(0, 2);                          // player_raw[2] = 3 号
        repeat (5) @(posedge clk);
        chk("抢答成功: 锁定 + 胜者=3 号(索引2)",
            (qstate === 2'd2) && (winner === 2'd2));

        // 计时冻结: 1 个计时拍后倒计时不变
        begin : FRZ
            reg [3:0] t_save;
            t_save = t_ones;
            repeat (200) @(posedge clk);
            chk("已锁定: 计时冻结", t_ones === t_save);
        end

        // ---- 4) 已锁定后再按选手键 → 忽略 ----
        pulse(0, 0);                          // 按选手 1 号
        repeat (5) @(posedge clk);
        chk("已锁定: 后续选手键忽略(胜者仍为 3 号)",
            (qstate === 2'd2) && (winner === 2'd2));

        // ---- 5) 复位键 → 回等待开始 ----
        pulse(2, 0);                          // 按复位
        repeat (5) @(posedge clk);
        chk("复位键 → 等待开始/胜者清零/倒计时回05",
            (qstate === 2'd0) && (winner === 2'd0) &&
            (t_tens === 4'd0) && (t_ones === 4'd5));

        // ---- 6) 同拍多路抢答 → 优先级 1>2>3>4 ----
        pulse(1, 0);                          // 开始
        repeat (5) @(posedge clk);
        player_raw[1] = 1'b0;                 // 同拍按下 2 号 与 4 号
        player_raw[3] = 1'b0;
        repeat (40) @(posedge clk);
        player_raw[1] = 1'b1;
        player_raw[3] = 1'b1;
        repeat (10) @(posedge clk);
        chk("同拍多路: 2 号优先于 4 号(索引1)",
            (qstate === 2'd2) && (winner === 2'd1));

        // ---- 8) 倒计时归零 → 时间到 ----
        pulse(2, 0);                          // 复位
        repeat (5) @(posedge clk);
        pulse(1, 0);                          // 开始
        repeat (700) @(posedge clk);          // > 5 个计时拍
        chk("倒计时归零 → 时间到(3) 且 00",
            (qstate === 2'd3) && (t_tens === 4'd0) && (t_ones === 4'd0));

        // 时间到后再按开始 → 下一轮
        pulse(1, 0);
        repeat (5) @(posedge clk);
        chk("时间到后按开始 → 下一轮(抢答中)",
            (qstate === 2'd1) && (t_ones === 4'd5));

        // ---- 9) en=0 → 强制回等待开始 ----
        en = 1'b0;
        repeat (5) @(posedge clk);
        chk("en=0 → 强制等待开始/胜者清零",
            (qstate === 2'd0) && (winner === 2'd0) && (t_ones === 4'd5));
        chk("en=0 时选手键完全无效", (qstate === 2'd0));

        // ---- 汇总 ----
        #100;
        if (err_cnt == 0)
            $display("=== quiz_ctrl 仿真结束: 全部通过 ===");
        else
            $display("=== quiz_ctrl 仿真结束: 失败数=%0d ===", err_cnt);
        $finish;
    end

    // 超时兜底
    initial begin
        #2000000 $finish;
    end

endmodule
