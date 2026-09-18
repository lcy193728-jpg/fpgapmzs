//====================================================================
// 模块名 : tb_osd_menu.v —— 全屏矢量菜单 V2 像素级回归 (osd_menu)
// 场景   : 生成 VGA 640×480 时序(带 hs/vs 负脉冲与消隐), 直接驱动
//          osd_menu(数据与重建坐标同拍送入), 分四段验证:
//   段0 菜单关/应急关 : 全帧透传背景(纯旁路, 每像素应=BG)
//   段1/段2 菜单开    : 整帧自绘, 逐色统计与几何公式推得期望一致:
//          BG_FULL=116556 / C_CARD=140882 / C_BD=8480
//          / 四卡左色块各640 / 白字=8712 / 副标题浅蓝=2554
//          / 滚动亮橙=2986 / 金线=576 / 宣传语黑底=23894
//          / 应急红=0 / 背景透传=0 —— 两个连续菜单帧均核
//          并在第 2 菜单帧做 ~20 采样点核对(ON=应写字色, OFF=应写底色)
//   段3 应急开/菜单关 : 顶部 52 行红条(33280) + 其余背景透传
// 额外   : 滚动相位每帧 +1 校验(层次引用 u_menu.phase, 逐帧 0..319 步进)
// 结算方式 : 以 osd_menu 输出 vs 的下降沿结算窗口; 复位释放瞬间产生的
//          空窗口跳过; 之后每个窗口恰含一帧依次按 段0/1/2/3 结算。
// 期望数值均由 gen_osd_font.py 墨点统计 + 几何公式推出(见段内注释)。
//====================================================================

