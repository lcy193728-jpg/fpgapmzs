//====================================================================
// 模块名 : tb_osd_scene.v —— 抢答 / 应急 两场景 OSD 像素级回归
// 被测   : src/osd_scene.v (三级管线 + 真汉字字库叠加)
//
// 变更史 : v11(2026-10-07) 会议场景整体删除 —— 本 TB 同步删掉
//          meeting_en / run_hh·mm·ss 端口、spot_meeting 用例、
//          全部 MT_* 期望量与区域面积常量; 窗口序列由 10 个压到 8 个。
//          ★ 同时把应急底带的期望墨点从**写死常量**改为
//            foot_sum_af(phase) —— 按当帧真实相位逐列求和。
//            原因: 应急底带周期 384px、屏宽 640px, 640 = 384 + 256,
//            多出的 256 列位置随相位平移; 写死常量是"碰巧对上了"而
//            不是推导正确。calc_expect() 会把 384 个相位全跑一遍并
//            打印实测 min/max 与旧常量对比(见 "A_FOOT 每帧墨点" 一行),
//            结论据此判定, 不再依赖巧合。
//
// 方法   : 生成 VGA 640×480 时序, 以恒定背景色 BG 送入 osd_scene
//          (data_i 与 px_x/px_y 同拍), 按帧切换场景使能, 逐帧结算:
//            · 全帧有效像素数 act_cnt 恒 = 640×480 = 307200;
//            · 逐"唯一输出色"计数(case(data_o))与几何+字模推导严格相等;
//            · 字形 ON/OFF 采样点比对(坐标取自 tools/gen_osd_font.py 打印);
//            · 出现未定义颜色即判 FAIL(抓毛刺/仲裁错误)。
//
// 期望值来源: 各带**墨点数由本 TB 直接从字形 ROM 读回统计**
//          (u_font_rom.mem[]), 因此与 ROM 内容自洽:
//            ★V3 字库: 2× 带存 32×32 真字模 1:1 显示 → 墨点 = Σ popcount32;
//                      1× 带存 16×16 字模       → 墨点 = Σ popcount(低 16 位);
//              NUM 数字带仍为 16×16 字模, 硬件 2× 行列折叠 → 屏上 = 4 × Σ;
//            抢答滚动带(周期 320px, 整 2 周期铺满 640) 墨点 = 2 × Σ(相位无关);
//            应急滚动带(周期 384px) 墨点 = 逐列查表按相位求和(相位相关)。
//          区域面积(由 osd_scene.v 几何常数推得, 与 px3/py3 无关的固定掩膜):
//            抢答: 标题带 11520 / 状态面板 46080 / 底带 26880
//                  → 透传 BG = 222720
//            应急: 顶红条 33280 / 深红标题带 17280 / 底带 26880
//                  → 透传 BG = 229760
//          ※ 应急红条按 4Hz 闪烁, 帧内可能落在亮相或暗相, 故只断言
//            (亮相 + 暗相 + 警示三角) = 33280 + 底带滚动金 且三角墨点 > 0。
//
// 段序(按 vs_o 下降沿结算窗口, 复位后首个空窗跳过):
//   窗口0       : 三使能全 0                → 纯透传
//   窗口1       : 抢答 qstate=0 等待开始
//   窗口2       : 抢答 qstate=1 抢答中(倒计时 05)
//   窗口3       : 抢答 qstate=2 已锁定(3 号)
//   窗口4       : 抢答 qstate=3 时间到
//   窗口5,6     : 应急(红条闪烁/三角/深红标题/滚动告警)
//   窗口7       : 三使能全 0                → 复透传(证明使能可控)
//====================================================================

