//====================================================================
// tb_quiz_scene_ctrl.v —— 抢答场景「题目/队伍/结束」跳图桥接控制器 仿真
//   【2026-10-09 改版】适配新 8 张布局 + 新增 q_idx/q_end 端口。
//
// 新布局(jump_idx 0 基):
//   QUIZ1..3 = 题目 (idx 0..2)  ← jump_idx = q_idx
//   QUIZ4..7 = 队伍 (idx 3..6)  ← jump_idx = winner + 3
//   QUIZ8    = 结束页 (idx 7)   ← jump_idx = 7
//
// 验证点:
//   1. 复位后无假触发(jump_req=0, iris_trig=0, locked=0);
//   2. 进入场景(en 0→1) → 强制一次首屏对齐跳图, idx = q_idx(0) + iris 翻转;
//   3. 题号推进 q_idx=1/2 → 各产生 1 次跳图, idx 与 q_idx 一致;
//   4. 锁定 → idx = winner+3 (3..6), 四队各验一次;
//   5. Q_LOCK 持续期间**不重复**发脉冲(防重入);
//   6. 结束页 q_end=1 → idx=7,**优先于锁定/题号**;
//   7. 离开场景(en=0)不产生跳图、不翻转、locked 清零;
//   8. toggle 对称性: 12 次事件(偶数)后 iris_trig 回到初值。
//
// ★时序纪律(本 TB 的关键, 改动请勿破坏):
//   (a) 脉冲/翻转计数器必须在 **posedge + #1** 处采样 —— 直接 @(posedge) 会与
//       dut 的时序逻辑同 delta 竞争, 读到本拍**刚写入**的更新值, 同一脉冲被记两次。
//   (b) 每次"推进一拍"用 tickr (@negedge → @posedge → #1), 采样点落在 posedge
//       之后, 读到的才是真实寄存值。
//   (c) 每次改变 q_idx/qstate/winner 后, 必须先 tickr 一拍"settle", 让 dut 的
//       tgt_d 吸收新 tgt_idx(此拍不计数), 再开始对脉冲计数 —— 否则新 idx 与
//       "本已存在的状态变化"合并在同一拍, 脉冲归属会与预期错位。
//====================================================================
`timescale 1ns/1ps

module tb_quiz_scene_ctrl;

    localparam [1:0] Q_IDLE = 2'd0, Q_RUN = 2'd1, Q_LOCK = 2'd2;

    reg        clk = 0;
    reg        rst = 1;
    reg        en = 0;
    reg  [1:0] qstate = Q_IDLE;
    reg  [1:0] winner = 2'd0;
    reg  [3:0] q_idx  = 4'd0;
    reg        q_end  = 1'b0;

    wire       jump_req;
    wire [3:0] jump_idx;
    wire       iris_trig;
    wire       locked;

    integer    errors = 0;
    integer    pulses;
    integer    flips;
    reg        iris_last;

    // 100MHz
    always #5 clk = ~clk;

    quiz_scene_ctrl dut (
        .clk       (clk),
        .rst       (rst),
        .en        (en),
        .qstate    (qstate),
        .winner    (winner),
        .q_idx     (q_idx),
        .q_end     (q_end),
        .jump_req  (jump_req),
        .jump_idx  (jump_idx),
        .iris_trig (iris_trig),
        .locked    (locked)
    );

    // 【规则(a)】采样进程: posedge + #1, 与 dut 时序逻辑错开 delta
    always @(posedge clk) begin
        #1;
        if (!rst) begin
            if (jump_req)                pulses = pulses + 1;
            if (iris_trig !== iris_last) flips  = flips  + 1;
            iris_last = iris_trig;
        end
    end

    // 【规则(b)】推进一拍: negedge → posedge(+#1) 采样
    task tickr;
        begin
            @(negedge clk);
            @(posedge clk);
            #1;
        end
    endtask

    task check_true;
        input        cond;
        input [255:0] msg;
        begin
            if (!cond) begin
                $display("[FAIL] %0s", msg);
                errors = errors + 1;
            end else begin
                $display("[PASS] %0s", msg);
            end
        end
    endtask

    task check_true2;
        input        cond;
        input [255:0] msg;
        input integer v0;
        input integer v1;
        begin
            if (!cond) begin
                $display("[FAIL] %0s (v0=%0d v1=%0d)", msg, v0, v1);
                errors = errors + 1;
            end else begin
                $display("[PASS] %0s (v0=%0d v1=%0d)", msg, v0, v1);
            end
        end
    endtask

    // 模拟一次完整的"锁定"过程: IDLE → RUN → LOCK(winner 与 qstate 同拍更新)
    //   ★调用前必须保证 tgt 已收敛(先 tickr 一拍 settle), 且 winner 已清零
    task do_lock;
        input [1:0] w;
        begin
            qstate = Q_RUN; winner = 2'd0; tickr;   // tgt 不变, 无脉冲
            qstate = Q_LOCK; winner = w;   tickr;   // tgt: idx → w+3, 发脉冲
            tickr;                                  // 稳定
        end
    endtask

    integer i;
    reg [3:0] expect_idx;
    integer   pulse_snapshot;
    integer   flip_snapshot;

    initial begin
        $display("=== tb_quiz_scene_ctrl start ===");
        pulses = 0;  flips = 0;
        iris_last = 1'b0;

        // ---------- 1. 复位 ----------
        rst = 1; en = 0; qstate = Q_IDLE; winner = 2'd0; q_idx = 4'd0; q_end = 1'b0;
        repeat (5) @(negedge clk);
        rst = 0;
        repeat (3) @(negedge clk);
        check_true(jump_req  === 1'b0, "复位后无跳图请求");
        check_true(locked    === 1'b0, "复位后未锁定");
        check_true(iris_trig === 1'b0, "复位后 iris 电平为 0(无反相)");
        check_true(pulses    == 0,     "复位后脉冲计数为 0");
        check_true(flips     == 0,     "复位后翻转计数为 0");

        // ---------- 2. 进入抢答场景: 首屏对齐必须跳一次 ----------
        q_idx = 4'd0; qstate = Q_IDLE;
        pulse_snapshot = pulses;
        flip_snapshot  = flips;
        en = 1;
        tickr; tickr;                          // 等待 en_rise 生效
        check_true((pulses - pulse_snapshot) == 1,
                   "进入场景即产生 1 次首屏对齐跳图");
        check_true((flips - flip_snapshot) == 1,
                   "进入场景 iris 恰好翻转 1 次");
        check_true(jump_idx === 4'd0, "首屏对齐跳到第 1 题(idx=0)");

        // 首屏对齐后不得再重复跳(idx 未变)
        pulse_snapshot = pulses;
        repeat (10) tickr;
        check_true(pulses == pulse_snapshot,
                   "首屏对齐后持续不发脉冲(防重入)");

        // ---------- 3. 题目推进: q_idx 0→1→2 ----------
        for (i = 1; i <= 2; i = i + 1) begin
            qstate = Q_IDLE; q_idx = i[3:0];
            pulse_snapshot = pulses;
            flip_snapshot  = flips;
            tickr; tickr;
            check_true2((pulses - pulse_snapshot) == 1,
                        "题号推进恰好 1 个跳图脉冲", i, pulses - pulse_snapshot);
            check_true2(jump_idx == i[3:0],
                        "题目图索引 = q_idx", i, jump_idx);
            check_true2((flips - flip_snapshot) == 1,
                        "题号推进 iris 恰好翻转 1 次", i, flips - flip_snapshot);

            pulse_snapshot = pulses;
            repeat (10) tickr;
            check_true(pulses == pulse_snapshot,
                       "题目持续显示期间不重复发脉冲");
        end

        // ---------- 4. 四队锁定 → idx = winner + 3 ----------
        qstate = Q_IDLE; q_idx = 4'd1;
        tickr;                                  // settle: 让 q_idx=1 生效
        for (i = 0; i < 4; i = i + 1) begin
            expect_idx     = i[3:0] + 4'd3;      // 队伍图 = winner + 3
            pulse_snapshot = pulses;
            flip_snapshot  = flips;

            do_lock(i[1:0]);

            check_true2((pulses - pulse_snapshot) == 1,
                        "锁定恰好产生 1 个跳图脉冲", i, pulses - pulse_snapshot);
            check_true2(jump_idx == expect_idx,
                        "队伍图索引 = winner+3", i, jump_idx);
            check_true2((flips - flip_snapshot) == 1,
                        "锁定 iris 恰好翻转 1 次", i, flips - flip_snapshot);
            check_true(locked === 1'b1, "锁定后 locked=1");

            // ---------- 5. 锁定持续: 不重复发脉冲 ----------
            pulse_snapshot = pulses;
            repeat (10) tickr;
            check_true(pulses == pulse_snapshot,
                       "Q_LOCK 持续期间不重复发跳图脉冲(防重入)");

            // 回 IDLE 准备下一队(同题, idx 回到 q_idx)
            qstate = Q_IDLE; winner = 2'd0;
            pulse_snapshot = pulses;
            flip_snapshot  = flips;
            tickr; tickr;
            check_true2((pulses - pulse_snapshot) == 1,
                        "离开锁定回题目页恰好 1 个跳图脉冲", i,
                        pulses - pulse_snapshot);
            check_true2(jump_idx == 4'd1, "回到当前题图(idx=q_idx=1)", i, jump_idx);
            check_true(locked === 1'b0, "回题目页后 locked=0");
        end

        // ---------- 6. 结束页: q_end 优先于一切 ----------
        //   从"队伍图 winner=0(idx 3)"切到结束页 → 恰好 1 个脉冲
        qstate = Q_LOCK; winner = 2'd0; q_end = 1'b1;
        pulse_snapshot = pulses;
        flip_snapshot  = flips;
        tickr; tickr;
        check_true2((pulses - pulse_snapshot) == 1,
                    "进入结束页恰好 1 个跳图脉冲", 7, pulses - pulse_snapshot);
        check_true(jump_idx === 4'd7, "结束页索引 = 7(QUIZ8)");
        check_true2((flips - flip_snapshot) == 1,
                    "结束页 iris 恰好翻转 1 次", 7, flips - flip_snapshot);

        // 结束页持续: 不重复跳(即"再按下一张不会跳转"的底层保证)
        pulse_snapshot = pulses;
        repeat (30) tickr;
        check_true(pulses == pulse_snapshot,
                   "结束页持续期间不再跳图(终态钳位)");

        // ---------- 7. 离开抢答场景(en=0): 不产生跳图/不翻转 ----------
        en = 0;
        qstate = Q_IDLE; winner = 2'd0; q_idx = 4'd0; q_end = 1'b0;
        tickr; tickr;
        pulse_snapshot = pulses;
        flip_snapshot  = flips;
        repeat (10) tickr;
        check_true(pulses == pulse_snapshot, "离开场景时不产生跳图(无多余跳转)");
        check_true((flips - flip_snapshot) == 0, "离开场景时不翻转 iris");
        check_true(locked === 1'b0,          "离开场景时保持未锁定");

        // ---------- 8. toggle 对称性 ----------
        //   全程事件数(idx 每次变化各 1 次跳图):
        //     进场景首屏对齐   1
        //     题号推进 0→1,1→2  2
        //     四队每轮: 锁定(idx→w+3) + 回题目页(idx→1) = 2 × 4 = 8
        //     结束页(idx→7)    1
        //     小计 12; 另加"第 1 队锁定前"从 idx=2 回 idx=1 的 settle 1 次 → 13
        //   13 为奇数 → iris_trig 应为 1(与初值 0 相反)。
        $display("       (总脉冲 = %0d, 总翻转 = %0d)", pulses, flips);
        check_true(pulses == 13,       "总跳图脉冲数 = 13");
        check_true(flips  == 13,       "总翻转次数 = 13(与脉冲一一对应)");
        check_true(iris_trig === 1'b1, "奇数次事件 → iris_trig 为 1(toggle 对称)");

        // ---------- 结果 ----------
        $display("=== tb_quiz_scene_ctrl done: errors=%0d ===", errors);
        if (errors == 0) $display("*** ALL PASS ***");
        else             $display("*** %0d FAIL ***", errors);
        $finish;
    end

    // 超时保护
    initial begin
        #200000;
        $display("[FAIL] TIMEOUT");
        $finish;
    end

endmodule
