//====================================================================
// tb_quiz_ctrl.v —— 抢答流程状态机(新流程) 仿真
//   【2026-10-09 改版】适配新端口: next_raw / judge_up_pl / judge_dn_pl /
//   q_idx / q_end / sc0..3 / score_tog / score_team。
//
// 新流程验证点:
//   1. 复位 / en=0 → 空闲, 题号 0, 分数全 0, 倒计时 = TIME_SEC;
//   2. 白色按钮(start_raw) 仅在 F_IDLE 有效 → 进入倒计时;
//   3. 倒计时中选手抢答 → 锁定 winner, 跳队伍图;
//   4. 锁定态 KEY3(judge_up_pl) → 该队 +2, score_tog 翻转, score_team=winner;
//   5. 锁定态 KEY2(judge_dn_pl) → 该队 -1, score_tog 翻转;
//   6. 分数**累计**(多次判定叠加);
//   7. 锁定态白色按钮无效(不重新开始);
//   8. 黑色按钮(next_raw) → 题号 +1, 回 F_IDLE;
//   9. 无人抢答: 倒计时归零 → 超时, 黑色按钮 → 题号 +1;
//  10. 最后一题后黑色按钮 → 结束页(q_end=1), 之后任何键都不再动作。
//
// 注: TIME_SEC=3 缩短仿真; DEB_MAX 缩小以加速外扩口消抖。
//====================================================================
`timescale 1ns/1ps

module tb_quiz_ctrl;

    localparam [1:0] Q_IDLE = 2'd0, Q_RUN = 2'd1, Q_LOCK = 2'd2, Q_TIMEUP = 2'd3;

    reg               clk;
    reg               rst;
    reg               en;
    reg  [3:0]        player_raw;
    reg               start_raw;
    reg               next_raw;
    reg               judge_up_pl;    // ★2026-10-09c: 语义由"单拍脉冲"改为"按住电平"
    reg               judge_dn_pl;

    wire [1:0]        qstate;
    wire [1:0]        winner;
    wire [3:0]        t_tens, t_ones;
    wire [3:0]        q_idx;
    wire              q_end;
    wire signed [7:0] sc0, sc1, sc2, sc3;
    wire              score_tog;
    wire [1:0]        score_team;

    integer           errors = 0;

    quiz_ctrl #(
        .DEB_MAX     (21'd20),        // 消抖缩到 20 拍(方便仿真)
        .SEC_CNT_MAX (27'd100),       // 1 "秒" = 100 拍
        .TIME_SEC    (8'd3),          // 倒计时 3 秒
        .Q_TOTAL     (4'd3),          // 3 道题
        .RPT_MAX     (24'd5)          // ★判分节拍缩到 5 拍(仿真加速)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .en           (en),
        .player_raw   (player_raw),
        .start_raw    (start_raw),
        .next_raw     (next_raw),
        .judge_up_lv  (judge_up_pl),
        .judge_dn_lv  (judge_dn_pl),
        .qstate       (qstate),
        .winner       (winner),
        .t_tens       (t_tens),
        .t_ones       (t_ones),
        .q_idx        (q_idx),
        .q_end        (q_end),
        .sc0          (sc0),
        .sc1          (sc1),
        .sc2          (sc2),
        .sc3          (sc3),
        .score_tog    (score_tog),
        .score_team   (score_team)
    );

    // 100MHz
    initial clk = 1'b0;
    always #5 clk = ~clk;

    task check_true;
        input        cond;
        input [255:0] msg;
        begin
            if (!cond) begin
                $display("[FAIL] %0s  (t=%0t)", msg, $time);
                errors = errors + 1;
            end else begin
                $display("[PASS] %0s", msg);
            end
        end
    endtask

    task check_int;
        input        cond;
        input [255:0] msg;
        input integer got;
        input integer exp;
        begin
            if (!cond) begin
                $display("[FAIL] %0s got=%0d exp=%0d (t=%0t)", msg, got, exp, $time);
                errors = errors + 1;
            end else begin
                $display("[PASS] %0s (=%0d)", msg, got);
            end
        end
    endtask

    // 外扩口按键(上拉高 / 按下低): 拉低 >20 拍以越过消抖
    // ★时序纪律: 所有 stimulus 一律在 **negedge** 驱动 —— DUT 在 posedge 采样,
    //   同沿驱动会与 DUT 的时序逻辑竞争(读到旧值/新值不确定), 是本次 24 个
    //   FAIL 的根因。negedge 驱动 = 半个周期建立时间, 与 DUT 采样沿彻底错开。
    // ★消抖器需要"连续 DEB_MAX+2 拍偏离"才采纳新电平(见 scene_control.v 的
    //   term_q 打拍设计), 故按下必须保持足够久; 这里用 60 拍(DEB_MAX=20)。
    localparam integer PRESS_CYCLES = 60;

    task press_start;
        begin
            @(negedge clk); start_raw = 1'b0;
            repeat (PRESS_CYCLES) @(negedge clk);
            start_raw = 1'b1;
            repeat (10) @(negedge clk);
        end
    endtask

    task press_next;
        begin
            @(negedge clk); next_raw = 1'b0;
            repeat (PRESS_CYCLES) @(negedge clk);
            next_raw = 1'b1;
            repeat (10) @(negedge clk);
        end
    endtask

    task press_player;
        input integer n;               // 0..3
        begin
            @(negedge clk); player_raw = ~(4'b0001 << n);
            repeat (PRESS_CYCLES) @(negedge clk);
            player_raw = 4'b1111;
            repeat (10) @(negedge clk);
        end
    endtask

    // ★2026-10-09c: quiz_ctrl 改为"按住电平 + 100ms 节拍"判定。
    //   本 TB 把 RPT_MAX 缩到 5 拍(见上方参数), 故"按下→等一个节拍→松开"
    //   恰好产生 1 次判定; 等价于原来的"单次脉冲", 用例期望值不变。
    task pulse_judge_up;               // 一次"点按"(按住 1 个节拍后松开)
        begin
            @(negedge clk); judge_up_pl = 1'b1;
            repeat (8) @(negedge clk);  // > RPT_MAX(5) → 保证产生 1 次判定
            judge_up_pl = 1'b0;
            repeat (3) @(negedge clk);
        end
    endtask

    task pulse_judge_dn;
        begin
            @(negedge clk); judge_dn_pl = 1'b1;
            repeat (8) @(negedge clk);
            judge_dn_pl = 1'b0;
            repeat (3) @(negedge clk);
        end
    endtask

    // 以负沿为基准推进一拍(保持所有等待都在 negedge)
    task tickn;
        begin
            @(negedge clk);
            #1;
        end
    endtask

    integer i;
    reg     tog_prev;

    initial begin
        $display("=== tb_quiz_ctrl start ===");
        rst = 1'b1;
        en = 1'b0;
        player_raw = 4'b1111;          // 上拉, 未按下
        start_raw  = 1'b1;
        next_raw   = 1'b1;
        judge_up_pl = 1'b0;
        judge_dn_pl = 1'b0;

        repeat (10) @(negedge clk);
        rst = 1'b0;
        repeat (5) @(negedge clk);

        // ---------- 1. 复位后空闲 ----------
        check_int(qstate === Q_IDLE, "复位后 qstate=IDLE", qstate, Q_IDLE);
        check_int(q_idx  === 4'd0,   "复位后题号 0",     q_idx, 0);
        check_true(q_end === 1'b0,   "复位后非结束页");
        check_true(sc0 === 8'sd0 && sc1 === 8'sd0 &&
                   sc2 === 8'sd0 && sc3 === 8'sd0, "复位后四队分数全 0");
        check_int(t_tens * 10 + t_ones, "复位后倒计时 = TIME_SEC(3)",
                  t_tens * 10 + t_ones, 3);

        // ---------- 2. en=0 时按键无效 ----------
        press_start();
        check_int(qstate === Q_IDLE, "en=0 时白色按钮无效", qstate, Q_IDLE);

        // 打开场景
        en = 1; repeat (3) @(negedge clk);

        // ---------- 3. 选手抢答在 IDLE 无效 ----------
        press_player(0);
        check_int(qstate === Q_IDLE, "IDLE 时选手抢答无效", qstate, Q_IDLE);

        // ---------- 4. 白色按钮 → 倒计时 ----------
        press_start();
        check_int(qstate === Q_RUN, "白色按钮 → 抢答中", qstate, Q_RUN);

        // ---------- 5. 倒计时递减 ----------
        repeat (150) @(negedge clk);       // 约 1.5 "秒"
        check_true((t_tens * 10 + t_ones) < 3, "倒计时在递减");

        // ---------- 6. 选手 3 号抢答 → 锁定 ----------
        press_player(2);                   // n=2 → 3 号(wire[2])
        check_int(qstate === Q_LOCK, "选手抢答 → 已锁定", qstate, Q_LOCK);
        check_int(winner === 2'd2,   "胜者 = 3 号(winner=2)", winner, 2);

        // ---------- 7. 锁定态白色按钮无效 ----------
        press_start();
        check_int(qstate === Q_LOCK, "锁定态白色按钮无效(仍锁定)", qstate, Q_LOCK);

        // ---------- 8. 判对 +2 ----------
        tog_prev = score_tog;
        pulse_judge_up();
        check_int(sc2 === 8'sd2,       "3 号判对 → +2", sc2, 2);
        check_true(score_tog !== tog_prev, "判分翻转 score_tog");
        check_int(score_team === 2'd2, "score_team = 胜者(2)", score_team, 2);

        // ---------- 9. 再判错 -1 → 累计 1 ----------
        pulse_judge_dn();
        check_int(sc2 === 8'sd1,       "3 号再判错 → 累计 1", sc2, 1);

        // ---------- 10. 锁定态外扩口选手键无效(不换 winner) ----------
        press_player(0);
        check_int(winner === 2'd2, "锁定态选手键无效(winner 不变)", winner, 2);
        check_int(qstate === Q_LOCK, "锁定态仍保持锁定", qstate, Q_LOCK);

        // ---------- 11. 黑色按钮 → 下一题 ----------
        press_next();
        check_int(q_idx === 4'd1,   "黑色按钮 → 题号 +1", q_idx, 1);
        check_int(qstate === Q_IDLE, "下一题回到待开始", qstate, Q_IDLE);
        check_int(winner === 2'd0,  "下一题 winner 清零", winner, 0);

        // ---------- 12. 无人抢答路径: 倒计时耗尽 ----------
        press_start();
        check_int(qstate === Q_RUN, "第 2 题开始倒计时", qstate, Q_RUN);
        repeat (400) @(negedge clk);       // 4 "秒" > TIME_SEC=3
        check_int(qstate === Q_TIMEUP, "无人抢答 → 超时", qstate, Q_TIMEUP);
        check_true((t_tens * 10 + t_ones) == 0, "超时后倒计时归零");

        // 超时态判分无效(仅锁定态可判)
        pulse_judge_up();
        check_true(sc0 === 8'sd0 && sc1 === 8'sd0 &&
                   sc2 === 8'sd1 && sc3 === 8'sd0, "超时态判分无效(分数不变)");

        // 超时态白色按钮无效
        press_start();
        check_int(qstate === Q_TIMEUP, "超时态白色按钮无效", qstate, Q_TIMEUP);

        // ---------- 13. 黑色按钮 → 第 3 题 ----------
        press_next();
        check_int(q_idx === 4'd2,   "超时后黑色按钮 → 题号 2", q_idx, 2);
        check_int(qstate === Q_IDLE, "第 3 题待开始", qstate, Q_IDLE);

        // ---------- 14. 最后一题: 锁定后下一题 → 结束页 ----------
        press_start();
        press_player(0);                   // 1 号抢答
        check_int(qstate === Q_LOCK, "第 3 题 1 号抢答锁定", qstate, Q_LOCK);
        check_int(winner === 2'd0,   "winner = 1 号", winner, 0);
        pulse_judge_up();                  // 1 号 +2
        check_int(sc0 === 8'sd2,     "1 号判对 → +2", sc0, 2);

        press_next();                      // 最后一题之后
        check_true(q_end === 1'b1,   "最后一题后 → 进入结束页(q_end=1)");
        check_true(qstate === Q_IDLE, "结束页对外呈现 qstate=IDLE");

        // ---------- 15. 结束页钳位: 任何键都不再动作 ----------
        press_start();
        press_next();
        press_player(1);
        pulse_judge_up();
        pulse_judge_dn();
        check_true(q_end === 1'b1,  "结束页保持 q_end=1(不再跳转)");
        check_int(q_idx === 4'd2,   "结束页题号不变", q_idx, 2);
        check_int(sc0 === 8'sd2,    "结束页分数不变(1 号 = 2)", sc0, 2);

        // ---------- 16. en=0 强制复位(离开场景) ----------
        en = 0; repeat (5) @(negedge clk);
        check_int(q_idx === 4'd0,   "离开场景题号清 0", q_idx, 0);
        check_true(q_end === 1'b0,  "离开场景清 q_end");
        check_true(sc0 === 8'sd0 && sc1 === 8'sd0 &&
                   sc2 === 8'sd0 && sc3 === 8'sd0, "离开场景四队分数清零");
        check_int(qstate === Q_IDLE, "离开场景回空闲", qstate, Q_IDLE);

        // ---------- 结果 ----------
        $display("=== tb_quiz_ctrl done: errors=%0d ===", errors);
        if (errors == 0) $display("*** ALL PASS ***");
        else             $display("*** %0d FAIL ***", errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("[FAIL] TIMEOUT");
        $finish;
    end

endmodule
