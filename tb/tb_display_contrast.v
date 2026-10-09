//====================================================================
// 模块名 : tb_display_contrast.v —— ★对比度功能回归(2026-10-09c 新增)
// 验证   : display_adjust 的 stage2b「对比度」运算 + 对比度 HUD 条几何
// 需求   : 用户 2026-10-09 指定"迎新场景4 / 抢答场景3 = 对比度";
//          ★2026-10-09f 起"应急场景2 = 对比度, 应急3 = 音量"。
//          RTL 公式(小鹅通口径) out = (in-128)*k/128 + 128, k = 8 + con*15
//          (con:0..15 → k:8..233; con=8 → k=128 = 中性, 天然透传)
//          门控: alpha!=255(淡入淡出期间) 时旁路 —— 保黑场纯黑
// 用例   :
//   [Case1] con=8(k=128) 中性: 整帧与输入逐位相同(数学恒等, 非旁路)
//   [Case2] con=15(k=233) 像素算术: 输入 64 → 期望 Q; 输入 192 → 期望 R;
//           输入 128(中灰) → 128(中心不动)
//   [Case3] con=0(k=8)  像素算术: 输入 64 → 期望 Q; 输入 192 → 期望 R
//   [Case4] HUD 条几何: con=12 → 描边286 / FG=648 / BG=162(品红 B47CFF)
//   [Case5] HUD 条几何: con=8  → 描边286 / FG=432 / BG=378
//   [Case6] HOLD(30帧) 到期整条消失
// 货 : 与 tb_display_adjust 同法(vs 上升沿清计数器, 下降沿前结算)
//      画布 640×80 以覆盖对比度条 y64..71(原 tb 只到 64 行 → 覆盖不到)
//====================================================================

