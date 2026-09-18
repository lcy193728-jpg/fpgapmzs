//====================================================================
// 模块名 : tb_display_adjust.v —— 显示末级调节引擎像素级回归
// 验证   : display_adjust(亮度增益 + 淡入淡出 + 三块 HUD 提示)
// 场景   : 为提速采用 640×56 缩短画布(三块 HUD 区 y4..11 / y16..23 /
//          y28..51 全部可见), 恒定灰 P=0x808080 输入。每一帧在 vs 上升沿
//          后实时采样内部 lvl_s/alpha, 由与 RTL 相同公式的函数导出期望
//          整帧色, 逐帧整帧逐色核对(亮度算术/淡入逐帧/HUD 几何/应急抑制
//          全被覆盖):
//   帧#0      稳态(menu=1 lvl=8) 全帧 0x808080(8档=直通), 无 HUD
//   帧#1..#10 场景切换淡出→淡入(menu 1→0): alpha 时序 =
//             255,255,191,127,63,0,0,64,128,192,255(FIDLE 消费事件那帧
//             仍全亮; FOUT 降 64/帧; FBLCK(busy=0 即放行); FIN 升 64/帧)
//   帧#11..#12 应急抑制淡出(menu 0→1 同时 emerg=1): 应急帧事件被清
//             帧全亮; emerg 撤除后也不再淡出
//   帧#13..#14 亮度条(lvl 8→12): 档变在帧边界武装 BAR_HOLD=3, 武装后首帧
//             vs 边沿即扣 1 → 实际连显 2 帧; 帧#15/#16 隐藏整帧 0xA0A0A0
//   帧#17..#18 降档(lvl 12→8)再弹条(生效档=8 格), 帧#19/#20 隐藏 0x808080
//   帧#21..#22 缩放档 4→6 → 弹"缩放条"(青, 生效 7 格); #23/#24 隐藏
//   帧#25..#26 KEY4 切手动 → 弹"状态卡"(橙框+暂停双条); #27/#28 隐藏
//   帧#29..#30 切到缩放模式(档位仍 6)→ 仍弹缩放条; #31/#32 隐藏
//   帧#33..#34 切到亮度模式 → 弹亮度条(8 档); #35/#36 隐藏
//   帧#37..#38 切回图片模式 → 弹状态卡(自动, 绿框+▶); #39..#41 隐藏
// 注 : 主流程 wait(valid_cnt==N) 触发时, 帧#0..#N-1 已结算完, 因此该
//      改动**从帧#N 起生效**(条/卡在 #N、#N+1 两帧可见, HOLD=3 首帧即扣)
// 结算方式 : 与 osd TB 同法(vs 下降沿结算窗口), 复位空窗跳过。
// 几何(display_adjust.v):
//   亮度条: 盒 x8..144×y4..11=137×8; 描边 2*(137+8)-4=286
//           内区 x9..143×y5..10=135×6=810; 生效内宽=L*9
//           L=12→108列(FG=648,空=162); L=8→72列(FG=432,空=378)
//   缩放条: 盒 x8..81×y16..23=74×8;  描边 2*(74+8)-4=160
//           内区 x9..80×y17..22=72×6=432; 生效格数=档+1
//           档4=45列(FG=270,空=162); 档6=63列(FG=378,空=54)
//   状态卡: 盒 x8..47×y28..51=40×24; 描边 2*(40+24)-4=124
//           内区 38×22=836; 自动=绿框+▶(14行三角, 面积56)
//              → AUTO=124+56=180, 内衬=780
//           手动=橙框+▮▮(2条×4列×12行=96)
//              → MAN=124+96=220, 内衬=740
// 输入灰 P: lvl8→gain128→0x808080; lvl12→gain160→0xA0A0A0
//====================================================================

