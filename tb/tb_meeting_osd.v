//====================================================================
// 测试平台 : tb_meeting_osd.v —— 会议 OSD(状态条 + MM:SS 倒计时 + 进度条) 像素验证
//   (2026-10-09j 新增; 2026-10-09n 补倒计时 MM:SS 数字/面板断言)
// 覆盖点:
//   [C1] meet_en=0 → 纯透传(data_o == data_i)
//   [C2] meet_en=1, state=RUN   → 状态条(y<52) = 红 0xE24B4A
//   [C3] meet_en=1, state=WARN  → 状态条 = 黄 0xF0A020
//   [C4] meet_en=1, state=IDLE  → 状态条 = 绿 0x2FA84F
//   ★[C10] 空闲态(IDLE + sec=0) → 绿条 + "00:00" + 进度条全空(2026-10-09o)
//   [C5] 非 OSD 区(y=300) → 透传(不影响议程图)
//   [C6] 进度条区(y=186, 已过区) → 状态色; 未过区 → 深灰 0x384048
//   [C7] 倒计时面板底(近黑 0x0A1018) / 面板描边(状态色)
//   [C8] MM:SS 数字点亮像素 = 白 0xFFFFFF(4 位 + 冒号)
//   [C9] MM:SS 数字熄灭像素 = 面板底(不该整块白)
//====================================================================
`timescale 1ns/1ps

module tb_meeting_osd;

    reg clk, rst, hs_i, vs_i, de_i;
    reg [23:0] data_i;
    reg [11:0] px_x, px_y;
    reg meet_en;
    reg [1:0] m_state;
    reg [5:0] m_sec;
    wire hs_o, vs_o, de_o;
    wire [23:0] data_o;
    wire [11:0] px_x_o, px_y_o;

    meeting_osd dut (
        .video_clk(clk), .rst(rst),
        .hs_i(hs_i), .vs_i(vs_i), .de_i(de_i), .data_i(data_i),
        .px_x(px_x), .px_y(px_y),
        .meet_en(meet_en), .m_state(m_state), .m_sec(m_sec),
        .hs_o(hs_o), .vs_o(vs_o), .de_o(de_o), .data_o(data_o),
        .px_x_o(px_x_o), .px_y_o(px_y_o)
    );

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

    // 采样一个像素: 设坐标, 等 3 拍(同步余量 + 组合 + 输出寄存器), 读 data_o
    task sample;
        input [11:0] x, y;
        input [23:0] expect;
        input [255:0] msg;
        begin
            @(posedge clk); px_x <= x; px_y <= y; data_i <= 24'h123456;
            repeat (3) @(posedge clk);
            chk(data_o == expect, msg);
        end
    endtask

    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        clk = 0; rst = 1; hs_i = 0; vs_i = 0; de_i = 1;
        px_x = 0; px_y = 0; data_i = 24'h123456;
        meet_en = 0; m_state = 2'd0; m_sec = 6'd20;
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);   // 等两级同步稳定

        // [C1] meet_en=0 → 透传
        @(posedge clk); px_x = 320; px_y = 10; data_i = 24'h123456;
        repeat (3) @(posedge clk);
        chk(data_o == 24'h123456, "meet_en=0 → 纯透传");

        // [C2] RUN → 状态条红
        meet_en = 1; m_state = 2'd1; m_sec = 6'd20;
        repeat (3) @(posedge clk);   // 等同步
        @(posedge clk); px_x = 320; px_y = 10;
        repeat (3) @(posedge clk);
        chk(data_o == 24'hE24B4A, "RUN 状态条 = 红 0xE24B4A");

        // [C3] WARN → 状态条黄
        m_state = 2'd2;
        repeat (3) @(posedge clk);
        @(posedge clk); px_x = 320; px_y = 10;
        repeat (3) @(posedge clk);
        chk(data_o == 24'hF0A020, "WARN 状态条 = 黄 0xF0A020");

        // [C4] IDLE → 状态条绿
        m_state = 2'd0;
        repeat (3) @(posedge clk);
        @(posedge clk); px_x = 320; px_y = 10;
        repeat (3) @(posedge clk);
        chk(data_o == 24'h2FA84F, "IDLE 状态条 = 绿 0x2FA84F");

        // [C5] 非 OSD 区 → 透传
        m_state = 2'd1;
        repeat (3) @(posedge clk);
        @(posedge clk); px_x = 320; px_y = 300; data_i = 24'hABCDEF;
        repeat (3) @(posedge clk);
        chk(data_o == 24'hABCDEF, "非 OSD 区(y=300) → 透传");

        // [C6] 进度条区(sec=10 → fill=100): 已过区(x<530) = 状态色; 未过区 = 深灰
        m_sec = 6'd10;
        repeat (3) @(posedge clk);
        @(posedge clk); px_x = 480; px_y = 186;   // 已过区(480 < 430+100=530)
        repeat (3) @(posedge clk);
        chk(data_o == 24'hE24B4A, "进度条已过区 = 红(状态色)");
        @(posedge clk); px_x = 580; px_y = 186;   // 未过区(580 >= 530)
        repeat (3) @(posedge clk);
        chk(data_o == 24'h384048, "进度条未过区 = 深灰 0x384048");

        //========================================================
        // [C7][C8][C9] MM:SS 倒计时(sec=20 → 显示 "00:20")
        //   几何: X0=376 Y0=64, 字宽48 字高64 段厚8。
        //   各字左沿: d3=376 d2=432 冒号=488 d1=512 d0=568
        //   段 a(上横) dy<8, dx∈[8,40) → y∈[64,72) x∈[x0+8,x0+40)
        //========================================================
        m_state = 2'd1; m_sec = 6'd20;
        repeat (3) @(posedge clk);

        // 面板底(近黑): 取面板左内角, 避开描边/数字/进度条/状态条
        //   面板 x∈[364,628) y∈[52,140); 取 (368, 96) → 非描边非数字
        sample(12'd368, 12'd96, 24'h0A1018, "倒计时面板底 = 近黑 0x0A1018");

        // 面板描边(状态色 RUN=红): 左边框 x∈[364,366)
        sample(12'd365, 12'd96, 24'hE24B4A, "面板左边框 = 红(状态色)");

        // 4 位数字 + 冒号点亮像素 = 白
        //   d3(0) 段a: (400,68); d2(0) 段a: (456,68)
        //   冒号上块:  (490,88)
        //   d1(2) 段a: (536,68); d0(0) 段a: (592,68)
        sample(12'd400, 12'd68, 24'hFFFFFF, "分钟十位 0 → 段a 白");
        sample(12'd456, 12'd68, 24'hFFFFFF, "分钟个位 0 → 段a 白");
        sample(12'd490, 12'd88, 24'hFFFFFF, "冒号上块 → 白");
        sample(12'd536, 12'd68, 24'hFFFFFF, "秒十位 2 → 段a 白");
        sample(12'd592, 12'd68, 24'hFFFFFF, "秒个位 0 → 段a 白");

        // [C9] 数字熄灭像素 = 面板底(不是白): d3 为 0 → 段g(中横) 不亮
        //   中横 dy∈[28,36) → y∈[92,100); 取 (400,96) 在字格内但段g 灭(字0 g 不亮)
        sample(12'd400, 12'd96, 24'h0A1018, "分钟十位 0 的段g 灭 → 面板底");

        // 换 sec=15 → "00:15": 秒十位 1 → 段a 灭(dy<8 不亮), 段b(右竖上)亮
        //   段b dy∈[8,30) → y∈[72,94); x∈[x0+40,x0+48) → x∈[552,560)
        m_sec = 6'd15;
        repeat (4) @(posedge clk);
        sample(12'd556, 12'd80, 24'hFFFFFF, "秒十位 1 → 段b(右竖上) 白");
        sample(12'd536, 12'd68, 24'h0A1018, "秒十位 1 → 段a 灭(面板底)");

        //========================================================
        // ★[C10] 空闲态(会议全部结束): state=IDLE + sec=0 → 绿条 + 显示 "00:00"
        //   用户需求(2026-10-09o): 会议走完 3 场后进空闲, 应看到绿条 + 00:00。
        //========================================================
        m_state = 2'd0; m_sec = 6'd0;
        repeat (4) @(posedge clk);
        // 状态条绿(空闲)
        sample(12'd320, 12'd10, 24'h2FA84F, "[C10] 空闲态状态条 = 绿 0x2FA84F");
        // 面板描边也应是绿色(状态色)
        sample(12'd365, 12'd96, 24'h2FA84F, "[C10] 空闲态面板左边框 = 绿");
        // 四位数字全为 0: 段 a(上横) 均白 → "00:00"
        sample(12'd400, 12'd68, 24'hFFFFFF, "[C10] 空闲 00:00 分钟十位 0 段a 白");
        sample(12'd456, 12'd68, 24'hFFFFFF, "[C10] 空闲 00:00 分钟个位 0 段a 白");
        sample(12'd536, 12'd68, 24'hFFFFFF, "[C10] 空闲 00:00 秒十位 0 段a 白");
        sample(12'd592, 12'd68, 24'hFFFFFF, "[C10] 空闲 00:00 秒个位 0 段a 白");
        // 冒号仍亮(00:00 有冒号)
        sample(12'd490, 12'd88, 24'hFFFFFF, "[C10] 空闲 00:00 冒号上块 白");
        // 进度条 sec=0 → fill=0, 整条未过(深灰)
        sample(12'd500, 12'd186, 24'h384048, "[C10] 空闲态进度条全空(深灰)");

        $display("========================================");
        $display("tb_meeting_osd: %0d PASS / %0d FAIL", npass, nfail);
        if (nfail == 0) $display("ALL PASS");
        else            $display("FAILED");
        $finish;
    end

endmodule
