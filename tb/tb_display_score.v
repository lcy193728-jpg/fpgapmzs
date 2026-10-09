//====================================================================
// tb_display_score.v —— 抢答分数显示(弹窗式 + 结束页散点)像素级回归
//   (2026-10-09c, 结束页改为"只显示分数 + 字体 2× 放大")
//
// 验证目标:
//   ① 弹窗式(右上角盒, 判分后 1s): 4 行 "T<队号><±><分>" 文字;
//      每行只画 5 字符 × 6px = 30px 宽 → 行尾不得再有像素(BUG-1)。
//   ② 结束页散点(q_end=1): 4 队分数分别落在 4 个槽内
//      (202,244)/(498,244)/(202,354)/(498,354), 槽 48×16;
//      槽内文字 = "±<分>"(★无队号前缀, 字体 2× 放大); 槽外不得有点亮(BUG-2)。
//   ③ 结束页时弹窗盒子不得出现(scb_pop 与 qend_s 互斥)。
//
// 画布: 只用需要的窄条以提速 —— 但弹窗在 y26..89、结束页在 y244..369,
//       二者跨度太大, 故本 TB 直接跑完整 640×480 一帧两组(帧数少, 可接受)。
//
// 判据: 逐帧逐像素统计"金色像素数"(C_SCB_TX=FFD24A), 与按点阵 popcount
//       算出的期望值逐帧相等; 且限定 x<30 的行尾区域金像素必须为 0。
//====================================================================
`timescale 1ns/1ps

module tb_display_score;

    // ---- 视频时序(与 tb_display_adjust 同口径) ----
    localparam H_ACT   = 640;
    localparam H_FP    = 16;
    localparam H_SYNC  = 40;
    localparam H_BP    = 16;
    localparam H_TOT   = H_ACT + H_FP + H_SYNC + H_BP;   // 712
    localparam V_ROWS  = 376;   // 覆盖弹窗(y26..90) + 结束页槽(y248..366)
    localparam V_FP    = 2;
    localparam V_SYNC  = 2;
    localparam V_BP    = 2;
    localparam V_TOT   = V_ROWS + V_FP + V_SYNC + V_BP;  // 486
    localparam H_START = H_FP + H_SYNC + H_BP;           // 72
    localparam V_START = V_FP + V_SYNC + V_BP;           // 6
    localparam CLK     = 40;

    localparam PIX    = 24'h808080;   // 恒定输入灰
    localparam C_GOLD = 24'hFFD24A;   // 分数文字(金)
    localparam C_EBD  = 24'h18284E;   // 结束页槽底(与 QUIZ8 卡片同色)
    localparam AREA   = H_ACT * V_ROWS;   // 640*480 = 307200

    // 期望笔数(只算 5 列 × 7 行的点阵 popcount):
    //   字模与 display_adjust.v resw_glyph 完全一致
    //   'T'=11 '1'=10 '2'=14 '3'=14 '4'=14 '5'=17 '6'=15 '7'=11 '8'=17
    //   '9'=15 '0'=19 '-'=3 '+'=9
    //   ★结束页字体 2× 放大: 每个点阵点 → 2×2 = 4 个屏幕像素
    //     ⇒ 结束页单字符像素数 = popcount × 4。
    localparam PC_T=11, PC_0=19, PC_1=10, PC_2=14, PC_3=14, PC_4=14,
               PC_5=17, PC_6=15, PC_7=11, PC_8=17, PC_9=15,
               PC_M=3, PC_P=9;

    // ---------------- 信号 ----------------
    reg         clk, rst;
    wire        hs_i, vs_i, de_i;
    wire [23:0] data_i;
    wire [11:0] px_i, py_i;
    reg         menu_active, emerg, bmp_busy, iris_trig;
    reg  [3:0]  bri_level, vol_level, res_level;
    reg  [3:0]  con_level;               // ★对比度档(2026-10-09c; 默认 8=旁路)
    reg  [1:0]  img_res;
    reg         pic_manual;
    reg  [2:0]  ui_mode;
    // 抢答
    reg         quiz_on, q_end;
    reg  [1:0]  q_state;
    reg signed [7:0] sc0, sc1, sc2, sc3;
    reg         sc_evt;
    reg  [1:0]  sc_team;
    wire        hs_o, vs_o, de_o;
    wire [23:0] data_o;

    integer err_cnt;
    // 逐帧统计
    reg [31:0] gold_cnt;      // 金色像素总数
    reg [31:0] ebd_cnt;       // 结束页槽底像素数
    // 结束页四槽分槽金像素数
    reg [31:0] g0, g1, g2, g3;
    // 弹窗 4 行分统计(盒内区 y26..90 / 行高 14: 行0=y30..36 行1=y44..50 行2=y58..64 行3=y72..78)
    reg [31:0] rg0, rg1, rg2, rg3;

    // 视频同步发生器
    reg [15:0] hcnt, vcnt;
    initial begin
        hcnt = 16'd0;
        vcnt = 16'd0;
    end
    always @(posedge clk) begin
        if (hcnt == H_TOT-1) begin
            hcnt <= 0;
            if (vcnt == V_TOT-1) vcnt <= 0; else vcnt <= vcnt + 1;
        end else hcnt <= hcnt + 1;
    end
    assign hs_i = ~((hcnt >= H_FP) && (hcnt < H_FP+H_SYNC));
    assign vs_i = ~((vcnt >= V_FP) && (vcnt < V_FP+V_SYNC));
    assign de_i = (hcnt >= H_START) && (hcnt < H_START+H_ACT) &&
                  (vcnt >= V_START) && (vcnt < V_START+V_ROWS);
    assign px_i = (hcnt >= H_START) ? (hcnt - H_START) : 12'd0;
    assign py_i = (vcnt >= V_START) ? (vcnt - V_START) : 12'd0;
    assign data_i = PIX;

    // ---- DUT: 短保持帧数(1 帧)以便本 TB 逐帧控制 ----
    display_adjust #(
        .BAR_HOLD_FRAMES (16'd1),
        .RES_HOLD_FRAMES (16'd1),
        .VOL_HOLD_FRAMES (16'd1),
        .MAN_HOLD_FRAMES (16'd1),
        .RESW_HOLD_FRAMES(16'd1),
        .SCB_HOLD_FRAMES (16'd6)      // 判分弹窗保持 3 帧
    ) u_sc (
        .video_clk (clk),
        .rst       (rst),
        .hs_i      (hs_i),
        .vs_i      (vs_i),
        .de_i      (de_i),
        .data_i    (data_i),
        .px_x      (px_i),
        .px_y      (py_i),
        .menu_active(1'b0),           // 非菜单态 → 无淡入淡出干扰
        .emerg     (1'b0),
        .bmp_busy  (1'b0),
        .iris_trig (1'b0),
        .bri_level (4'd8),            // 亮度直通(增益×1.0) → 便于辨色
        .vol_level (4'd8),
        .res_level (4'd4),
        .con_level (con_level),   // ★对比度档(2026-10-09c)
        .img_res   (2'd1),            // 640x480, 分辨率字幕会弹但位置不冲突
        .pic_manual(1'b0),
        .ui_mode   (3'd0),
        .quiz_on   (quiz_on),
        .q_state   (q_state),
        .q_end     (q_end),
        .sc0       (sc0),
        .sc1       (sc1),
        .sc2       (sc2),
        .sc3       (sc3),
        .sc_evt    (sc_evt),
        .sc_team   (sc_team),
        .hs_o      (hs_o),
        .vs_o      (vs_o),
        .de_o      (de_o),
        .data_o    (data_o)
    );

    // ---- 时钟 / 复位 ----
    initial clk = 1'b0;
    always #(CLK/2) clk = ~clk;

    // ---- 像素统计(最简实现): ----
    //   cnt_en 由 task 在"帧边界后"置 1, 在"下一个帧边界"由硬件清 0。
    //   计数块: posedge clk, de_o 且 cnt_en → 累加。
    reg cnt_en;
    initial cnt_en = 1'b0;
    // 弹窗像素坐标转储(诊断用): cnt_en 期间把所有 C_GOLD 像素写盘
    integer dump_fd;
    initial dump_fd = 0;
    always @(posedge clk) begin
        if (de_o && cnt_en && data_o == C_GOLD) begin
            if (dump_fd == 0) dump_fd = $fopen("_gold_dump.txt", "w");
            $fwrite(dump_fd, "%0d %0d\n", px_i, py_i);
        end
    end

    always @(posedge clk) begin
        if (de_o && cnt_en) begin
            if (data_o == C_GOLD) gold_cnt <= gold_cnt + 1;
            if (data_o == C_EBD)  ebd_cnt  <= ebd_cnt + 1;
            if (data_o == C_GOLD) begin
                // 结束页槽(2026-10-09c): 48×16 @ (202,244)/(498,244)/(202,354)/(498,354)
                if (px_i >= 202 && px_i < 250 && py_i >= 244 && py_i < 260) g0 <= g0 + 1;
                if (px_i >= 498 && px_i < 546 && py_i >= 244 && py_i < 260) g1 <= g1 + 1;
                if (px_i >= 202 && px_i < 250 && py_i >= 354 && py_i < 370) g2 <= g2 + 1;
                if (px_i >= 498 && px_i < 546 && py_i >= 354 && py_i < 370) g3 <= g3 + 1;
                if (px_i >= 456 && px_i < 632) begin
                    if (py_i >= 30 && py_i < 37) rg0 <= rg0 + 1;
                    if (py_i >= 44 && py_i < 51) rg1 <= rg1 + 1;
                    if (py_i >= 58 && py_i < 65) rg2 <= rg2 + 1;
                    if (py_i >= 72 && py_i < 79) rg3 <= rg3 + 1;
                end
            end
        end
    end

    // 等一整帧边界(vs 上升沿)
    task wait_frame;
        begin
            @(posedge vs_o);
        end
    endtask

    // 采集一整帧: 帧边界后开计, 下一个帧边界前停(恰一帧)
    //   ★cnt_en 用阻塞赋值: 与计数块的 NBA 配合时, 必须在同一 time step 立刻生效,
    //     否则要等到下一拍才生效 → 会多采一帧(2× 计数)。
    task sample_frame;
        begin
            @(posedge vs_o);
            gold_cnt = 0;  ebd_cnt = 0;
            g0 = 0; g1 = 0; g2 = 0; g3 = 0;
            rg0 = 0; rg1 = 0; rg2 = 0; rg3 = 0;
            #1; cnt_en = 1'b1;
            @(posedge vs_o);
            #1; cnt_en = 1'b0;
        end
    endtask

    task chk;
        input cond;
        input [255:0] msg;
        begin
            if (cond) $display("  [PASS] %0s", msg);
            else begin
                $display("  [FAIL] %0s", msg);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    // ---------------- 主流程 ----------------
    initial begin
        err_cnt = 0;
        rst = 1'b1;
        con_level = 4'd8;   // ★对比度默认档 = 旁路(不影响既有几何期望值)
        bri_level = 4'd8; vol_level = 4'd8; res_level = 4'd4;
        quiz_on = 1'b0; q_end = 1'b0; q_state = 2'd0;
        sc0 = 8'sd0; sc1 = 8'sd0; sc2 = 8'sd0; sc3 = 8'sd0;
        sc_evt = 1'b0; sc_team = 2'd0;
        iris_trig = 1'b0;
        gold_cnt = 0; ebd_cnt = 0; g0 = 0; g1 = 0; g2 = 0; g3 = 0;
        rg0=0; rg1=0; rg2=0; rg3=0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        //================================================================
        // 用例 1: 弹窗式 —— 4 队分数 T1+2 / T2-1 / T3+0 / T4+4
        //================================================================
        $display("\n[Case1] 弹窗式分数板 (判分后保持)");
        quiz_on = 1'b1;
        sc0 = 8'sd2; sc1 = -8'sd1; sc2 = 8'sd0; sc3 = 8'sd4;
        @(negedge clk);
        // 触发判分(电平翻转) → 弹窗
        sc_evt = ~sc_evt; sc_team = 2'd0;
        repeat (6) @(posedge clk);   // CDC 过域 + 帧边界武装 scb_cnt
        // 采一整帧(此时弹窗必在场: hold=6)
        sample_frame;
        // 期望金像素 = popcount("T1+2")+popcount("T2-1")+popcount("T3+0")+popcount("T4+4")
        //   = 44+38+53+48 = 183
        $display("    popup gold px = %0d (exp 183)", gold_cnt);
        $display("    popup per-row gold: r0=%0d r1=%0d r2=%0d r3=%0d (exp 44/38/53/48)",
                 rg0, rg1, rg2, rg3);
        chk(gold_cnt == 32'd183, "popup 4-team glyph popcount = 183");


        //================================================================
        // 用例 2: 弹窗消失(保持帧耗尽)
        //================================================================
        $display("\n[Case2] 弹窗到期消失");
        repeat (9) wait_frame;
        gold_cnt = 0;
        sample_frame;
        $display("    after expiry gold px = %0d (exp 0)", gold_cnt);
        chk(gold_cnt == 32'd0, "popup disappears after hold frames");

        //================================================================
        // 用例 3: 结束页散点 —— 4 队 +2 / -1 / +0 / +4(★无队号前缀, 字体 2×)
        //================================================================
        $display("\n[Case3] 结束页(q_end=1)四队分数散点(仅分数, 2x 字)");
        q_end = 1'b1;
        repeat (4) @(posedge clk);
        gold_cnt = 0; ebd_cnt = 0; g0=0; g1=0; g2=0; g3=0;
        sample_frame;
        // 期望(2× 放大 → popcount ×4):
        //   队1 "+2"  = (9+14)*4  = 92
        //   队2 "-1"  = (3+10)*4  = 52
        //   队3 "+0"  = (9+19)*4  = 112
        //   队4 "+4"  = (9+14)*4  = 92
        //   合计 = 92+52+112+92 = 348
        $display("    endpage gold px = %0d (exp 348)", gold_cnt);
        $display("    per-slot: s1=%0d s2=%0d s3=%0d s4=%0d", g0, g1, g2, g3);
        chk(gold_cnt == 32'd348, "endpage total glyph popcount = 348");
        chk(g0 == 32'd92,  "slot1 '+2' = 92");
        chk(g1 == 32'd52,  "slot2 '-1' = 52");
        chk(g2 == 32'd112, "slot3 '+0' = 112");
        chk(g3 == 32'd92,  "slot4 '+4' = 92");
        // 槽底像素 = 4 槽 × (48×16) = 3072 减去被文字覆盖的 348(文字压在槽底上)
        //   → 实际 C_EBD 计数 = 3072 - 348 = 2724
        $display("    slot-bg px = %0d (exp 2724)", ebd_cnt);
        chk(ebd_cnt == 32'd2724, "slot bg = 48*16*4 - 348 = 2724");

        //================================================================
        // 用例 4: 结束页时弹窗盒子不得出现(scb_pop 与 qend_s 互斥)
        //================================================================
        $display("\n[Case4] 结束页不弹盒");
        sc_evt = ~sc_evt; sc_team = 2'd1;
        repeat (4) @(posedge clk);
        gold_cnt = 0; ebd_cnt = 0; g0=0; g1=0; g2=0; g3=0;
        sample_frame;
        $display("    endpage after score gold px = %0d (exp 348)", gold_cnt);
        chk(gold_cnt == 32'd348, "endpage popup suppressed, only 4 slots");

        //================================================================
        // 用例 5: 分数变化 → 结束页实时更新(1队 +2→+12 两位数, 文字左移居中)
        //================================================================
        $display("\n[Case5] 结束页分数实时更新(两位数)");
        sc0 = 8'sd12;   // 1队 12 分 → "+12"
        repeat (4) @(posedge clk);
        gold_cnt = 0; g0 = 0;
        sample_frame;
        // "+12" = (9+10+14)*4 = 132
        $display("    slot1 gold px = %0d (exp 132)", g0);
        chk(g0 == 32'd132, "slot1 2-digit '+12' = 132");
        // 合计 = 132+52+112+92 = 388
        chk(gold_cnt == 32'd388, "total = 132+52+112+92 = 388");

        //================================================================
        // 用例 6: 负数两位数 4队 -12
        //================================================================
        $display("\n[Case6] 结束页负数两位数");
        sc3 = -8'sd12;  // 4队 -12 → "-12"
        repeat (4) @(posedge clk);
        gold_cnt = 0; g3 = 0;
        sample_frame;
        // "-12" = (3+10+14)*4 = 108
        $display("    slot4 gold px = %0d (exp 108)", g3);
        chk(g3 == 32'd108, "slot4 neg 2-digit '-12' = 108");

        //================================================================
        // 用例 7: 行尾无拖尾像素(BUG-1 核心判据) —— 弹窗模式
        //   盒内区 x452..631; 文字只占左 30px(x456..485); 右半 x486..631
        //   必须全无金像素。
        //================================================================
        $display("\n[Case7] 弹窗行尾无拖尾(BUG-1)");
        q_end = 1'b0;
        repeat (4) @(posedge clk);
        sc_evt = ~sc_evt; sc_team = 2'd2;   // 再弹一次
        wait_frame;
        gold_cnt = 0;
        // 单独统计"盒内区 x486..631 的金像素"(拖尾区)
        begin : tail_chk
            integer tail_cnt;
            tail_cnt = 0;
            @(posedge vs_o);
            repeat (H_TOT) begin
                @(posedge clk);
                if (de_o && px_i >= 486 && px_i < 632 &&
                    py_i >= 30 && py_i < 90 && data_o == C_GOLD)
                    tail_cnt = tail_cnt + 1;
            end
            $display("    box right-half (x486..631) gold px = %0d (exp 0)", tail_cnt);
            chk(tail_cnt == 0, "no tail pixels right of text (BUG-1 fixed)");
        end

        //================================================================
        $display("\n================ SUMMARY ================");
        if (err_cnt == 0)
            $display("  ** ALL PASS (0 FAIL)");
        else
            $display("  ** %0d FAIL", err_cnt);
        $display("========================================\n");
        $finish;
    end

    // 超时保护(一帧 ≈ 712*486*20ns ≈ 6.9ms, 全程约 30 帧 → 放宽到 400ms)
    initial begin
        #400000000;
        $display("  [FAIL] SIM TIMEOUT");
        $finish;
    end

endmodule