`timescale 1ns/1ps
module tb_display_adjust;

    // ---- 缩短画布(高度须覆盖状态卡 y28..51) ----
    localparam H_ACT   = 640;
    localparam H_FP    = 8;
    localparam H_SYNC  = 32;
    localparam H_BP    = 16;
    localparam H_TOT   = H_ACT + H_FP + H_SYNC + H_BP;   // 696
    localparam V_ROWS  = 56;
    localparam V_FP    = 2;
    localparam V_SYNC  = 2;
    localparam V_BP    = 2;
    localparam V_TOT   = V_ROWS + V_FP + V_SYNC + V_BP;  // 62
    localparam H_START = H_FP + H_SYNC + H_BP;           // 56
    localparam V_START = V_FP + V_SYNC + V_BP;           // 6
    localparam CLK     = 40;

    // ---- 颜色常量 ----
    localparam PIX     = 24'h808080;   // 恒定输入灰
    localparam C_BD    = 24'hE4F0FF;   // HUD 边框(亮度条/缩放条)
    localparam C_FG    = 24'hFFC93C;   // 亮度生效档位金
    localparam C_BGS   = 24'h101418;   // 未生效档位深
    localparam C_RESF  = 24'h22D3EE;   // 缩放已生效档位青
    localparam C_CARD  = 24'h0A1018;   // 状态卡内衬
    localparam C_AUTO  = 24'h22C55E;   // 自动轮播: 绿框+播放三角
    localparam C_MAN   = 24'hFFA028;   // 手动单张: 橙框+暂停双条

    localparam AREA    = H_ACT * V_ROWS;   // 35840
    // 亮度条
    localparam EX_BD   = 286;
    localparam EX_FG12 = 648;
    localparam EX_BG12 = 162;
    localparam EX_FG8  = 432;
    localparam EX_BG8  = 378;
    // 缩放条
    localparam EX_RBD  = 160;
    localparam EX_RFG4 = 270;   // 档4: (4+1)*9=45 列 ×6 行
    localparam EX_RBG4 = 162;   // 432-270
    localparam EX_RFG6 = 378;   // 档6: (6+1)*9=63 列 ×6 行
    localparam EX_RBG6 = 54;    // 432-378
    // 状态卡
    localparam EX_CBD  = 124;   // 卡描边
    localparam EX_AUTO = 180;   // 124 + 三角 56
    localparam EX_CBGA = 780;   // 836 - 56
    localparam EX_MAN  = 220;   // 124 + 双条 96
    localparam EX_CBGM = 740;   // 836 - 96

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
    reg  [3:0]  res_level;               // 缩放档 0..7(默认 4=100%)
    reg         pic_manual;              // 1=手动单张 / 0=自动轮播
    reg  [1:0]  ui_mode;                 // 功能模式 0图片/1亮度/2缩放
    wire        hs_o, vs_o, de_o;
    wire [23:0] data_o;

    integer     err_cnt;
    integer     chk_frame;
    integer     valid_cnt;
    reg  [31:0] act_cnt;
    reg  [31:0] c_uni;
    reg  [31:0] c_bd, c_fg, c_bgs;
    reg  [31:0] c_res, c_card, c_auto, c_man;   // 新增 HUD 逐色计数
    reg         vs_o_d;
    reg  [23:0] exp_uni;                 // 当前帧非条像素期望色(实时推导)

    //--------------- 与 RTL 同式的期望色函数 ----------------
    function [7:0] chan8; input integer v; begin
        chan8 = (v > 255) ? 8'd255 : v[7:0];
    end endfunction

    function [23:0] exp_pix; input [3:0] lv; input [7:0] al;
        integer g, br;
        begin
            g  = 64 + lv * 8;                 // 增益(与 RTL: 64+L*8)
            br = (128 * g + 64) / 128;        // 亮度: (P*g+64)>>7
            if (br > 255) br = 255;
            if (al == 8'd255)
                exp_pix = {chan8(br), chan8(br), chan8(br)};
            else begin
                br = (br * al + 128) / 256;   // 淡入: (b*alpha+128)>>8
                exp_pix = {chan8(br), chan8(br), chan8(br)};
            end
        end
    endfunction

    // alpha 时序表(帧号→期望 alpha): 淡出 255→191/127/63/0(FIN 等忙释放),
    // 淡入 0→64/128/192(FIN 每帧 +64, 与 RTL 一致): 帧#2=191,3=127,4=63,
    // 5=0,6=0,7=64,8=128,9=192; 其余帧 255
    function [7:0] alpha_sched; input integer f; begin
        case (f)
            2: alpha_sched = 8'd191;
            3: alpha_sched = 8'd127;
            4: alpha_sched = 8'd63;
            5: alpha_sched = 8'd0;
            6: alpha_sched = 8'd0;
            7: alpha_sched = 8'd64;
            8: alpha_sched = 8'd128;
            9: alpha_sched = 8'd192;
            default: alpha_sched = 8'd255;
        endcase
    end endfunction

    //--------------- 例化被测模块 ----------------
    display_adjust #(
        .DATA_W         (24),
        .H_ACT          (H_ACT),
        .V_ACT          (V_ROWS),
        .BAR_HOLD_FRAMES(16'd3),         // 缩短条保持帧数, 提速回归
        .RES_HOLD_FRAMES(16'd3),
        .MAN_HOLD_FRAMES(16'd3)
    ) u_disp (
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
        .bri_level  (bri_level),
        .res_level  (res_level),
        .pic_manual (pic_manual),
        .ui_mode    (ui_mode),
        .hs_o       (hs_o),
        .vs_o       (vs_o),
        .de_o       (de_o),
        .data_o     (data_o)
    );

    //--------------- 时钟 / 复位 ----------------
    initial clk = 1'b0;
    always #(CLK/2) clk = ~clk;

    initial begin
        rst = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
    end

    //--------------- 控制初值(与系统上电默认一致) ----------------
    initial begin
        menu_active = 1'b1;
        emerg       = 1'b0;
        bmp_busy    = 1'b0;
        bri_level   = 4'd8;
        res_level   = 4'd4;      // 100%
        pic_manual  = 1'b0;      // 自动轮播
        ui_mode     = 2'd0;      // 图片模式
    end

    //--------------- 视频时序发生器(640×56 短画布) ----------------
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
    assign data_i = de_r ? PIX : 24'h000000;
    assign px_i   = de_r ? (h_cnt - H_START) : 12'd0;
    assign py_i   = de_r ? (v_cnt - V_START) : 12'd0;

    //--------------- 检查任务 ----------------
    // 整帧色模式: 所有像素 = exp_uni, 三块 HUD 均不得出现
    task chk_uni_frame; input [31:0] frm; begin
        if (act_cnt != AREA || c_uni != AREA ||
            c_bd != 0 || c_fg != 0 || c_bgs != 0 ||
            c_res != 0 || c_card != 0 || c_auto != 0 || c_man != 0) begin
            err_cnt = err_cnt + 1;
            $display("t=%0t [FAIL] 帧#%0d 期望整帧%h 有效=%0d 该色=%0d 条(%0d/%0d/%0d) HUD(%0d/%0d/%0d/%0d)",
                     $time, frm, exp_uni, act_cnt, c_uni, c_bd, c_fg, c_bgs,
                     c_res, c_card, c_auto, c_man);
        end
        $display("t=%0t [%s] 帧#%0d 整帧色=%h (有效=%0d)",
                 $time, ((act_cnt==AREA) && (c_uni==AREA) &&
                         (c_bd==0)&&(c_fg==0)&&(c_bgs==0) &&
                         (c_res==0)&&(c_card==0)&&(c_auto==0)&&(c_man==0)) ? "PASS" : "FAIL",
                 frm, exp_uni, act_cnt);
    end endtask

    // 亮度条模式: 边框286 + 生效fg + 未生效bgs + 其余(应为 exp_uni)
    task chk_bar_frame; input [31:0] frm; input [31:0] fg; input [31:0] bgs; begin
        if (act_cnt != AREA || c_bd != EX_BD || c_fg != fg || c_bgs != bgs ||
            c_uni != AREA - EX_BD - fg - bgs ||
            c_res != 0 || c_card != 0 || c_auto != 0 || c_man != 0) begin
            err_cnt = err_cnt + 1;
            $display("t=%0t [FAIL] 帧#%0d 条 有效=%0d 边框=%0d 生效=%0d 空=%0d 亮=%0d HUD(%0d/%0d/%0d/%0d)",
                     $time, frm, act_cnt, c_bd, c_fg, c_bgs, c_uni,
                     c_res, c_card, c_auto, c_man);
        end
        $display("t=%0t [%s] 帧#%0d 亮度条段 (边框=%0d 生效=%0d 空=%0d 亮=%0d)",
                 $time, ((act_cnt==AREA) && (c_bd==EX_BD) && (c_fg==fg) &&
                         (c_bgs==bgs) && (c_uni==AREA-EX_BD-fg-bgs) &&
                         (c_res==0)&&(c_card==0)&&(c_auto==0)&&(c_man==0))
                        ? "PASS" : "FAIL",
                 frm, c_bd, c_fg, c_bgs, c_uni);
    end endtask

    // 缩放条模式: 亮度条金色必须全 0; 边框与空槽与亮度条共用色
    //   (c_bd=C_BAR_BD 边框 / c_bgs=C_BAR_BG 空槽 / c_res=C_RES_FG 青色生效格)
    task chk_res_frame; input [31:0] frm; input [31:0] rfg; input [31:0] rbg; begin
        if (act_cnt != AREA || c_bd != EX_RBD || c_fg != 0 || c_bgs != rbg ||
            c_res != rfg || c_uni != AREA - EX_RBD - rfg - rbg ||
            c_card != 0 || c_auto != 0 || c_man != 0) begin
            err_cnt = err_cnt + 1;
            $display("t=%0t [FAIL] 帧#%0d 缩放条 有效=%0d 边框=%0d 青=%0d 空=%0d 亮=%0d 卡(%0d/%0d/%0d)",
                     $time, frm, act_cnt, c_bd, c_res, c_bgs, c_uni,
                     c_card, c_auto, c_man);
        end
        $display("t=%0t [%s] 帧#%0d 缩放条段 (边框=%0d 青=%0d 空=%0d 亮=%0d)",
                 $time, ((act_cnt==AREA) && (c_bd==EX_RBD) && (c_res==rfg) &&
                         (c_bgs==rbg) && (c_uni==AREA-EX_RBD-rfg-rbg) &&
                         (c_fg==0)&&(c_card==0)&&(c_auto==0)&&(c_man==0))
                        ? "PASS" : "FAIL",
                 frm, c_bd, c_res, c_bgs, c_uni);
    end endtask

    // 状态卡模式: auto=1 → 绿框+▶; auto=0 → 橙框+双竖条
    task chk_card_frame; input [31:0] frm; input auto_mode; begin
        begin
            if (auto_mode) begin
                if (act_cnt != AREA || c_auto != EX_AUTO || c_card != EX_CBGA ||
                    c_uni != AREA - EX_AUTO - EX_CBGA ||
                    c_bd != 0 || c_fg != 0 || c_bgs != 0 || c_res != 0 || c_man != 0) begin
                    err_cnt = err_cnt + 1;
                    $display("t=%0t [FAIL] 帧#%0d 状态卡(自动) 有效=%0d 绿=%0d 衬=%0d 亮=%0d",
                             $time, frm, act_cnt, c_auto, c_card, c_uni);
                end
                $display("t=%0t [%s] 帧#%0d 状态卡(自动轮播) 绿框+▶=%0d 衬底=%0d 亮=%0d",
                         $time, ((act_cnt==AREA) && (c_auto==EX_AUTO) &&
                                 (c_card==EX_CBGA) && (c_uni==AREA-EX_AUTO-EX_CBGA) &&
                                 (c_bd==0)&&(c_fg==0)&&(c_bgs==0)&&(c_res==0)&&(c_man==0))
                                ? "PASS" : "FAIL",
                         frm, c_auto, c_card, c_uni);
            end
            else begin
                if (act_cnt != AREA || c_man != EX_MAN || c_card != EX_CBGM ||
                    c_uni != AREA - EX_MAN - EX_CBGM ||
                    c_bd != 0 || c_fg != 0 || c_bgs != 0 || c_res != 0 || c_auto != 0) begin
                    err_cnt = err_cnt + 1;
                    $display("t=%0t [FAIL] 帧#%0d 状态卡(手动) 有效=%0d 橙=%0d 衬=%0d 亮=%0d",
                             $time, frm, act_cnt, c_man, c_card, c_uni);
                end
                $display("t=%0t [%s] 帧#%0d 状态卡(手动单张) 橙框+▮▮=%0d 衬底=%0d 亮=%0d",
                         $time, ((act_cnt==AREA) && (c_man==EX_MAN) &&
                                 (c_card==EX_CBGM) && (c_uni==AREA-EX_MAN-EX_CBGM) &&
                                 (c_bd==0)&&(c_fg==0)&&(c_bgs==0)&&(c_res==0)&&(c_auto==0))
                                ? "PASS" : "FAIL",
                         frm, c_man, c_card, c_uni);
            end
        end
    end endtask

    //--------------- 自动检查 ----------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            err_cnt   <= 0;
            chk_frame <= 0;
            valid_cnt <= 0;
            act_cnt   <= 32'd0;
            c_uni     <= 32'd0;
            c_bd      <= 32'd0; c_fg <= 32'd0; c_bgs <= 32'd0;
            c_res     <= 32'd0; c_card <= 32'd0;
            c_auto    <= 32'd0; c_man <= 32'd0;
            vs_o_d    <= 1'b1;
            exp_uni   <= 24'h808080;
        end
        else begin
            // vs 上升沿(新帧起点, 模块 FSM 已按新 alpha 更新完) → 推导本帧期望色
            if (~vs_o_d && vs_o)
                exp_uni <= exp_pix(u_disp.lvl_s, u_disp.alpha);
            vs_o_d <= vs_o;

            // ---- 有效像素内: 分类计数 ----
            if (de_o) begin
                act_cnt <= act_cnt + 32'd1;
                case (data_o)
                    C_BD : c_bd  <= c_bd  + 32'd1;
                    C_FG : c_fg  <= c_fg  + 32'd1;
                    C_BGS: c_bgs <= c_bgs + 32'd1;
                    C_RESF: c_res <= c_res + 32'd1;
                    C_CARD: c_card <= c_card + 32'd1;
                    C_AUTO: c_auto <= c_auto + 32'd1;
                    C_MAN : c_man  <= c_man  + 32'd1;
                    default: begin
                        if (data_o !== exp_uni) begin
                            err_cnt <= err_cnt + 1;
                            $display("t=%0t [FAIL] 期望色%h 收到%h @(%0d,%0d)",
                                     $time, exp_uni, data_o, u_disp.px1, u_disp.py1);
                        end
                        c_uni <= c_uni + 32'd1;
                    end
                endcase
            end

            // ---- 帧边界结算(vs_o 下降沿; 此刻 u_disp.alpha 仍是本帧值) ----
            if (vs_o_d && ~vs_o) begin
                if (act_cnt == 0) begin
                    $display("t=%0t [NOTE] 窗口#%0d为空, 跳过", $time, chk_frame);
                end
                else begin
                    // alpha 时序核对(防事件早/晚一帧等时序错位)
                    if (u_disp.alpha !== alpha_sched(valid_cnt)) begin
                        err_cnt <= err_cnt + 1;
                        $display("t=%0t [FAIL] 帧#%0d alpha=%0d 期望=%0d",
                                 $time, valid_cnt, u_disp.alpha,
                                 alpha_sched(valid_cnt));
                    end
                    case (valid_cnt)   // 结算时=已完成帧数=当前帧号
                        0, 1: chk_uni_frame(valid_cnt);
                        2:   chk_uni_frame(2);
                        3:   chk_uni_frame(3);
                        4:   chk_uni_frame(4);
                        5:   chk_uni_frame(5);
                        6:   chk_uni_frame(6);
                        7:   chk_uni_frame(7);
                        8:   chk_uni_frame(8);
                        9:   chk_uni_frame(9);
                        10, 11, 12: chk_uni_frame(valid_cnt);
                        // 档位变化在帧边界武装条 → 帧#13/#14(12档) 与
                        // 帧#17/#18(8档) 各显示 2 帧, 其余为纯整帧色
                        13, 14: chk_bar_frame(valid_cnt, EX_FG12, EX_BG12);
                        15, 16: chk_uni_frame(valid_cnt);
                        17, 18: chk_bar_frame(valid_cnt, EX_FG8, EX_BG8);
                        19, 20: chk_uni_frame(valid_cnt);
                        // 帧#21/#22 缩放档 4→6 弹缩放条; #23/#24 隐藏
                        21, 22: chk_res_frame(valid_cnt, EX_RFG6, EX_RBG6);
                        23, 24: chk_uni_frame(valid_cnt);
                        // 帧#25/#26 KEY4 切手动 → 状态卡(橙); #27/#28 隐藏
                        25, 26: chk_card_frame(valid_cnt, 1'b0);
                        27, 28: chk_uni_frame(valid_cnt);
                        // 帧#29/#30 切到缩放模式(档位仍 6, 未变)→ 仍弹缩放条
                        //   (证明"切模式即弹当前档位"; 之后 #31/#32 隐藏)
                        29, 30: chk_res_frame(valid_cnt, EX_RFG6, EX_RBG6);
                        31, 32: chk_uni_frame(valid_cnt);
                        // 帧#33/#34 切到亮度模式 → 亮度条(8档); #35/#36 隐藏
                        33, 34: chk_bar_frame(valid_cnt, EX_FG8, EX_BG8);
                        35, 36: chk_uni_frame(valid_cnt);
                        // 帧#37/#38 切回图片模式 → 状态卡(自动/绿); #39..#41 隐藏
                        37, 38: chk_card_frame(valid_cnt, 1'b1);
                        39, 40, 41: chk_uni_frame(valid_cnt);
                        default: ;
                    endcase
                    valid_cnt <= valid_cnt + 1;
                end
                chk_frame <= chk_frame + 1;
                act_cnt   <= 32'd0;
                c_uni     <= 32'd0;
                c_bd      <= 32'd0; c_fg <= 32'd0; c_bgs <= 32'd0;
                c_res     <= 32'd0; c_card <= 32'd0;
                c_auto    <= 32'd0; c_man <= 32'd0;
            end
        end
    end

    //--------------- 主流程(帧边界驱动控制信号) ----------------
    initial begin
        @(negedge rst);
        // 帧#0 稳态; 帧#1 起淡出(事件在帧#0 期间锁存, 帧#1 边沿消费)
        wait (valid_cnt == 1);
        menu_active = 1'b0;            // 菜单→场景, 触发淡出淡入序列
        // 帧#1..#10 淡出→FBLCK→淡入 自动推进(busy=0 即放行)
        wait (valid_cnt == 11);
        menu_active = 1'b1;            // 场景→菜单, 但应急同时拉起
        emerg       = 1'b1;
        wait (valid_cnt == 12);        // 帧#11(应急帧)结束
        emerg = 1'b0;                   // 撤除应急: 事件已在应急帧被清, 不再淡出
        wait (valid_cnt == 13);        // 帧#12 结束 → 亮度升档
        bri_level = 4'd12;
        wait (valid_cnt == 16);        // 帧#15(第3条帧)结束
        wait (valid_cnt == 17);        // 帧#16(亮度12稳态)结束 → 降回 8 档(再弹条)
        bri_level = 4'd8;
        wait (valid_cnt == 21);        // 帧#0..#20 已结算 → 改动从帧#21 生效
        // ---- 缩放档变化 → 弹缩放条(帧#21/#22 可见) ----
        res_level = 4'd6;
        wait (valid_cnt == 25);        // 帧#21..#24 已结算(条已消失)
        // ---- KEY4 切手动单张 → 弹状态卡(橙, 帧#25/#26 可见) ----
        pic_manual = 1'b1;
        wait (valid_cnt == 29);        // 帧#25..#28 已结算
        // ---- 切到"缩放模式"但档位不变 → 仍弹缩放条(档 4, 帧#29/#30) ----
        ui_mode = 2'd2;                // MODE_RES
        wait (valid_cnt == 33);
        // ---- 切到"亮度模式" → 弹亮度条(档 8, 帧#33/#34) ----
        ui_mode = 2'd1;                // MODE_BRI
        wait (valid_cnt == 37);
        // ---- 切回"图片模式" → 弹状态卡(自动/绿, 帧#37/#38) ----
        ui_mode    = 2'd0;             // MODE_PIC
        pic_manual = 1'b0;             // 同时回自动轮播(状态卡应显示"自动")
        wait (valid_cnt == 42);        // 帧#39..#41 收尾(纯整帧色)
        #1000;
        if (err_cnt == 0)
            $display("=== display_adjust 仿真结束: 全部通过(校验 %0d 帧) ===",
                     valid_cnt);
        else
            $display("=== display_adjust 仿真结束: 失败数=%0d ===", err_cnt);
        $finish;
    end

    // 超时兜底(每帧≈1.73ms; 42 帧≈73ms, 余量充足)
    initial begin
        #500000000 $finish;
    end

endmodule