`timescale 1ns/1ps
module tb_display_contrast;

    // ---- 画布: 覆盖对比度条 y64..71 → 高 80 ----
    localparam H_ACT   = 640;
    localparam H_FP    = 8;
    localparam H_SYNC  = 32;
    localparam H_BP    = 16;
    localparam H_TOT   = H_ACT + H_FP + H_SYNC + H_BP;   // 696
    localparam V_ROWS  = 80;
    localparam V_FP    = 2;
    localparam V_SYNC  = 2;
    localparam V_BP    = 2;
    localparam V_TOT   = V_ROWS + V_FP + V_SYNC + V_BP;  // 86
    localparam H_START = H_FP + H_SYNC + H_BP;           // 56
    localparam V_START = V_FP + V_SYNC + V_BP;           // 6
    localparam CLK     = 40;

    localparam AREA    = H_ACT * V_ROWS;                 // 51200

    // 对比度条几何(与 RTL 一致)
    localparam C_BDB   = 24'hE4F0FF;    // HUD 描边(近白)
    localparam C_CONF  = 24'hB47CFF;    // 对比度生效档位(品红)
    localparam C_CBGS  = 24'h101418;    // 未生效档位(深)
    localparam EX_CBD  = 286;           // 盒 137×8 → 2*(137+8)-4
    localparam EX_CIN  = 810;           // 内区 135×6
    localparam EX_CFG12= 648;           // 12*9=108 列 ×6 行
    localparam EX_CBG12= 162;           // 810-648
    localparam EX_CFG8 = 432;           // 8*9=72 列 ×6 行
    localparam EX_CBG8 = 378;           // 810-432

    //--------------- 信号 ----------------
    reg         clk;
    reg         rst;
    wire        hs_i, vs_i, de_i;
    wire [23:0] data_i;
    wire [11:0] px_i, py_i;
    reg         menu_active;
    reg         emerg;
    reg         bmp_busy;
    reg  [3:0]  bri_level;
    reg  [3:0]  vol_level;
    reg  [3:0]  res_level;
    reg  [3:0]  con_level;
    reg         pic_manual;
    reg  [2:0]  ui_mode;
    reg  [1:0]  img_res;
    reg         iris_trig;
    wire        hs_o, vs_o, de_o;
    wire [23:0] data_o;

    initial clk = 1'b0;
    always #(CLK/2) clk = ~clk;

    //--------------- 被测模块 ----------------
    display_adjust #(
        .H_ACT (H_ACT),
        .V_ACT (V_ROWS),
        .IRIS_FRAMES (8'd0)      // 关 iris, 隔离对比度行为
    ) dut (
        .video_clk  (clk),
        .rst        (rst),
        .hs_i       (hs_i),
        .vs_i       (vs_i),
        .de_i       (de_i),
        .data_i     (data_i),
        .px_x       (px_i),
        .px_y       (py_i),
        .menu_active(menu_active),
        .emerg      (emerg),
        .bmp_busy   (bmp_busy),
        .iris_trig  (iris_trig),
        .wipe_trig  (1'b0),     // ★左→右 Wipe(2026-10-09j; 本 TB 不测, 置 0)
        .bri_level  (bri_level),
        .vol_level  (vol_level),
        .res_level  (res_level),
        .con_level  (con_level),
        .img_res    (img_res),
        .pic_manual (pic_manual),
        .ui_mode    (ui_mode),
        .quiz_on    (1'b0),
        .meeting_on (1'b0),     // ★会议场景(2026-10-09j; 本 TB 不测, 置 0)
        .q_state    (2'd0),
        .q_end      (1'b0),
        .sc0        (8'sd0),
        .sc1        (8'sd0),
        .sc2        (8'sd0),
        .sc3        (8'sd0),
        .sc_evt     (1'b0),
        .sc_team    (2'd0),
        .hs_o       (hs_o),
        .vs_o       (vs_o),
        .de_o       (de_o),
        .data_o     (data_o)
    );

    //--------------- 扫描发生器 ----------------
    reg [15:0] hcnt, vcnt;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hcnt <= 16'd0;
            vcnt <= 16'd0;
        end
        else if (hcnt == H_TOT-1) begin
            hcnt <= 16'd0;
            if (vcnt == V_TOT-1) vcnt <= 16'd0; else vcnt <= vcnt + 16'd1;
        end else hcnt <= hcnt + 16'd1;
    end
    assign hs_i = ~((hcnt >= H_FP) && (hcnt < H_FP+H_SYNC));
    assign vs_i = ~((vcnt >= V_FP) && (vcnt < V_FP+V_SYNC));
    assign de_i = (hcnt >= H_START) && (hcnt < H_START+H_ACT) &&
                  (vcnt >= V_START) && (vcnt < V_START+V_ROWS);
    assign px_i = de_i ? (hcnt - H_START) : 12'd0;
    assign py_i = de_i ? (vcnt - V_START) : 12'd0;
    reg [23:0] IN_PIX;
    assign data_i = IN_PIX;

    //--------------- 整帧统计 ----------------
    //   口径同 tb_display_adjust: 在 de_o 内按输出色分类, vs_o 下降沿结算。
    integer c_bd, c_cfg, c_cbg, c_pix, c_unk;
    integer act_cnt;
    reg vs_o_d = 1'b1;       // 上一拍 vs_o(帧边界检测)
    reg [23:0] cur_pix;      // 期望的"非 HUD"像素色
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            c_bd<=0; c_cfg<=0; c_cbg<=0; c_pix<=0; c_unk<=0; act_cnt<=0;
        end
        else begin
            if (de_o) begin
                act_cnt <= act_cnt + 1;
                if      (data_o === C_BDB)   c_bd  <= c_bd  + 1;
                else if (data_o === C_CONF)  c_cfg <= c_cfg + 1;
                else if (data_o === C_CBGS)  c_cbg <= c_cbg + 1;
                else if (data_o === cur_pix) c_pix <= c_pix + 1;
                else                         c_unk <= c_unk + 1;
            end
            if (vs_o_d && ~vs_o) begin     // 帧边界结算
                c_bd<=0; c_cfg<=0; c_cbg<=0; c_pix<=0; c_unk<=0; act_cnt<=0;
            end
            vs_o_d <= vs_o;
        end
    end

    //--------------- 检查/工具任务 ----------------
    integer err_cnt;

    task chk;
        input [255:0] name;
        input integer got;
        input integer exp;
        begin
            if (got === exp) begin
                $display("  [PASS] %0s = %0d (exp %0d)", name, got, exp);
            end else begin
                $display("  [FAIL] %0s = %0d (exp %0d)", name, got, exp);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    task wait_frames;
        input integer n;
        integer i;
        begin
            for (i=0; i<n; i=i+1) @(negedge vs_o);
        end
    endtask

    // 采一整帧: 等一帧结束(vs_o 下降沿)即可。
    //   ★2026-10-09e 修正竞态: 统计块在同一个 negedge 上**同时**做"清零 + 翻
    //     vs_o_d", 若本 task 与该块在同一时刻被唤醒, 读到的是"清零后的 0"
    //     (非阻塞赋值与 task 唤醒的先后不确定)。
    //     加一个极小的 #1 延迟, 让统计块的 NBA 更新先落地, 再读稳定值。
    task sample_frame;
        begin
            @(negedge vs_o);
            #1;                     // 让统计块的 NBA 更新落地(消除零时刻竞态)
        end
    endtask

    // ★改输入像素并采一整帧(2026-10-09e)
    //   IN_PIX 是组合直连 data_i, 若在**帧中间**改, 该帧会变成"半新半旧"的
    //   混合帧 → 整帧计数对不上(这是本次调 TB 踩的坑)。
    //   正确做法: 先等到帧边界(negedge vs_o)再改 IN_PIX 与 cur_pix,
    //   然后等**下一个**帧边界 —— 这一帧从头到尾都是新像素, 计数才干净。
    //   (task 内不能引用非 input 的局部变量, 故 cur_pix 由调用方在改完后
    //    用 set_cur 同步; 这里用 task 参数把"期望色"一并带入。)
    reg [23:0] tgt_pix;                 // task 与主流程共享的临时期望色
    task set_pix;                       // 只改输入像素(在帧边界处调用)
        input [23:0] p;
        begin
            IN_PIX  = p;
            cur_pix = p;
        end
    endtask

    //   改像素 → 等一帧让它铺满整帧 → 再等一帧结算, 共两帧
    task pix_frame;
        input [23:0] p;
        begin
            @(negedge vs_o);            // 对齐到帧边界再改(避免混合帧)
            IN_PIX  = p;
            cur_pix = p;
            @(negedge vs_o);            // 本帧(全为新像素)结算
            #1;
        end
    endtask

    // ★对比度专用: 输入 in_color, 期望输出色 exp_color(在帧边界改, 采一整帧)
    task in_frame;
        input [23:0] in_color;
        input [23:0] exp_color;
        begin
            @(negedge vs_o);            // 对齐帧边界
            IN_PIX  = in_color;
            cur_pix = exp_color;        // 统计块按 exp 分类(与输入分开)
            @(negedge vs_o);            // 本帧结算
            #1;                         // 等统计块 NBA 落地(避免与 chk 竞态)
        end
    endtask

    // 用 RTL 同式算期望像素(有符号中心化 + 截断右移)
    //   ★2026-10-09e: k 映射改为 k = 8 + con*15 (8..233), 与小鹅通口径一致
    //     (con=8 → k=128 中性; con=15 → 233 增强; con=0 → 8 最弱)
    function [7:0] con_exp;
        input integer in;
        input integer con;
        integer k, ctr, prod, q;
        begin
            k   = 8 + con*15;
            ctr = in - 128;
            prod = ctr * k;          // 算术乘法
            q = prod / 128;          // Verilog 算术右移 = 向 -inf 取整 → 与除法同
            if (prod < 0 && (prod % 128 != 0)) q = prod/128 - 1;  // 向 -inf
            q = q + 128;
            if (q > 255) q = 255;
            if (q < 0)   q = 0;
            con_exp = q[7:0];
        end
    endfunction

    //--------------- 主流程 ----------------
    integer e64, e192, e128;
    integer got;

    initial begin
        err_cnt = 0;
        c_bd=0; c_cfg=0; c_cbg=0; c_pix=0; c_unk=0;
        rst = 1'b1;
        menu_active = 1'b1;     // 稳态(菜单态 → 不淡出, alpha 恒 255)
        emerg       = 1'b0;
        bmp_busy    = 1'b0;
        bri_level   = 4'd8;     // ×1.0 直通
        vol_level   = 4'd8;
        res_level   = 4'd4;
        con_level   = 4'd8;
        pic_manual  = 1'b0;
        ui_mode     = 3'd0;
        img_res     = 2'd1;
        iris_trig   = 1'b0;
        IN_PIX      = 24'h808080;
        cur_pix     = 24'h808080;

        repeat (6) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // 让扫描从整帧起点跑起来: 先等若干完整帧, 使内部状态(alpha 等)稳定
        wait_frames(3);

        //=========================================================
        $display("");
        $display("[Case1] con=8(k=128, 中性): 整帧应逐位等于输入(数学恒等)");
        //=========================================================
        con_level = 4'd8;
        IN_PIX    = 24'h808080;      // 中灰(初值, 已稳定)
        cur_pix   = 24'h808080;
        sample_frame();
        chk("case1 中灰 passthru px", c_pix, AREA);
        chk("case1 中灰 unknown px",  c_unk, 0);
        // ★中性档必须对**任意**输入都恒等(不能只在中灰成立):
        //   旧实现是"旁路", 只保证透传; 新实现是"k=128 数学恒等", 同样应逐位相同。
        //   ※ 用 pix_frame 在帧边界改像素, 避免"半新半旧"混合帧。
        pix_frame(24'h2A5A8A);       // 三通道各不相同(0x2A/0x5A/0x8A, 暗/中/亮)
        chk("case1 三色 passthru px", c_pix, AREA);
        chk("case1 三色 unknown px",  c_unk, 0);
        pix_frame(24'hFFFFFF);       // 全白(边界)
        chk("case1 全白 passthru px", c_pix, AREA);
        chk("case1 全白 unknown px",  c_unk, 0);
        pix_frame(24'h808080);       // 恢复中灰

        //=========================================================
        $display("");
        $display("[Case2] con=15(k=233) 像素算术");
        $display("        期望: in=64→%0d, in=192→%0d, in=128→%0d",
                 con_exp(64,15), con_exp(192,15), con_exp(128,15));
        //=========================================================
        con_level = 4'd15;
        wait_frames(34);          // 先让档变提示条过期, 免得干扰
        // --- in = 64 ---
        e64     = con_exp(64,15);
        in_frame(24'h404040, {e64[7:0], e64[7:0], e64[7:0]});
        chk("case2 in=64 result px", c_pix, AREA);
        chk("case2 in=64 unknown",   c_unk, 0);
        $display("        (64 -> %0d, 暗部更暗 ✓)", e64);
        // --- in = 192 ---
        e192    = con_exp(192,15);
        in_frame(24'hC0C0C0, {e192[7:0], e192[7:0], e192[7:0]});
        chk("case2 in=192 result px", c_pix, AREA);
        $display("        (192 -> %0d, 亮部更亮 ✓)", e192);
        // --- in = 128(中心不动) ---
        e128    = con_exp(128,15);
        in_frame(24'h808080, {e128[7:0], e128[7:0], e128[7:0]});
        chk("case2 in=128 result px", c_pix, AREA);
        $display("        (128 -> %0d, 中灰不动 ✓)", e128);

        //=========================================================
        $display("");
        $display("[Case3] con=0(k=8) 像素算术: 暗部抬升 → 对比度降至最弱");
        $display("        期望: in=64→%0d, in=192→%0d", con_exp(64,0), con_exp(192,0));
        //=========================================================
        con_level = 4'd0;
        wait_frames(34);
        e64     = con_exp(64,0);
        in_frame(24'h404040, {e64[7:0], e64[7:0], e64[7:0]});
        chk("case3 in=64 result px", c_pix, AREA);
        $display("        (64 -> %0d, 向中灰抬升 ✓)", e64);
        e192    = con_exp(192,0);
        in_frame(24'hC0C0C0, {e192[7:0], e192[7:0], e192[7:0]});
        chk("case3 in=192 result px", c_pix, AREA);
        $display("        (192 -> %0d, 向中灰压低 ✓)", e192);

        //=========================================================
        $display("");
        $display("[Case4] HUD 条几何: con=12 → 描边%0d / 品红FG=%0d / 深槽BG=%0d",
                 EX_CBD, EX_CFG12, EX_CBG12);
        //=========================================================
        con_level = 4'd12;
        e128 = con_exp(128,12);
        @(negedge vs_o);                        // ★对齐帧边界再改输入(避免混合帧)
        IN_PIX  = 24'h808080;
        cur_pix = {e128[7:0], e128[7:0], e128[7:0]};
        sample_frame();          // 档变武装
        sample_frame();          // 条首帧
        chk("case4 bar border", c_bd,  EX_CBD);
        chk("case4 bar FG",     c_cfg, EX_CFG12);
        chk("case4 bar BG",     c_cbg, EX_CBG12);
        chk("case4 bar total",  c_bd + c_cfg + c_cbg + c_pix, AREA);

        //=========================================================
        $display("");
        $display("[Case5] HUD 条几何: con=8 → 品红FG=%0d / 深槽BG=%0d",
                 EX_CFG8, EX_CBG8);
        //=========================================================
        con_level = 4'd8;
        sample_frame();
        sample_frame();
        chk("case5 bar border", c_bd,  EX_CBD);
        chk("case5 bar FG",     c_cfg, EX_CFG8);
        chk("case5 bar BG",     c_cbg, EX_CBG8);
        chk("case5 bar total",  c_bd + c_cfg + c_cbg + c_pix, AREA);

        //=========================================================
        $display("");
        $display("[Case6] 提示条自动消失(VOL_HOLD_FRAMES=30 帧后)");
        //=========================================================
        wait_frames(34);
        sample_frame();
        chk("case6 bar border gone", c_bd,  0);
        chk("case6 bar FG gone",     c_cfg, 0);
        chk("case6 bar BG gone",     c_cbg, 0);
        chk("case6 full frame",      c_pix, AREA);

        $display("");
        $display("==================================================");
        if (err_cnt == 0) $display("  ** ALL PASS (0 FAIL)");
        else              $display("  ** FAILED: %0d", err_cnt);
        $display("==================================================");
        $finish;
    end

    initial begin
        #800_000_000;
        $display("[FAIL] TIMEOUT");
        $finish;
    end

endmodule
