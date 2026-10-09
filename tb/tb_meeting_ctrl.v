//====================================================================
// 测试平台 : tb_meeting_ctrl.v —— 会议场景议程状态机 + 倒计时 + Wipe 触发
//   (2026-10-09j; 2026-10-09o 增加"全部会议结束→空闲"用例)
// 覆盖点:
//   [C1] 复位 → IDLE(空闲), 倒计时 0
//   [C2] scene_en=1 → 自动进 RUN, sec_left=MEET_SEC(20)
//   [C3] 倒计时逐秒递减(每 CLK_FREQ 拍减 1)
//   [C4] sec_left ≤ WARN_SEC(3) → 进 WARN(即将结束)
//   [C5] 归零 → NEXT(1 拍) → next_pl 脉冲 + wipe_trig 翻转 → 回 RUN 重置 20
//   [C6] 手动 key_next/key_prev → 重置倒计时 + wipe_trig 翻转
//   [C7] scene_en=0 → 回 IDLE, 倒计时归零
//   ★[C8] 走完 MEET_NUM(3) 场 → 进 IDLE(空闲/无会议), 停在末图, sec=0(00:00)
//   ★[C9] 空闲态: 按键不再重启(只有 scene_en 0→1 才重开)
//   ★[C10] 拨码离开再回来(scene_en 0→1) → 重新开跑第 1 场
//   (仿真用 defparam 缩短 MEET_SEC=5 / CLK_FREQ=100 加速)
//====================================================================
`timescale 1ns/1ps

module tb_meeting_ctrl;

    reg clk, rst, scene_en, key_next, key_prev;
    wire [1:0] state;
    wire [5:0] sec_left;
    wire next_pl, meet_active, warn_active, wipe_trig;

    meeting_ctrl #(
        .MEET_SEC (6'd20),
        .WARN_SEC (6'd3),
        .MEET_NUM (4'd3),
        .CLK_FREQ (32'd100_000_000)
    ) dut (
        .clk(clk), .rst(rst), .scene_en(scene_en),
        .key_next(key_next), .key_prev(key_prev),
        .state(state), .sec_left(sec_left), .next_pl(next_pl),
        .meet_active(meet_active), .warn_active(warn_active),
        .wipe_trig(wipe_trig)
    );

    // 仿真缩短参数(不影响逻辑, 只加速)
    defparam dut.MEET_SEC = 6'd5;
    defparam dut.MEET_NUM = 4'd3;      // 3 场(与卡上 MEET1..3 一致)
    defparam dut.CLK_FREQ = 32'd100;   // 1s = 100 拍

    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_WARN = 2'd2, S_NEXT = 2'd3;

    reg w0, w1;   // wipe_trig 快照(切场前后对比)

    integer npass, nfail;
    initial begin npass = 0; nfail = 0; end

    task chk;
        input ok;
        input [255:0] msg;
        begin
            if (ok) begin npass = npass + 1; $display("[PASS] %0s", msg); end
            else   begin nfail = nfail + 1; $display("[FAIL] %0s", msg); end
        end
    endtask

    task settle;
        input integer n;
        integer i;
        begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
    endtask

    initial clk = 0;
    always #5 clk = ~clk;   // 100MHz(周期 10ns)

    integer t0, t1, k;
    initial begin
        clk = 0; rst = 1; scene_en = 0; key_next = 0; key_prev = 0;
        repeat (4) @(posedge clk);
        rst = 0;
        settle(3);

        // [C1] 复位 → IDLE
        chk(state == S_IDLE, "复位后 = IDLE 空闲");
        chk(sec_left == 6'd0, "IDLE 倒计时 = 0");
        chk(meet_active == 1'b0, "IDLE meet_active = 0");

        // [C2] scene_en=1 → 自动进 RUN
        scene_en = 1;
        settle(2);
        chk(state == S_RUN, "scene_en=1 → 自动进 RUN");
        chk(sec_left == 6'd5, "RUN 初始倒计时 = MEET_SEC(5)");
        chk(meet_active == 1'b1, "RUN meet_active = 1");

        // [C3] 倒计时逐秒递减(1s = 100 拍)
        t0 = sec_left;
        settle(100);   // 1 秒
        t1 = sec_left;
        chk(t1 == t0 - 1, "1 秒后倒计时 -1");
        settle(100);   // 再 1 秒 → 4→3 → 进入 WARN(≤3)
        chk(state == S_WARN, "sec_left=3 → 进 WARN");
        chk(warn_active == 1'b1, "WARN 期间 warn_active = 1");

        // [C4][C5] WARN 归零 → NEXT → next_pl + wipe_trig 翻转 (第1场→第2场)
        w0 = wipe_trig;
        settle(100);   // 3→2
        settle(100);   // 2→1
        settle(100);   // 1→0 → NEXT(1拍) → next_pl → 回 RUN(第2场)
        settle(1);
        chk(state == S_RUN, "第1场归零后回到 RUN(第2场)");
        chk(sec_left == 6'd5, "切场后倒计时重置 = 5");
        chk(wipe_trig != w0, "切场 wipe_trig 翻转");

        // [C6] 手动 key_next → 重置 + wipe_trig 翻转 (第2场→第3场)
        w1 = wipe_trig;
        key_next = 1;
        settle(1);
        key_next = 0;
        settle(1);
        chk(state == S_RUN, "手动 key_next 后仍在 RUN");
        chk(sec_left == 6'd5, "手动切场倒计时重置 = 5");
        chk(wipe_trig != w1, "手动切场 wipe_trig 翻转");

        //-------------------------------------------------------------
        // ★[C8] 走完第 3 场(最后一场) 归零 → 应进 IDLE(空闲)
        //   当前已是第 3 场(dut.meet_idx==3), 跑完它 → S_NEXT 判 >= MEET_NUM
        //   → S_IDLE, 且**不发 next_pl**(停在末图)。
        //-------------------------------------------------------------
        // 跑完第 3 场(5s: 5→...→1→0 → NEXT → IDLE)
        for (k = 0; k < 8; k = k + 1) begin
            if (state == S_IDLE) k = 100;      // 已到 IDLE, 提前跳出
            else settle(100);
        end
        settle(2);
        chk(state == S_IDLE, "[C8] 走完第3场 → 进 IDLE 空闲");
        chk(sec_left == 6'd0, "[C8] 空闲态倒计时 = 0 → 显示 00:00");
        chk(meet_active == 1'b0, "[C8] 空闲态 meet_active = 0(非会议中)");

        // [C8b] 空闲停留: 多等 3 秒仍应停在 IDLE(不自动重开)
        settle(300);
        chk(state == S_IDLE, "[C8] 空闲态保持(等 3s 仍 IDLE, 不自动重开)");
        chk(sec_left == 6'd0, "[C8] 空闲态秒数仍 0");

        // [C9] 空闲态按键无效(只有 scene_en 0→1 才重开)
        key_next = 1; settle(2); key_next = 0; settle(2);
        chk(state == S_IDLE, "[C9] 空闲态按 key_next 不重启(仍 IDLE)");
        key_prev = 1; settle(2); key_prev = 0; settle(2);
        chk(state == S_IDLE, "[C9] 空闲态按 key_prev 不重启(仍 IDLE)");

        // [C10] 拨码离开再回来 → 重新开跑第 1 场
        scene_en = 0;
        settle(3);
        chk(state == S_IDLE, "[C10] 离开场景 → IDLE");
        scene_en = 1;
        settle(2);
        chk(state == S_RUN, "[C10] 拨码再回来 → 重新进 RUN(第1场)");
        chk(sec_left == 6'd5, "[C10] 重开后倒计时 = 5(第1场)");

        // [C7] scene_en=0 → 回 IDLE
        scene_en = 0;
        settle(2);
        chk(state == S_IDLE, "scene_en=0 → 回 IDLE");
        chk(sec_left == 6'd0, "离开场景倒计时归零");

        $display("========================================");
        $display("tb_meeting_ctrl: %0d PASS / %0d FAIL", npass, nfail);
        if (nfail == 0) $display("ALL PASS");
        else            $display("FAILED");
        $finish;
    end

endmodule