`timescale 1ns/1ps
module tb_osd_scene;

    localparam H_ACT   = 640;
    localparam H_FP    = 16;
    localparam H_SYNC  = 96;
    localparam H_BP    = 48;
    localparam H_TOT   = H_ACT + H_FP + H_SYNC + H_BP;   // 800
    localparam V_ACT   = 480;
    localparam V_FP    = 10;
    localparam V_SYNC  = 2;
    localparam V_BP    = 33;
    localparam V_TOT   = V_ACT + V_FP + V_SYNC + V_BP;   // 525
    localparam H_START = H_FP + H_SYNC + H_BP;           // 160
    localparam V_START = V_FP + V_SYNC + V_BP;           // 45
    localparam CLK     = 40;                             // ≈25.175MHz

    localparam TOT_PIX = H_ACT * V_ACT;                  // 307200

    //------ 输入背景(BG) 与 唯一输出色(与 osd_scene.v 常量一一对应) ------
    //   多个 localparam 同值(金/白/橙)折叠为同一条 case 分支:
    //    C_GOLD  = QZ_TITLE/QZ_DIG/AL_ICO/AL_FOOT
    //    C_WHITE = QZ_TXT/AL_TITLE
    //    C_ORNG  = QZ_FOOT
    //   v11 起 C_STEEL(会议 M_RUN 标签专用)随会议层一起删除。
    localparam BG      = 24'h204080;
    localparam C_GOLD  = 24'hFFD24A;
    localparam C_WHITE = 24'hF5FDFF;
    localparam C_ORNG  = 24'hFF7A1F;
    localparam C_BARA  = 24'hFF2A2A;   // 应急红条(亮相)
    localparam C_BARB  = 24'h8A0000;   // 应急红条(暗相)/三角感叹号
    localparam C_ALRED = 24'h552040;   // 应急深红衬底(=(BG+8A0000)>>1)
    localparam C_NAVY  = 24'h153363;   // 标题条藏蓝 50%((BG+0A2647)>>1)
    localparam C_PANEL = 24'h0F2C55;   // 面板藏蓝 75%((BG+3*0A2647)>>2)
    localparam C_DARK  = 24'h081020;   // 底带暗色(BG>>2)

    //------ 区域面积(由 osd_scene.v 几何常数推得) ------
    localparam QZ_AREA_BAND = 48*240;    // 11520  y12..59 x200..439
    localparam QZ_AREA_PANL = 144*320;   // 46080  y84..227 x160..479
    localparam AL_AREA_BAR  = 52*640;    // 33280  行0..51 全区宽
    localparam AL_AREA_TBND = 48*360;    // 17280  y74..121 x140..499
    localparam FOOT_AREA    = 42*640;    // 26880  y438..479

    //------ 底带滚动几何(与 osd_scene.v 的 mw_m/aw_m 取模一致) ------
    localparam QF_BASE_P = 4672;         // 抢答底带 ROM 基址
    localparam QF_N      = 20;           // 抢答底带字数
    localparam QF_PERIOD = 320;          // 抢答底带周期(px)
    localparam AF_BASE_P = 5312;         // 应急底带 ROM 基址
    localparam AF_N      = 24;           // 应急底带字数
    localparam AF_PERIOD = 384;          // 应急底带周期(px)

    //--------------- 信号 ----------------
    reg         clk;
    reg         rst;
    wire        hs_i, vs_i, de_i;
    wire [23:0] data_i;
    wire [11:0] px_i, py_i;
    wire        hs_o, vs_o, de_o;
    wire [23:0] data_o;
    wire [11:0] px_x_o, px_y_o;

    reg         quiz_en, alarm_en;
    reg  [1:0]  qstate;
    reg  [1:0]  winner;
    reg  [3:0]  t_tens, t_ones;

    // 结算/统计
    integer     cnt_err;                 // 计数类失败
    integer     sp_err;                  // 采样点类失败
    integer     valid_cnt;
    reg  [31:0] act_cnt;
    reg  [31:0] c_bg, c_navy, c_panel, c_dark, c_alred;
    reg  [31:0] c_gold, c_white, c_orng, c_bara, c_barb;
    reg         vs_o_d;

    // 诊断: 抢答面板内各字形窗的墨点/着色计数(定位几何与着色)
    reg  [31:0] d_st_ink,  d_st_white;   // 状态文字 x256..383 y96..127
    reg  [31:0] d_w_ink,   d_w_gold;     // 胜者号   x256..287 y96..127
    reg  [31:0] d_o_ink,   d_o_gold;     // 倒计时个位 x304..335 y180..211
    reg  [31:0] d_s_ink,   d_s_gold;     // 单位"秒"  x336..367 y180..211

    // 期望值(由 ROM 读回统计, 复位释放后计算)
    integer     ink_qt, ink_qw, ink_qr, ink_ql, ink_qx, ink_qn;
    integer     ink_qsec, ink_qf, ink_at;
    integer     ink_af_all, ink_af16, ink_tmp;
    integer     af_min, af_max, af_hard;
    integer     num_ink [0:9];
    integer     q_dig_run;               // 倒计时 5 秒 + "秒"
    integer     exp_qf, exp_af;          // 底带墨点(按当帧相位求和)

    // 底带"逐列墨点"查表: pos(=char*16+col) → 该列墨点数
    integer     qf_pos [0:319];
    integer     af_pos [0:383];

    integer     ex_qz_navy, ex_qz_gold, ex_qz_orng, ex_qz_dark, ex_qz_bg;
    integer     ex_qz_white, ex_qz_dig, ex_qz_panel;
    integer     ex_al_white, ex_al_alred, ex_al_dark, ex_al_bg;

    integer     i;

    //--------------- 例化被测模块 ----------------
    // 共享字形 ROM(与 top 同构: 实体在 TB 顶层例化, 被 u_scene 读)
    wire        rom_en_s;
    wire [12:0] rom_addr_s;
    wire [31:0] rom_q;
    osd_font_rom #(.ADDR_W(13), .DEPTH(5856)) u_font_rom (
        .clk   (clk),
        .rst   (rst),
        .rd_en (rom_en_s),
        .addr  (rom_addr_s),
        .q     (rom_q)
    );

    osd_scene #(
        .DATA_W  (24),
        .H_ACT   (H_ACT),
        .V_ACT   (V_ACT)
    ) u_scene (
        .video_clk  (clk),
        .rst        (rst),
        .hs_i       (hs_i),
        .vs_i       (vs_i),
        .de_i       (de_i),
        .data_i     (data_i),
        .px_x       (px_i),
        .px_y       (py_i),
        .quiz_en    (quiz_en),
        .alarm_en   (alarm_en),
        .qstate     (qstate),
        .winner     (winner),
        .t_tens     (t_tens),
        .t_ones     (t_ones),
        .rom_en_o   (rom_en_s),
        .rom_addr_o (rom_addr_s),
        .rom_q      (rom_q),
        .hs_o       (hs_o),
        .vs_o       (vs_o),
        .de_o       (de_o),
        .data_o     (data_o),
        .px_x_o     (px_x_o),
        .px_y_o     (px_y_o)
    );

    //--------------- 时钟 / 复位 ----------------
    initial clk = 1'b0;
    always #(CLK/2) clk = ~clk;

    initial begin
        rst = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
    end

    //--------------- 场景使能/抢答状态 初值(全关=纯透传) ----------------
    initial begin
        quiz_en    = 1'b0;
        alarm_en   = 1'b0;
        qstate     = 2'd0;
        winner     = 2'd0;
        t_tens     = 4'd0;
        t_ones     = 4'd5;          // 等待开始/抢答中均显示 05 秒
    end

    //--------------- 视频时序发生器(模拟 osd_welcome 出口) ----------------
    reg [11:0] h_cnt;
    reg [11:0] v_cnt;
    reg        hs_r, vs_r, de_r;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            h_cnt <= 12'd0;
            v_cnt <= 12'd0;
        end
        else begin
            if (h_cnt == H_TOT - 1) begin
                h_cnt <= 12'd0;
                if (v_cnt == V_TOT - 1)
                    v_cnt <= 12'd0;
                else
                    v_cnt <= v_cnt + 12'd1;
            end
            else
                h_cnt <= h_cnt + 12'd1;
        end
    end

    always @(*) begin
        hs_r = ~(h_cnt >= H_FP && h_cnt < H_FP + H_SYNC);
        vs_r = ~(v_cnt >= V_FP && v_cnt < V_FP + V_SYNC);
        de_r = (h_cnt >= H_START && h_cnt < H_TOT) &&
               (v_cnt >= V_START && v_cnt < V_TOT);
    end
    assign hs_i   = hs_r;
    assign vs_i   = vs_r;
    assign de_i   = de_r;
    assign data_i = de_r ? BG : 24'h000000;      // 恒定背景, 与 de 同拍
    assign px_i   = de_r ? (h_cnt - H_START) : 12'd0;
    assign py_i   = de_r ? (v_cnt - V_START) : 12'd0;

    //================================================================
    // 字形 ROM 墨点统计(直接读回 ROM, 与生成器自洽)
    //================================================================
    function integer pc32; input [31:0] v; integer k; begin
        pc32 = 0;
        for (k = 0; k < 32; k = k + 1)
            if (v[k]) pc32 = pc32 + 1;
    end endfunction

    task band_ink32;                     // 32×32 帯(2× 真字模 1:1)墨点: 行 0..31
        input  integer base;
        input  integer n;
        output integer ink;
        integer rr, cc;
        begin
            ink = 0;
            for (rr = 0; rr < 32; rr = rr + 1)
                for (cc = 0; cc < n; cc = cc + 1)
                    ink = ink + pc32(u_font_rom.mem[base + rr*n + cc]);
        end
    endtask

    task band_ink;                       // 16×16 帯(1×)墨点: 行 0..15, 取低 16 位
        input  integer base;
        input  integer n;
        output integer ink;
        integer rr, cc;
        begin
            ink = 0;
            for (rr = 0; rr < 16; rr = rr + 1)
                for (cc = 0; cc < n; cc = cc + 1)
                    ink = ink + pc32(u_font_rom.mem[base + rr*n + cc] & 32'hFFFF);
        end
    endtask

    task char_ink;                       // 单字符(16 行)墨点
        input  integer base;
        input  integer n;
        input  integer cc;
        output integer ink;
        integer rr;
        begin
            ink = 0;
            for (rr = 0; rr < 16; rr = rr + 1)
                ink = ink + pc32(u_font_rom.mem[base + rr*n + cc] & 32'hFFFF);
        end
    endtask

    //--------------------------------------------------------------
    // 底带按"当帧相位"求墨点(必须逐帧算, 不能只用一个常量)
    //   osd_scene 内: pos = ((px + phase) % 640) % PERIOD
    //                 字 = pos>>4, 带内列 = pos&15
    //                 墨点 = rom[base + (pos&15)*N + (pos>>4)] 的低 16 位
    //   抢答 PERIOD=320 与 640 整除 ⇒ 与相位无关;
    //   应急 PERIOD=384, 640 = 384+256 ⇒ 多出 256 列的位置随相位平移,
    //   故不能只用一个"全 24 格 + 前 16 格"的常量(那只是碰巧相等,
    //   calc_expect 会把 384 个相位全跑一遍实测, 见 "A_FOOT 每帧墨点" 一行)。
    //--------------------------------------------------------------
    function integer foot_sum_qf;
        input integer ph;
        integer x, k, s;
        begin
            s = 0;
            for (x = 0; x < 640; x = x + 1) begin
                k = x + ph;
                if (k >= 640) k = k - 640;
                if (k >= QF_PERIOD) k = k - QF_PERIOD;
                s = s + qf_pos[k];
            end
            foot_sum_qf = s;
        end
    endfunction

    function integer foot_sum_af;
        input integer ph;
        integer x, k, s;
        begin
            s = 0;
            for (x = 0; x < 640; x = x + 1) begin
                k = x + ph;
                if (k >= 640) k = k - 640;
                if (k >= AF_PERIOD) k = k - AF_PERIOD;
                s = s + af_pos[k];
            end
            foot_sum_af = s;
        end
    endfunction

    task calc_expect; begin
        band_ink32(3776,  5, ink_qt);    // QT_TITLE  (2×)
        band_ink32(3936,  4, ink_qw);    // QW_WAIT   (2×)
        band_ink32(4064,  3, ink_qr);    // QR_READY  (2×)
        band_ink32(4160,  2, ink_ql);    // QWL_WIN   (2×)
        band_ink32(4224,  5, ink_qx);    // QWR_WIN   (2×)
        band_ink32(4384,  8, ink_qn);    // QN_NONE   (2×)
        band_ink32(4640,  1, ink_qsec);  // QS_SEC    (2×)
        band_ink  (4672, 20, ink_qf);    // Q_FOOT    (1×, 周期 320 → 恒 ×2)
        band_ink32(4992, 10, ink_at);    // AT_TITLE  (2×)

        band_ink(5312, 24, ink_af_all);  // A_FOOT 全 24 格(仅作参考打印)

        for (i = 0; i < 10; i = i + 1)
            char_ink(5696, 10, i, num_ink[i]);

        // ---- 底带逐列墨点表 ----
        for (i = 0; i < QF_PERIOD; i = i + 1)
            qf_pos[i] = pc32(u_font_rom.mem[QF_BASE_P + (i & 15)*QF_N + (i >> 4)]
                             & 32'hFFFF);
        for (i = 0; i < AF_PERIOD; i = i + 1)
            af_pos[i] = pc32(u_font_rom.mem[AF_BASE_P + (i & 15)*AF_N + (i >> 4)]
                             & 32'hFFFF);

        // ---- 应急底带: 相位相关性实测量化 ----
        //   旧 TB 把期望写成常量 (全 24 格 + 前 16 格)。这里把 384 个相位
        //   全部走一遍, 打印实测最小值/最大值, 用来判定"写死常量"是否
        //   恰好等于每个相位的真值 —— 不再靠推测。
        ink_af16 = 0;
        for (i = 0; i < 16; i = i + 1) begin
            char_ink(5312, 24, i, ink_tmp);
            ink_af16 = ink_af16 + ink_tmp;
        end
        af_min = 0;  af_max = 0;
        for (i = 0; i < AF_PERIOD; i = i + 1) begin
            exp_af = foot_sum_af(i);
            if (i == 0 || exp_af < af_min) af_min = exp_af;
            if (i == 0 || exp_af > af_max) af_max = exp_af;
        end
        af_hard = ink_af_all + ink_af16;

        // ---- 抢答(公共量) ----
        //   NUM 带仍为 16×16 字模, 硬件 2× 行列折叠 → 屏上墨点 = 4 × 字模墨点
        q_dig_run  = 4*num_ink[5] + ink_qsec;      // 倒计时 '5'(折叠×4) + '秒'(32×32 1:1)
        // ★2026-10-09 显示规则再改: 抢答场景 OSD 只剩"倒计时秒数";
        //   标题条(c_navy)、状态字(c_white)、面板(c_panel) **全部不再出现**
        //   → 对应的期望计数一律为 0, 全部像素回到透传背景。
        ex_qz_navy = 0;                            // 标题条已取消
        ex_qz_gold = 0;                            // 标题金字已取消(倒计时另计)
        // 整屏透传, 唯一例外是"抢答中"态的倒计时数字(金色, 非 BG)。
        // 非抢答中态没有倒计时 → 由各段把 ex_qz_dig 置 0, 此处按 0 扣。
        ex_qz_bg   = TOT_PIX;                      // 基准; 段2 再扣倒计时墨点

        // ---- 应急 ----
        ex_al_white = ink_at;                      // 32×32 真字模 1:1
        ex_al_alred = AL_AREA_TBND - ink_at;
        ex_al_bg    = TOT_PIX - AL_AREA_BAR - AL_AREA_TBND - FOOT_AREA;

        $display("---- 字模墨点(读回 ROM 统计) ----");
        $display("  QT=%0d QW=%0d QR=%0d QL=%0d QX=%0d QN=%0d QSEC=%0d Q_FOOT=%0d AT=%0d A_FOOT(全24格)=%0d",
                 ink_qt, ink_qw, ink_qr, ink_ql, ink_qx, ink_qn, ink_qsec,
                 ink_qf, ink_at, ink_af_all);
        $display("  NUM[0..9] = %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                 num_ink[0], num_ink[1], num_ink[2], num_ink[3], num_ink[4],
                 num_ink[5], num_ink[6], num_ink[7], num_ink[8], num_ink[9]);
        $display("  Q_FOOT 每帧墨点(相位无关) = %0d (== 2*%0d = %0d)",
                 foot_sum_qf(0), ink_qf, 2*ink_qf);
        $display("  A_FOOT 每帧墨点 实测相位范围 = %0d .. %0d  (全24格=%0d + 前16格=%0d → 旧写死常量=%0d)",
                 af_min, af_max, ink_af_all, ink_af16, af_hard);
        if ((af_min == af_hard) && (af_max == af_hard))
            $display("  → 相位无关, 旧写死常量恰好恒等(仍按相位实算, 不再依赖巧合)");
        else
            $display("  ★ 相位相关! 旧写死常量=%0d 只覆盖 [%0d..%0d] 的一部分 → 必须按相位实算",
                     af_hard, af_min, af_max);
        $display("---- 期望逐色计数 ----");
        $display("  抢答 BG=%0d NAVY=%0d GOLDbase=%0d  (状态/数字: WHITE/GOLD/PANEL 随 qstate)",
                 ex_qz_bg, ex_qz_navy, ex_qz_gold);
        $display("  应急 BG=%0d WHITE=%0d ALRED=%0d  (顶红条+三角恒=33280)",
                 ex_al_bg, ex_al_white, ex_al_alred);
    end endtask

    //================================================================
    // 采样点核对(坐标取自 tools/gen_osd_font.py 打印)
    //================================================================
    task chk; input [11:0] x; input [11:0] y; input [23:0] expc;
              input [255:0] tag; begin
        if (u_scene.px3 == x && u_scene.py3 == y) begin
            if (data_o !== expc) begin
                sp_err = sp_err + 1;
                $display("t=%0t [FAIL] %0s@(%0d,%0d) got=%h exp=%h",
                         $time, tag, x, y, data_o, expc);
            end
            else
                $display("t=%0t [PASS] %0s@(%0d,%0d)=%h", $time, tag, x, y, data_o);
        end
    end endtask

    task chk2; input [11:0] x; input [11:0] y;
               input [23:0] e1; input [23:0] e2; input [255:0] tag; begin
        if (u_scene.px3 == x && u_scene.py3 == y) begin
            if ((data_o !== e1) && (data_o !== e2)) begin
                sp_err = sp_err + 1;
                $display("t=%0t [FAIL] %0s@(%0d,%0d) got=%h exp={%h|%h}",
                         $time, tag, x, y, data_o, e1, e2);
            end
            else
                $display("t=%0t [PASS] %0s@(%0d,%0d)=%h(闪相)", $time, tag, x, y, data_o);
        end
    end endtask

    // ★2026-10-09 新显示规则: 抢答场景 OSD 只剩"倒计时秒数"一个动态元素,
    //   标题条/状态行/底部滚动全部**透传**卡上题目图与队伍图。
    //   故这里把原先断言"叠加文字"的点, 改为断言"透传背景色"。
    task spot_qz0; begin
        // 题目页(qstate=0/待开始): 标题条/状态行位置必须透传
        chk(246, 21, BG,      "QT_TITLE 透传(题目页不叠标题)");
        chk(240, 20, BG,      "QT_TITLE 透传(条外)");
        chk(262, 97, BG,      "QW_WAIT 透传(题目页不叠状态)");
        chk(256, 96, BG,      "QW_WAIT 透传(面板外)");
        chk(356,181, BG,      "QS_SEC 透传(待开始无倒计时)");
        chk(100,300, BG,      "抢答区外透传");
    end endtask

    task spot_qz1; begin
        // 抢答中(qstate=1): 标题/状态仍不叠, 但**倒计时秒数**要叠金色
        chk(278, 97, BG,      "QR_READY 透传(抢答中不叠状态字)");
        chk(272, 96, BG,      "QR_READY 透传(面板外)");
        chk(356,181, C_GOLD,  "QS_SEC ON(抢答中倒计时)");
    end endtask

    task spot_qz2; begin
        // 已锁定(qstate=2): 队伍图自带队名, OSD 全部透传
        chk(211, 97, BG,      "QWL_WIN 透传(队伍页不叠文字)");
        chk(192, 96, BG,      "QWL_WIN 透传(面板外)");
        chk(326, 97, BG,      "QWR_WIN 透传(队伍页不叠文字)");
        chk(288, 96, BG,      "QWR_WIN 透传(面板外)");
        chk(356,181, BG,      "QS_SEC 透传(锁定后无倒计时)");
    end endtask

    task spot_qz3; begin
        // 超时(qstate=3): 同样全部透传
        chk(217, 97, BG,      "QN_NONE 透传(超时页不叠文字)");
        chk(192, 96, BG,      "QN_NONE 透传(面板外)");
    end endtask

    task spot_alarm; begin
        chk (169, 83, C_WHITE, "AT_TITLE ON");     // 深红衬底标题字
        chk (160, 82, C_ALRED, "AT_TITLE OFF");
        chk (320, 10, C_GOLD,  "警示三角(非感叹号)");
        chk (100,200, BG,      "应急区外透传");
        chk2(  5,  5, C_BARA, C_BARB, "顶部红条(闪相)");
    end endtask

    task check_spots; begin
        case (valid_cnt)
            1: spot_qz0();
            2: spot_qz1();
            3: spot_qz2();
            4: spot_qz3();
            5: spot_alarm();
            default: ;
        endcase
    end endtask

    //================================================================
    // 结算任务
    //================================================================
    task chk_cnt; input [255:0] nm; input [31:0] got; input [31:0] exp; begin
        if (got !== exp) begin
            cnt_err = cnt_err + 1;
            $display("t=%0t [FAIL] 计数 %0s got=%0d exp=%0d", $time, nm, got, exp);
        end
    end endtask

    //================================================================
    // 自动检查主块
    //================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt_err   = 0;
            sp_err    = 0;
            valid_cnt <= 0;
            act_cnt   <= 32'd0;
            c_bg      <= 32'd0;  c_navy  <= 32'd0;
            c_panel   <= 32'd0;  c_dark  <= 32'd0;
            c_alred   <= 32'd0;  c_gold  <= 32'd0;
            c_white   <= 32'd0;  c_orng  <= 32'd0;
            c_bara    <= 32'd0;  c_barb  <= 32'd0;
            vs_o_d    <= 1'b1;
            d_st_ink  <= 32'd0;  d_st_white <= 32'd0;
            d_w_ink   <= 32'd0;  d_w_gold   <= 32'd0;
            d_o_ink   <= 32'd0;  d_o_gold   <= 32'd0;
            d_s_ink   <= 32'd0;  d_s_gold   <= 32'd0;
        end
        else begin
            vs_o_d <= vs_o;

            // ---- 有效像素: 逐像素分类计数 + 采样点 ----
            if (de_o) begin
                act_cnt <= act_cnt + 32'd1;
                case (data_o)
                    BG      : c_bg    <= c_bg    + 32'd1;
                    C_NAVY  : c_navy  <= c_navy  + 32'd1;
                    C_PANEL : c_panel <= c_panel + 32'd1;
                    C_DARK  : c_dark  <= c_dark  + 32'd1;
                    C_ALRED : c_alred <= c_alred + 32'd1;
                    C_GOLD  : c_gold  <= c_gold  + 32'd1;
                    C_WHITE : c_white <= c_white + 32'd1;
                    C_ORNG  : c_orng  <= c_orng  + 32'd1;
                    C_BARA  : c_bara  <= c_bara  + 32'd1;
                    C_BARB  : c_barb  <= c_barb  + 32'd1;
                    default : begin
                        cnt_err = cnt_err + 1;
                        $display("t=%0t [FAIL] 未知色 %h @(%0d,%0d)",
                                 $time, data_o, u_scene.px3, u_scene.py3);
                    end
                endcase
                check_spots();

                // ---- 诊断: 抢答各字形窗墨点/着色 ----
                if ((u_scene.py3 >= 12'd96) && (u_scene.py3 < 12'd128)) begin
                    if ((u_scene.px3 >= 12'd256) && (u_scene.px3 < 12'd384)) begin
                        if (data_o != C_PANEL) d_st_ink   <= d_st_ink   + 32'd1;
                        if (data_o == C_WHITE) d_st_white <= d_st_white + 32'd1;
                    end
                    if ((u_scene.px3 >= 12'd256) && (u_scene.px3 < 12'd288)) begin
                        if (data_o != C_PANEL) d_w_ink  <= d_w_ink  + 32'd1;
                        if (data_o == C_GOLD)  d_w_gold <= d_w_gold + 32'd1;
                    end
                end
                if ((u_scene.py3 >= 12'd180) && (u_scene.py3 < 12'd212)) begin
                    if ((u_scene.px3 >= 12'd304) && (u_scene.px3 < 12'd336)) begin
                        if (data_o != C_PANEL) d_o_ink  <= d_o_ink  + 32'd1;
                        if (data_o == C_GOLD)  d_o_gold <= d_o_gold + 32'd1;
                    end
                    if ((u_scene.px3 >= 12'd336) && (u_scene.px3 < 12'd368)) begin
                        if (data_o != C_PANEL) d_s_ink  <= d_s_ink  + 32'd1;
                        if (data_o == C_GOLD)  d_s_gold <= d_s_gold + 32'd1;
                    end
                end
            end

            // ---- 帧边界(vs_o 下降沿): 结算刚结束的窗口 ----
            //   ★ 此刻 u_scene.phase 仍等于"刚结束这一帧所用的相位"
            //     (phase 在 vs_i 上升沿更新, 而 vs_o 下降沿比它早)。
            if (vs_o_d && ~vs_o) begin
                if (act_cnt == 0) begin
                    $display("t=%0t [NOTE] 窗口#%0d为空, 跳过", $time, valid_cnt);
                end
                else begin
                    if (act_cnt != TOT_PIX) begin
                        cnt_err = cnt_err + 1;
                        $display("t=%0t [FAIL] 帧%0d 有效像素=%0d 期望=%0d",
                                 $time, valid_cnt, act_cnt, TOT_PIX);
                    end
                    case (valid_cnt)
                        0: begin   // 段0: 两使能全 0 → 纯透传
                            chk_cnt("旁路BG",  c_bg, TOT_PIX);
                            chk_cnt("旁路NAVY",c_navy, 0);
                            chk_cnt("旁路PANEL",c_panel,0);
                            chk_cnt("旁路DARK",c_dark, 0);
                            chk_cnt("旁路GOLD",c_gold, 0);
                            chk_cnt("旁路WHITE",c_white,0);
                            chk_cnt("旁路ORNG", c_orng, 0);
                            chk_cnt("旁路BARA", c_bara, 0);
                            chk_cnt("旁路BARB", c_barb, 0);
                            chk_cnt("旁路ALRED",c_alred,0);
                            $display("t=%0t [段0] 帧%0d 纯透传 有效=%0d BG=%0d",
                                     $time, valid_cnt, act_cnt, c_bg);
                        end
                        1: begin   // 段1: 抢答 qstate=0 等待开始(不叠任何字)
                            ex_qz_white = 0;
                            ex_qz_dig   = 0;   // 待开始不显示倒计时
                            ex_qz_panel = 0;
                            ex_qz_orng  = 0;
                            ex_qz_dark  = 0;
                            ex_qz_bg    = TOT_PIX;   // 无倒计时 → 全透传
                            chk_cnt("抢答0BG",   c_bg,    ex_qz_bg);
                            chk_cnt("抢答0NAVY", c_navy,  ex_qz_navy);
                            chk_cnt("抢答0GOLD", c_gold,  ex_qz_gold + ex_qz_dig);
                            chk_cnt("抢答0WHITE",c_white, ex_qz_white);
                            chk_cnt("抢答0PANEL",c_panel, ex_qz_panel);
                            chk_cnt("抢答0ORNG", c_orng,  ex_qz_orng);
                            chk_cnt("抢答0DARK", c_dark,  ex_qz_dark);
                            chk_cnt("抢答0ALRED",c_alred, 0);
                            chk_cnt("抢答0BARA", c_bara,  0);
                            chk_cnt("抢答0BARB", c_barb,  0);
                            $display("t=%0t [段1] 帧%0d 抢答(等待开始) phase=%0d BG=%0d WHITE=%0d GOLD=%0d PANEL=%0d ORNG=%0d",
                                     $time, valid_cnt, u_scene.phase, c_bg, c_white, c_gold,
                                     c_panel, c_orng);
                        end
                        2: begin   // 段2: 抢答 qstate=1 抢答中(只叠倒计时)
                            ex_qz_white = 0;   // 状态字已取消
                            ex_qz_dig   = q_dig_run;
                            ex_qz_panel = 0;
                            ex_qz_orng  = 0;
                            ex_qz_dark  = 0;
                            // 倒计时数字是金色墨点, 从透传背景里扣除
                            ex_qz_bg    = TOT_PIX - ex_qz_dig;
                            chk_cnt("抢答1BG",   c_bg,    ex_qz_bg);
                            chk_cnt("抢答1NAVY", c_navy,  ex_qz_navy);
                            chk_cnt("抢答1GOLD", c_gold,  ex_qz_gold + ex_qz_dig);
                            chk_cnt("抢答1WHITE",c_white, ex_qz_white);
                            chk_cnt("抢答1PANEL",c_panel, ex_qz_panel);
                            chk_cnt("抢答1ORNG", c_orng,  ex_qz_orng);
                            chk_cnt("抢答1DARK", c_dark,  ex_qz_dark);
                            $display("t=%0t [段2] 帧%0d 抢答(抢答中) BG=%0d WHITE=%0d GOLD=%0d PANEL=%0d",
                                     $time, valid_cnt, c_bg, c_white, c_gold, c_panel);
                        end
                        3: begin   // 段3: 抢答 qstate=2 已锁定(队伍图, 全透传)
                            ex_qz_white = 0;   // 队伍图自带队名, OSD 不叠
                            ex_qz_dig   = 0;   // 锁定后不显示倒计时
                            ex_qz_panel = 0;
                            ex_qz_orng  = 0;
                            ex_qz_dark  = 0;
                            ex_qz_bg    = TOT_PIX;   // 无倒计时 → 全透传
                            chk_cnt("抢答2BG",   c_bg,    ex_qz_bg);
                            chk_cnt("抢答2NAVY", c_navy,  ex_qz_navy);
                            chk_cnt("抢答2GOLD", c_gold,  ex_qz_gold + ex_qz_dig);
                            chk_cnt("抢答2WHITE",c_white, ex_qz_white);
                            chk_cnt("抢答2PANEL",c_panel, ex_qz_panel);
                            chk_cnt("抢答2ORNG", c_orng,  ex_qz_orng);
                            chk_cnt("抢答2DARK", c_dark,  ex_qz_dark);
                            $display("t=%0t [段3] 帧%0d 抢答(已锁定) BG=%0d WHITE=%0d GOLD=%0d PANEL=%0d",
                                     $time, valid_cnt, c_bg, c_white, c_gold, c_panel);
                        end
                        4: begin   // 段4: 抢答 qstate=3 时间到(全透传)
                            ex_qz_white = 0;
                            ex_qz_dig   = 0;
                            ex_qz_panel = 0;
                            ex_qz_orng  = 0;
                            ex_qz_dark  = 0;
                            ex_qz_bg    = TOT_PIX;   // 无倒计时 → 全透传
                            chk_cnt("抢答3BG",   c_bg,    ex_qz_bg);
                            chk_cnt("抢答3NAVY", c_navy,  ex_qz_navy);
                            chk_cnt("抢答3GOLD", c_gold,  ex_qz_gold);
                            chk_cnt("抢答3WHITE",c_white, ex_qz_white);
                            chk_cnt("抢答3PANEL",c_panel, ex_qz_panel);
                            chk_cnt("抢答3ORNG", c_orng,  ex_qz_orng);
                            chk_cnt("抢答3DARK", c_dark,  ex_qz_dark);
                            $display("t=%0t [段4] 帧%0d 抢答(时间到) BG=%0d WHITE=%0d PANEL=%0d",
                                     $time, valid_cnt, c_bg, c_white, c_panel);
                        end
                        5, 6: begin // 段5/6: 应急(两帧; 红条闪烁相位与本断言无关)
                            exp_af      = foot_sum_af(u_scene.phase);
                            ex_al_dark  = FOOT_AREA - exp_af;
                            chk_cnt("应急BG",   c_bg,    ex_al_bg);
                            chk_cnt("应急WHITE",c_white, ex_al_white);
                            chk_cnt("应急ALRED",c_alred, ex_al_alred);
                            chk_cnt("应急DARK", c_dark,  ex_al_dark);
                            chk_cnt("应急ORNG", c_orng,  0);
                            chk_cnt("应急NAVY", c_navy,  0);
                            chk_cnt("应急PANEL",c_panel, 0);
                            // 红条区(亮相+暗相+三角金)=33280; 三角墨点 = 金 - 底带金
                            if ((c_bara + c_barb + c_gold) !== (AL_AREA_BAR + exp_af)) begin
                                cnt_err = cnt_err + 1;
                                $display("t=%0t [FAIL] 应急红条区 %0d(亮相%d+暗相%d+金%d-底带金%d) 期望=%0d",
                                         $time, c_bara + c_barb + c_gold,
                                         c_bara, c_barb, c_gold, exp_af,
                                         AL_AREA_BAR + exp_af);
                            end
                            if (c_gold <= exp_af) begin
                                cnt_err = cnt_err + 1;
                                $display("t=%0t [FAIL] 警示三角未绘制(gold=%0d 底带金=%0d)",
                                         $time, c_gold, exp_af);
                            end
                            $display("t=%0t [段5] 帧%0d 应急 phase=%0d BG=%0d 亮相=%0d 暗相=%0d GOLD(三角+底带)=%0d WHITE=%0d ALRED=%0d DARK=%0d",
                                     $time, valid_cnt, u_scene.phase, c_bg, c_bara, c_barb, c_gold,
                                     c_white, c_alred, c_dark);
                        end
                        7: begin   // 段7: 两使能全 0 → 复透传
                            chk_cnt("复旁路BG",   c_bg, TOT_PIX);
                            chk_cnt("复旁路GOLD", c_gold, 0);
                            chk_cnt("复旁路WHITE",c_white,0);
                            chk_cnt("复旁路ALRED",c_alred,0);
                            chk_cnt("复旁路DARK", c_dark, 0);
                            $display("t=%0t [段7] 帧%0d 复透传 有效=%0d BG=%0d",
                                     $time, valid_cnt, act_cnt, c_bg);
                        end
                        default: ;
                    endcase
                    valid_cnt <= valid_cnt + 1;   // 仅非空窗口计数(空窗为复位/管线过渡)
                end
                act_cnt   <= 32'd0;
                c_bg      <= 32'd0;  c_navy  <= 32'd0;
                c_panel   <= 32'd0;  c_dark  <= 32'd0;
                c_alred   <= 32'd0;  c_gold  <= 32'd0;
                c_white   <= 32'd0;  c_orng  <= 32'd0;
                c_bara    <= 32'd0;  c_barb  <= 32'd0;
            end
        end
    end

    //================================================================
    // 主流程(按窗口切换场景使能)
    //================================================================
    initial begin
        @(negedge rst);
        calc_expect();                       // ROM 已初始化完毕, 统计期望值

        wait (valid_cnt == 1);               // 窗口0(纯透传)结束 → 进抢答(等待开始)
        quiz_en = 1'b1;
        qstate  = 2'd0;
        t_tens  = 4'd0;
        t_ones  = 4'd5;

        wait (valid_cnt == 2);               // 抢答中
        qstate  = 2'd1;

        wait (valid_cnt == 3);               // 已锁定(3 号)
        qstate  = 2'd2;
        winner  = 2'd2;

        wait (valid_cnt == 4);               // 时间到
        qstate  = 2'd3;

        wait (valid_cnt == 5);               // 进应急
        quiz_en  = 1'b0;
        alarm_en = 1'b1;

        wait (valid_cnt == 7);               // 退出应急 → 复透传
        alarm_en = 1'b0;

        wait (valid_cnt == 8);               // 复透传帧结束
        #1000;
        if (cnt_err == 0 && sp_err == 0)
            $display("=== osd_scene 仿真结束: 全部通过(结算 %0d 帧) ===", valid_cnt);
        else
            $display("=== osd_scene 仿真结束: 计数失败=%0d 采样失败=%0d ===",
                     cnt_err, sp_err);
        $finish;
    end

    // 超时兜底(约 16.8ms/帧; 8 有效帧 + 空窗 < 400ms)
    initial begin
        #400000000 $finish;
    end

endmodule