`timescale 1ns/1ps
module tb_osd_menu;

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

    //---- 颜色(与 osd_menu.v 各 localparam 一致) ----
    localparam BG       = 24'h204080;   // 输入背景(透传源)
    localparam C_RED    = 24'hFF2A2A;   // 应急红条
    localparam C_BGFULL = 24'h0A1220;   // 全屏深藏青底
    localparam C_ULINE  = 24'hFFD24A;   // 标题下金色线
    localparam C_CARD   = 24'h152742;   // 卡片内衬
    localparam C_BD     = 24'h2FA9E8;   // 卡片描边
    localparam C_ACC0   = 24'h2E7CF6;   // 卡1 左色块
    localparam C_ACC1   = 24'h18C99E;   // 卡2 左色块
    localparam C_ACC2   = 24'hF5A623;   // 卡3 左色块
    localparam C_ACC3   = 24'hE84A4A;   // 卡4 左色块
    localparam C_TXTW   = 24'hF5FDFF;   // 白字(标题/卡标题)
    localparam C_TAG    = 24'h9DCBF2;   // 副标题浅钢蓝
    localparam C_MARQ   = 24'hFF7A1F;   // 滚动宣传语亮橙
    localparam C_MQBG   = 24'h000000;   // 宣传语黑底

    //================================================================
    // 菜单帧期望逐色计数(几何公式推导, 见下方分组算式):
    //   ★V3.4 定版字库(思源黑体 / Noto Sans SC; 32×32 真字模 2× 带 + 16px 直渲 1× 带)
    //     对应的墨点(gen 打印):
    //     TITLE=2616(1:1)  CT0..3=1129/888/1122/1114  TG0..3=532/499/513/536
    //     MARQ=1295(带内一周期 = 320px)
    //   白色 = 2616 + 4 卡标题(1129+888+1122+1114=4253) = 6869
    //   副标题 = 532+499+513+536 = 2080;  滚动橙 = 1295×2(整行含两周期) = 2590
    //   金线 = 2行×288px(x176..463) = 576
    //   卡: 每卡 色块8×80=640 / 描边2120 / 内衬37240-卡字 / 卡外BG列2×5600
    //   宣传黑底 = 42行×640 − 2590 = 24290
    //   BG_FULL = (0..27行17920 + 标题行20480-2616 + 60..63行2560
    //     + 金线行1280-576 + 66..79行8960 + 卡外11200×4 + 卡间3×6400
    //     + 430..437行5120) = 117128
    //   卡片内衬 = 4×(40000-640-2120) − 4253 − 2080 = 142627
    //   校验和: 117128+142627+8480+2560+6869+2080+2590+576+24290 = 307200
    //================================================================
    localparam TOT_PIX   = H_ACT * V_ACT;              // 307200
    localparam EMERG_PIX = 52 * H_ACT;                 // 33280
    localparam EX_BGFULL = 117128;
    localparam EX_CARD   = 142627;
    localparam EX_BD     = 8480;
    localparam EX_ACC    = 640;
    localparam EX_TXTW   = 6869;
    localparam EX_TAG    = 2080;
    localparam EX_MARQ   = 2590;
    localparam EX_ULINE  = 576;
    localparam EX_MQBG   = 24290;

    //--------------- 信号 ----------------
    reg         clk;
    reg         rst;
    wire        hs_i, vs_i, de_i;
    wire [23:0] data_i;
    wire [11:0] px_i, py_i;
    reg         menu_en;
    reg         emerg_en;
    wire        hs_o, vs_o, de_o;
    wire [23:0] data_o;
    wire [11:0] px_x_o, px_y_o;

    // 结算/统计
    integer     err_cnt;
    integer     chk_frame;
    integer     valid_cnt;
    reg  [31:0] act_cnt;
    reg  [31:0] c_red, c_bgfull, c_card, c_bd;
    reg  [31:0] c_acc0, c_acc1, c_acc2, c_acc3;
    reg  [31:0] c_txtw, c_tag, c_marq, c_uline, c_mqbg, c_pass;
    reg         vs_o_d;                 // vs_o 延迟一拍(下降沿检测)
    reg  [9:0]  phase_save;             // 上一帧读取的滚动相位
    reg         phase_first;            // 尚未读过相位
    integer     phase_bad;              // 相位步进失败次数

    //--------------- 例化被测模块 ----------------
    // 共享字形 ROM(与 top.v 同构: 实体在 TB 顶层例化, 被 u_menu 读)
    wire        rom_en_m;
    wire [12:0] rom_addr_m;
    wire [31:0] rom_q;
    osd_font_rom #(.ADDR_W(13), .DEPTH(5856)) u_font_rom (
        .clk   (clk),
        .rst   (rst),
        .rd_en (rom_en_m),
        .addr  (rom_addr_m),
        .q     (rom_q)
    );

    osd_menu #(
        .DATA_W     (24),
        .H_ACT      (H_ACT),
        .V_ACT      (V_ACT),
        .EMERG_ROWS (52)
    ) u_menu (
        .video_clk (clk),
        .rst       (rst),
        .hs_i      (hs_i),
        .vs_i      (vs_i),
        .de_i      (de_i),
        .data_i    (data_i),
        .px_x      (px_i),
        .px_y      (py_i),
        .menu_en   (menu_en),
        .emerg_en  (emerg_en),
        .rom_en_o  (rom_en_m),
        .rom_addr_o(rom_addr_m),
        .rom_q     (rom_q),
        .hs_o      (hs_o),
        .vs_o      (vs_o),
        .de_o      (de_o),
        .data_o    (data_o),
        .px_x_o    (px_x_o),
        .px_y_o    (px_y_o)
    );

    // 坐标透传对齐: px_x_o/px_y_o 必须恒等于内部三级管线的 px3/py3
    wire px_mism = (px_x_o !== u_menu.px3) || (px_y_o !== u_menu.py3);

    //--------------- 时钟 / 复位 ----------------
    initial clk = 1'b0;
    always #(CLK/2) clk = ~clk;

    initial begin
        rst = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
    end

    //--------------- 控制使能: 复位后默认全关 ----------------
    initial begin
        menu_en  = 1'b0;
        emerg_en = 1'b0;
    end

    //--------------- 视频时序发生器(模拟 osd_engine 出口) ----------------
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
        hs_r = ~(h_cnt >= H_FP && h_cnt < H_FP + H_SYNC);   // 负脉冲
        vs_r = ~(v_cnt >= V_FP && v_cnt < V_FP + V_SYNC);   // 负脉冲
        de_r = (h_cnt >= H_START && h_cnt < H_TOT) &&
               (v_cnt >= V_START && v_cnt < V_TOT);
    end
    assign hs_i   = hs_r;
    assign vs_i   = vs_r;
    assign de_i   = de_r;
    assign data_i = de_r ? BG : 24'h000000;     // 与 de 同拍(已对齐)
    assign px_i   = de_r ? (h_cnt - H_START) : 12'd0;
    assign py_i   = de_r ? (v_cnt - V_START) : 12'd0;

    //================================================================
    // 采样点核对(第 2 菜单帧, 坐标与 gen_osd_font.py 打印一致)
    //  ON = 字形墨点 -> 应写字色;  OFF = 字形区空白 -> 应底色
    //  特征点 = 全屏底色/金线/卡色块/描边/内衬/黑底 各类区域取点
    //================================================================
    task chk; input [11:0] x; input [11:0] y; input [23:0] expc;
             input [255:0] tag; begin
        if (u_menu.px3 == x && u_menu.py3 == y) begin
            if (data_o !== expc) begin
                err_cnt = err_cnt + 1;
                $display("t=%0t [FAIL] %0s@(%0d,%0d) got=%h exp=%h",
                         $time, tag, x, y, data_o, expc);
            end
            else
                $display("t=%0t [PASS] %0s@(%0d,%0d)=%h", $time, tag, x, y, data_o);
        end
    end endtask

    task check_spots; begin
        if (valid_cnt == 2) begin
            // ---- 文字带采样点(V3.4 思源黑体字库, gen 打印) ----
            chk(182, 29, C_TXTW, "TITLE ON");
            chk(176, 28, C_BGFULL,"TITLE OFF");
            chk(115, 93, C_TXTW, "CT0 ON");
            chk( 98, 92, C_CARD, "CT0 OFF");
            chk(114,183, C_TXTW, "CT1 ON");
            chk( 98,182, C_CARD, "CT1 OFF");
            chk(104,273, C_TXTW, "CT2 ON");
            chk( 98,272, C_CARD, "CT2 OFF");
            chk(113,363, C_TXTW, "CT3 ON");
            chk( 98,362, C_CARD, "CT3 OFF");
            chk(101,132, C_TAG,  "TG0 ON");
            chk( 98,132, C_CARD, "TG0 OFF");
            chk(117,222, C_TAG,  "TG1 ON");
            chk( 98,222, C_CARD, "TG1 OFF");
            chk(104,312, C_TAG,  "TG2 ON");
            chk( 98,312, C_CARD, "TG2 OFF");
            chk(106,402, C_TAG,  "TG3 ON");
            chk( 98,402, C_CARD, "TG3 OFF");
            // ---- 矢量几何特征点 ----
            chk(  5,  5, C_BGFULL,"BG 顶");
            chk(300, 64, C_ULINE, "金线");
            chk(100, 64, C_BGFULL,"金线左外");
            chk(500, 64, C_BGFULL,"金线右外");
            chk( 73, 80, C_ACC0,  "卡0色块顶");
            chk(320, 80, C_BD,    "卡0顶边");
            chk(320, 90, C_CARD,  "卡0内衬");
            chk( 73,159, C_ACC0,  "卡0色块底");
            chk(320,159, C_BD,    "卡0底边");
            chk(569, 90, C_BD,    "卡0右边");
            chk(570, 90, C_BGFULL,"卡0右外");
            chk( 69, 90, C_BGFULL,"卡0左外");
            chk(320,165, C_BGFULL,"卡间缝");
            chk( 73,180, C_ACC1,  "卡1色块");
            chk( 73,270, C_ACC2,  "卡2色块");
            chk( 73,360, C_ACC3,  "卡3色块");
            chk(300,439, C_MQBG,  "宣传黑底");
            chk(300,479, C_MQBG,  "宣传黑底底");
        end
    end endtask

    //--------------- 自动检查 ----------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            err_cnt    <= 0;
            chk_frame  <= 0;
            valid_cnt  <= 0;
            act_cnt    <= 32'd0;
            c_red      <= 32'd0;   c_bgfull <= 32'd0;
            c_card     <= 32'd0;   c_bd     <= 32'd0;
            c_acc0     <= 32'd0;   c_acc1   <= 32'd0;
            c_acc2     <= 32'd0;   c_acc3   <= 32'd0;
            c_txtw     <= 32'd0;   c_tag    <= 32'd0;
            c_marq     <= 32'd0;   c_uline  <= 32'd0;
            c_mqbg     <= 32'd0;   c_pass   <= 32'd0;
            vs_o_d     <= 1'b1;
            phase_save <= 10'd0;
            phase_first<= 1'b1;
            phase_bad  <= 0;
        end
        else begin
            vs_o_d <= vs_o;

            // ---- 坐标透传对齐检查(应恒成立) ----
            if (px_mism) begin
                err_cnt <= err_cnt + 1;
                $display("t=%0t [FAIL] px_o 与内部 px3/py3 失配 out=(%0d,%0d) in=(%0d,%0d)",
                         $time, px_x_o, px_y_o, u_menu.px3, u_menu.py3);
            end

            // ---- 有效像素内: 逐像素分类计数 ----
            if (de_o) begin
                act_cnt <= act_cnt + 32'd1;
                case (data_o)
                    C_RED   : c_red   <= c_red   + 32'd1;
                    C_BGFULL: c_bgfull<= c_bgfull+ 32'd1;
                    C_CARD  : c_card  <= c_card  + 32'd1;
                    C_BD    : c_bd    <= c_bd    + 32'd1;
                    C_ACC0  : c_acc0  <= c_acc0  + 32'd1;
                    C_ACC1  : c_acc1  <= c_acc1  + 32'd1;
                    C_ACC2  : c_acc2  <= c_acc2  + 32'd1;
                    C_ACC3  : c_acc3  <= c_acc3  + 32'd1;
                    C_TXTW  : c_txtw  <= c_txtw  + 32'd1;
                    C_TAG   : c_tag   <= c_tag   + 32'd1;
                    C_MARQ  : c_marq  <= c_marq  + 32'd1;
                    C_ULINE : c_uline <= c_uline + 32'd1;
                    C_MQBG  : c_mqbg  <= c_mqbg  + 32'd1;
                    BG      : c_pass  <= c_pass  + 32'd1;
                    default : begin
                        err_cnt <= err_cnt + 1;
                        $display("t=%0t [FAIL] 未知色 %h @(%0d,%0d)",
                                 $time, data_o, u_menu.px3, u_menu.py3);
                    end
                endcase
                check_spots();
            end

            // ---- 帧边界: vs_o 下降沿 → 结算刚结束的窗口 ----
            if (vs_o_d && ~vs_o) begin
                // 滚动相位逐帧 +1 校验(层次引用 u_menu.phase)
                if (phase_first) begin
                    phase_first <= 1'b0;
                    phase_save  <= u_menu.phase;
                end
                else begin
                    if (u_menu.phase !== ((phase_save == 10'd319) ?
                                         10'd0 : phase_save + 10'd1)) begin
                        phase_bad <= phase_bad + 1;
                        $display("t=%0t [FAIL] 滚动相位步进异常 prev=%0d cur=%0d",
                                 $time, phase_save, u_menu.phase);
                    end
                    phase_save <= u_menu.phase;
                end

                if (act_cnt == 0) begin
                    $display("t=%0t [NOTE] 窗口#%0d为空, 跳过", $time, chk_frame);
                end
                else begin
                    valid_cnt <= valid_cnt + 1;
                    case (valid_cnt)                     // 结算时 = 已完成帧数
                        0: begin  // 段0: 全旁路
                            if (act_cnt != TOT_PIX || c_pass != TOT_PIX) begin
                                err_cnt <= err_cnt + 1;
                                $display("t=%0t [FAIL] 旁路段 有效=%0d 透传=%0d 期望=%0d/%0d",
                                         $time, act_cnt, c_pass, TOT_PIX, TOT_PIX);
                            end
                            $display("t=%0t [%s] 帧#%0d 旁路段 (有效=%0d 透传=%0d)",
                                     $time, (act_cnt == TOT_PIX &&
                                             c_pass == TOT_PIX) ? "PASS" : "FAIL",
                                     valid_cnt, act_cnt, c_pass);
                        end
                        1, 2: begin // 段1/2: 菜单开(两帧逐色统计一致)
                            if (act_cnt   != TOT_PIX) fail_cnt("有效像素", act_cnt, TOT_PIX);
                            if (c_bgfull  != EX_BGFULL) fail_cnt("底色BG_FULL", c_bgfull, EX_BGFULL);
                            if (c_card    != EX_CARD)   fail_cnt("卡片内衬", c_card, EX_CARD);
                            if (c_bd      != EX_BD)     fail_cnt("卡片描边", c_bd, EX_BD);
                            if (c_acc0    != EX_ACC)    fail_cnt("色块0", c_acc0, EX_ACC);
                            if (c_acc1    != EX_ACC)    fail_cnt("色块1", c_acc1, EX_ACC);
                            if (c_acc2    != EX_ACC)    fail_cnt("色块2", c_acc2, EX_ACC);
                            if (c_acc3    != EX_ACC)    fail_cnt("色块3", c_acc3, EX_ACC);
                            if (c_txtw    != EX_TXTW)   fail_cnt("白色字形", c_txtw, EX_TXTW);
                            if (c_tag     != EX_TAG)    fail_cnt("副标题字", c_tag, EX_TAG);
                            if (c_marq    != EX_MARQ)   fail_cnt("滚动橙字", c_marq, EX_MARQ);
                            if (c_uline   != EX_ULINE)  fail_cnt("金色线", c_uline, EX_ULINE);
                            if (c_mqbg    != EX_MQBG)   fail_cnt("宣传黑底", c_mqbg, EX_MQBG);
                            if (c_red     != 0)         fail_cnt("应急红", c_red, 0);
                            if (c_pass    != 0)         fail_cnt("背景透传", c_pass, 0);
                            $display("t=%0t [%s] 帧#%0d 菜单段 (有效=%0d)",
                                     $time,
                                     (act_cnt==TOT_PIX && c_bgfull==EX_BGFULL &&
                                      c_card==EX_CARD && c_bd==EX_BD &&
                                      c_acc0==EX_ACC && c_acc1==EX_ACC &&
                                      c_acc2==EX_ACC && c_acc3==EX_ACC &&
                                      c_txtw==EX_TXTW && c_tag==EX_TAG &&
                                      c_marq==EX_MARQ && c_uline==EX_ULINE &&
                                      c_mqbg==EX_MQBG && c_red==0 && c_pass==0)
                                     ? "PASS" : "FAIL",
                                     valid_cnt, act_cnt);
                        end
                        3: begin  // 段3: 应急开/菜单关
                            if (act_cnt != TOT_PIX)         fail_cnt("有效像素", act_cnt, TOT_PIX);
                            if (c_red   != EMERG_PIX)       fail_cnt("应急红", c_red, EMERG_PIX);
                            if (c_pass  != TOT_PIX-EMERG_PIX) fail_cnt("透传", c_pass,
                                                                     TOT_PIX-EMERG_PIX);
                            $display("t=%0t [%s] 帧#%0d 应急段 (有效=%0d 红=%0d 透传=%0d)",
                                     $time, (act_cnt==TOT_PIX &&
                                             c_red==EMERG_PIX &&
                                             c_pass==TOT_PIX-EMERG_PIX)
                                            ? "PASS" : "FAIL",
                                     valid_cnt, act_cnt, c_red, c_pass);
                        end
                        default: ;  // 额外帧不再判(控制提前结束)
                    endcase
                end
                chk_frame <= chk_frame + 1;
                act_cnt   <= 32'd0;
                c_red     <= 32'd0;   c_bgfull <= 32'd0;
                c_card    <= 32'd0;   c_bd     <= 32'd0;
                c_acc0    <= 32'd0;   c_acc1   <= 32'd0;
                c_acc2    <= 32'd0;   c_acc3   <= 32'd0;
                c_txtw    <= 32'd0;   c_tag    <= 32'd0;
                c_marq    <= 32'd0;   c_uline  <= 32'd0;
                c_mqbg    <= 32'd0;   c_pass   <= 32'd0;
            end
        end
    end

    task fail_cnt; input [31:0] nm; input [31:0] got; input [31:0] expc; begin
        err_cnt = err_cnt + 1;
        $display("t=%0t [FAIL] 计数项=%0d got=%0d 期望=%0d", $time, nm, got, expc);
    end endtask

    //--------------- 主流程(按有效帧切换使能) ----------------
    initial begin
        @(negedge rst);                       // 复位释放
        wait (valid_cnt == 1);                // 段0(旁路)结束 → 开菜单
        menu_en = 1'b1;
        wait (valid_cnt == 3);                // 段1/2(两帧菜单)结束 → 关菜单开应急
        menu_en  = 1'b0;
        emerg_en = 1'b1;
        wait (valid_cnt == 4);                // 段3(应急)结束
        #1000;
        if (err_cnt == 0 && phase_bad == 0)
            $display("=== osd_menu V2 仿真结束: 全部通过(校验 %0d 帧) ===",
                     valid_cnt);
        else
            $display("=== osd_menu V2 仿真结束: 失败数=%0d 相位异常=%0d ===",
                     err_cnt, phase_bad);
        $finish;
    end

    // 超时兜底(约 17ms/帧, 4 有效帧+空窗<120ms)
    initial begin
        #250000000 $finish;
    end

endmodule
