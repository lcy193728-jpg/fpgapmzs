//====================================================================
// 测试平台 : tb_ui_key_ctrl_meeting.v —— 会议场景 KEY 功能模式(2026-10-09j)
// 覆盖点:
//   [C1] 会议场景(scene_id=1) KEY1 循环 0→1→2→3→4→0(无周期档、无计分档)
//   [C2] 模式 3 = 对比度(KEY3 调 con_level, 不调周期)
//   [C3] 模式 4 = 音量(KEY3 调 vol_level)
//   [C4] 模式 0 = 议程切换(KEY3 下一场 key_next_pl)
//====================================================================
`timescale 1ns/1ps
module tb_ui_key_ctrl_meeting;

    localparam CLK_PERIOD = 10;

    reg clk, rst, key1, key2, key3, key4;
    reg [7:0] img_no;
    reg scene_chg, alarm_scene;
    reg [1:0] scene_id;

    wire [2:0] mode;
    wire [3:0] bri_level, vol_level, res_level, con_level;
    wire [7:0] period_sec;
    wire key_next_pl, key_prev_pl;

    ui_key_ctrl dut (
        .clk(clk), .rst(rst), .key1(key1), .key2(key2), .key3(key3), .key4(key4),
        .control_lock(1'b0), .alarm_scene(alarm_scene), .alarm_type(),
        .img_no(img_no), .scene_chg(scene_chg), .scene_id(scene_id),
        .mode(mode), .bri_level(bri_level), .vol_level(vol_level),
        .res_level(res_level), .con_level(con_level),
        .period_sec(period_sec), .period_cycles(),
        .disp_hold(), .disp_sel(), .pic_manual(), .pic_param(),
        .key_next_pl(key_next_pl), .key_prev_pl(key_prev_pl), .res_chg_pl()
    );

    defparam dut.u_k1.DEB_MAX = 20'd100;
    defparam dut.u_k2.DEB_MAX = 20'd100;
    defparam dut.u_k3.DEB_MAX = 20'd100;
    defparam dut.u_k4.DEB_MAX = 20'd100;

    integer npass, nfail;
    initial begin npass = 0; nfail = 0; end

    // 单周期脉冲粘滞捕获(key_next_pl 是组合脉冲, 按下瞬间有效)
    reg next_seen;
    always @(posedge clk) if (key_next_pl) next_seen <= 1'b1;

    task chk;
        input ok;
        input [255:0] msg;
        begin
            if (ok) begin npass = npass + 1; $display("[PASS] %0s", msg); end
            else   begin nfail = nfail + 1; $display("[FAIL] %0s (mode=%0d con=%0d vol=%0d)", msg, mode, con_level, vol_level); end
        end
    endtask

    task settle;
        input integer n;
        integer i;
        begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
    endtask

    task press1; begin key1 = 0; settle(150); key1 = 1; settle(150); end endtask
    task press2; begin key2 = 0; settle(150); key2 = 1; settle(150); end endtask
    task press3; begin key3 = 0; settle(150); key3 = 1; settle(150); end endtask

    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        clk = 0; rst = 1; key1 = 1; key2 = 1; key3 = 1; key4 = 1;
        img_no = 8'd1; scene_chg = 0; alarm_scene = 0; scene_id = 2'd1;  // 会议场景
        next_seen = 1'b0;
        repeat (4) @(posedge clk);
        rst = 0;
        settle(5);

        // [C1] 会议 KEY1 循环 0→1→2→3→4→0
        chk(mode == 3'd0, "会议初始模式 = 0(议程)");
        press1; chk(mode == 3'd1, "会议 KEY1 → 模式1(亮度)");
        press1; chk(mode == 3'd2, "会议 KEY1 → 模式2(缩放)");
        press1; chk(mode == 3'd3, "会议 KEY1 → 模式3(对比度)");
        press1; chk(mode == 3'd4, "会议 KEY1 → 模式4(音量)");
        press1; chk(mode == 3'd0, "会议 KEY1 → 回模式0(无5档)");

        // [C2] 模式 3 = 对比度
        press1; press1; press1;   // → 模式3
        chk(mode == 3'd3, "会议 → 模式3");
        press3;
        chk(con_level == 4'd9, "模式3 KEY3 → 对比度 8→9");
        chk(period_sec == 8'd3, "模式3 → 周期秒数不变(该档是对比度,非周期)");
        press2; chk(con_level == 4'd8, "模式3 KEY2 → 对比度 9→8");

        // [C3] 模式 4 = 音量
        press1;
        chk(mode == 3'd4, "会议 KEY1 → 模式4");
        press3;
        chk(vol_level == 4'd9, "模式4 KEY3 → 音量 8→9");
        chk(con_level == 4'd8, "模式4 → 对比度不变(该档是音量)");
        press2; chk(vol_level == 4'd8, "模式4 KEY2 → 音量 9→8");

        // [C4] 模式 0 = 议程切换(KEY3 下一场)
        press1;   // 4→0
        chk(mode == 3'd0, "会议 KEY1 → 回模式0");
        next_seen = 1'b0;
        press3;
        chk(next_seen == 1'b1, "模式0 KEY3 → 下一场脉冲(key_next_pl)");

        $display("========================================");
        $display("tb_ui_key_ctrl_meeting: %0d PASS / %0d FAIL", npass, nfail);
        if (nfail == 0) $display("ALL PASS");
        else            $display("FAILED");
        $finish;
    end

endmodule
