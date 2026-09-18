//====================================================================
// 模块名 : tb_osd_welcome.v —— 迎新展示场景 OSD 像素级回归 (osd_welcome)
// 场景   : 生成 VGA 640×480 时序, 以恒定背景色 BG 送入 osd_welcome
//          (数据与重建坐标同拍), 分三段验证:
//   段0 welcome_en=0 : 全帧原样透传背景(纯旁路, 每像素应=BG)
//   段1/2 welcome_en=1 : 全帧自绘, 逐色统计与几何+墨点推导一致:
//          BG(非OSD区背景保持)=244384 / 金底条混色=11489
//          / 欢迎语深字=1887(W_TITLE 32×32 真字模墨点, 1:1)
//          / 左卡藏蓝混色=10460 / 右卡藏蓝混色=10483(总量20943)
//          / 卡内白字=1297(660+637) / 左/右强调条各160
//          / 底部滚动流程亮橙=2248(W_FLOW墨点1124×2, 屏宽=两整周期)
//          / 暗带底=24632 / 背景透传=244384
//          两帧连续核对(滚动相位逐帧+1 但整帧计数不变), 第2帧再采样
//          字形 ON/OFF 点(坐标与 gen_osd_font.py 打印一致)
//   段3 welcome_en=0 : 关闭后背景恢复纯透传(证明使能可控)
// 结算方式 : 以 osd_welcome 输出 vs 下降沿结算窗口; 复位释放瞬间的空
//          窗口跳过; 之后每个窗口恰含一帧, 依次按段0/1/2/3 结算。
// 期望值推导见文件头与段内算式(几何= osd_welcome.v, 墨点= gen 打印)。
//====================================================================

`timescale 1ns/1ps
module tb_osd_welcome;

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

    //---- 输入背景与各输出颜色(与 osd_welcome.v 常量一致) ----
    // 恒定背景 BG, 使每类 OSD 混色成为唯一可计数颜色:
    //   金底50%=(BG+GOLD)>>1 / 卡底75%=(BG+3*NAVY)>>2 / 暗带=BG>>2
    localparam BG      = 24'h204080;
    localparam C_GOLDM = 24'h8F8965;   // 金底条混色
    localparam C_CARDM = 24'h0F2C55;   // 信息卡藏蓝混色
    localparam C_DARKM = 24'h081020;   // 底部暗带
    localparam C_TXT_T = 24'h142A50;   // 欢迎语字形(深藏青)
    localparam C_TXT_I = 24'hF5FDFF;   // 信息卡字形(近白)
    localparam C_TXT_F = 24'hFF7A1F;   // 流程滚动字(亮橙)
    localparam C_ACCL  = 24'h2E7CF6;   // 左卡强调(蓝)
    localparam C_ACCR  = 24'h18C99E;   // 右卡强调(青)

    //================================================================
    // 期望逐色计数(几何与墨点推导):
    //   BG 透传=307200 - 叠加区(13376+11280+11280+26880=62816)=244384
    //   金底区(行8..51=44行 × x168..471=304px)=13376
    //     → 金底混色=13376 - 欢迎语墨点 1887 = 11489
    //   欢迎语字=1887(32×32 真字模 1:1) / 左卡强调=4×40=160 / 右卡强调=160
    //   左卡(行392..431=40行 × x24..305=282px)=11280
    //     → 左卡混色=11280-160-660=10460
    //   右卡(x334..615 同宽)=11280 → 右卡混色=11280-160-637=10483
    //   卡内白字=660+637=1297
    //   滚动橙=1124×2(屏宽640=两整周期 320)=2248
    //     / 暗带=42×640-2248=24632
    //   校验和=244384+11489+1887+160+160+10460+10483+1297+2248+24632
    //          =307200
    //================================================================
    localparam TOT_PIX  = H_ACT * V_ACT;                 // 307200
    localparam EX_BG    = 244384;
    localparam EX_GOLD  = 11489;
    localparam EX_TITLE = 1887;
    localparam EX_ACCL  = 160;
    localparam EX_ACCR  = 160;
    localparam EX_CARD  = 10460 + 10483;                 // 两卡同混色
    localparam EX_WTXT  = 660 + 637;                     // 卡内白字合计
    localparam EX_ORNG  = 2248;
    localparam EX_DARK  = 24632;

    //--------------- 信号 ----------------
    reg         clk;
    reg         rst;
    wire        hs_i, vs_i, de_i;
    wire [23:0] data_i;
    wire [11:0] px_i, py_i;
    reg         welcome_en;
    wire        hs_o, vs_o, de_o;
    wire [23:0] data_o;
    wire [11:0] px_x_o, px_y_o;

    // 结算/统计
    integer     err_cnt;
    integer     chk_frame;
    integer     valid_cnt;
    reg  [31:0] act_cnt;
    reg  [31:0] c_bg, c_gold, c_title, c_accl, c_accr;
    reg  [31:0] c_card, c_wtxt, c_orng, c_dark;
    reg         vs_o_d;                 // vs_o 延迟一拍(下降沿检测)
    reg  [9:0]  phase_save;
    reg         phase_first;
    integer     phase_bad;

    //--------------- 例化被测模块 ----------------
    // 共享字形 ROM(与 top.v 同构: 实体在 TB 顶层例化, 被 u_welcome 读)
    wire        rom_en_w;
    wire [12:0] rom_addr_w;
    wire [31:0] rom_q;
    osd_font_rom #(.ADDR_W(13), .DEPTH(5856)) u_font_rom (
        .clk   (clk),
        .rst   (rst),
        .rd_en (rom_en_w),
        .addr  (rom_addr_w),
        .q     (rom_q)
    );

    osd_welcome #(
        .DATA_W  (24),
        .H_ACT   (H_ACT),
        .V_ACT   (V_ACT)
    ) u_welcome (
        .video_clk  (clk),
        .rst        (rst),
        .hs_i       (hs_i),
        .vs_i       (vs_i),
        .de_i       (de_i),
        .data_i     (data_i),
        .px_x       (px_i),
        .px_y       (py_i),
        .welcome_en (welcome_en),
        .rom_en_o   (rom_en_w),
        .rom_addr_o (rom_addr_w),
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

    //--------------- 控制使能: 复位后默认关闭 ----------------
    initial welcome_en = 1'b0;

    //--------------- 视频时序发生器(模拟 osd_menu 出口) ----------------
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
    assign data_i = de_r ? BG : 24'h000000;     // 恒定背景, 与 de 同拍
    assign px_i   = de_r ? (h_cnt - H_START) : 12'd0;
    assign py_i   = de_r ? (v_cnt - V_START) : 12'd0;

    //================================================================
    // 采样点核对(第 2 张 OSD 帧, 坐标与 gen_osd_font.py 打印一致):
    //  ON = 字形墨点 -> 应写字色;  OFF = 字形区空白 -> 应衬底色
    //  另取 强调条 / 金底区 / 暗带区 特征点
    //================================================================
    task chk; input [11:0] x; input [11:0] y; input [23:0] expc;
             input [255:0] tag; begin
        if (u_welcome.px3 == x && u_welcome.py3 == y) begin
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
            chk(215, 15, C_TXT_T, "W_TITLE ON");
            chk(208, 14, C_GOLDM, "W_TITLE OFF");
            chk( 88,400, C_TXT_I, "W_PLACE ON");
            chk( 85,400, C_CARDM, "W_PLACE OFF");
            chk(395,400, C_TXT_I, "W_CONT ON");
            chk(355,400, C_CARDM, "W_CONT OFF");
            // ---- 特征点: 强调条 / 金底边缘 / 暗带 ----
            chk( 25,410, C_ACCL,  "左卡强调");
            chk(336,410, C_ACCR,  "右卡强调");
            chk(169,  8, C_GOLDM, "金底条左上");
            chk(470, 51, C_GOLDM, "金底条右下");
            chk(470,  7, BG,      "金底条外(背景保持)");
            chk(169, 52, BG,      "金底条下外(背景保持)");
            chk(300,445, C_DARKM, "暗带上段");
            chk(300,470, C_DARKM, "暗带下段");
            chk(  5,  5, BG,      "顶部背景");
            chk(620, 10, BG,      "右侧背景");
            chk(320,300, BG,      "中部背景");
        end
    end endtask

    //--------------- 自动检查 ----------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            err_cnt    <= 0;
            chk_frame  <= 0;
            valid_cnt  <= 0;
            act_cnt    <= 32'd0;
            c_bg       <= 32'd0;  c_gold  <= 32'd0;
            c_title    <= 32'd0;  c_accl  <= 32'd0;
            c_accr     <= 32'd0;  c_card  <= 32'd0;
            c_wtxt     <= 32'd0;  c_orng  <= 32'd0;
            c_dark     <= 32'd0;
            vs_o_d     <= 1'b1;
            phase_save <= 10'd0;
            phase_first<= 1'b1;
            phase_bad  <= 0;
        end
        else begin
            vs_o_d <= vs_o;

            // ---- 有效像素内: 逐像素分类计数 ----
            if (de_o) begin
                act_cnt <= act_cnt + 32'd1;
                case (data_o)
                    BG      : c_bg    <= c_bg    + 32'd1;
                    C_GOLDM : c_gold  <= c_gold  + 32'd1;
                    C_TXT_T : c_title <= c_title + 32'd1;
                    C_ACCL  : c_accl  <= c_accl  + 32'd1;
                    C_ACCR  : c_accr  <= c_accr  + 32'd1;
                    C_CARDM : c_card  <= c_card  + 32'd1;
                    C_TXT_I : c_wtxt  <= c_wtxt  + 32'd1;
                    C_TXT_F : c_orng  <= c_orng  + 32'd1;
                    C_DARKM : c_dark  <= c_dark  + 32'd1;
                    default : begin
                        err_cnt <= err_cnt + 1;
                        $display("t=%0t [FAIL] 未知色 %h @(%0d,%0d)",
                                 $time, data_o, u_welcome.px3, u_welcome.py3);
                    end
                endcase
                check_spots();
            end

            // ---- 帧边界: vs_o 下降沿 → 结算刚结束的窗口 ----
            if (vs_o_d && ~vs_o) begin
                // 滚动相位逐帧 +1 校验(层次引用 u_welcome.phase)
                if (phase_first) begin
                    phase_first <= 1'b0;
                    phase_save  <= u_welcome.phase;
                end
                else begin
                    if (u_welcome.phase !== ((phase_save == 10'd319) ?
                                         10'd0 : phase_save + 10'd1)) begin
                        phase_bad <= phase_bad + 1;
                        $display("t=%0t [FAIL] 滚动相位步进异常 prev=%0d cur=%0d",
                                 $time, phase_save, u_welcome.phase);
                    end
                    phase_save <= u_welcome.phase;
                end

                if (act_cnt == 0) begin
                    $display("t=%0t [NOTE] 窗口#%0d为空, 跳过", $time, chk_frame);
                end
                else begin
                    valid_cnt <= valid_cnt + 1;
                    case (valid_cnt)                     // 结算时 = 已完成帧数
                        0: begin  // 段0: 纯旁路(不叠加)
                            if (act_cnt != TOT_PIX || c_bg != TOT_PIX) begin
                                err_cnt <= err_cnt + 1;
                                $display("t=%0t [FAIL] 旁路段 有效=%0d 透传=%0d 期望=%0d/%0d",
                                         $time, act_cnt, c_bg, TOT_PIX, TOT_PIX);
                            end
                            $display("t=%0t [%s] 帧#%0d 旁路段 (有效=%0d 透传=%0d)",
                                     $time, (act_cnt == TOT_PIX &&
                                             c_bg == TOT_PIX) ? "PASS" : "FAIL",
                                     valid_cnt, act_cnt, c_bg);
                        end
                        1, 2: begin // 段1/2: OSD 开(两帧逐色统计一致)
                            if (act_cnt  != TOT_PIX)  fail_cnt("有效像素", act_cnt, TOT_PIX);
                            if (c_bg     != EX_BG)    fail_cnt("背景透传", c_bg, EX_BG);
                            if (c_gold   != EX_GOLD)  fail_cnt("金底混色", c_gold, EX_GOLD);
                            if (c_title  != EX_TITLE) fail_cnt("欢迎语字", c_title, EX_TITLE);
                            if (c_accl   != EX_ACCL)  fail_cnt("左卡强调", c_accl, EX_ACCL);
                            if (c_accr   != EX_ACCR)  fail_cnt("右卡强调", c_accr, EX_ACCR);
                            if (c_card   != EX_CARD)  fail_cnt("卡片混色", c_card, EX_CARD);
                            if (c_wtxt   != EX_WTXT)  fail_cnt("信息卡字", c_wtxt, EX_WTXT);
                            if (c_orng   != EX_ORNG)  fail_cnt("滚动橙字", c_orng, EX_ORNG);
                            if (c_dark   != EX_DARK)  fail_cnt("暗带底", c_dark, EX_DARK);
                            $display("t=%0t [%s] 帧#%0d OSD段 (有效=%0d)",
                                     $time,
                                     (act_cnt==TOT_PIX && c_bg==EX_BG &&
                                      c_gold==EX_GOLD && c_title==EX_TITLE &&
                                      c_accl==EX_ACCL && c_accr==EX_ACCR &&
                                      c_card==EX_CARD && c_wtxt==EX_WTXT &&
                                      c_orng==EX_ORNG && c_dark==EX_DARK)
                                     ? "PASS" : "FAIL",
                                     valid_cnt, act_cnt);
                        end
                        3: begin  // 段3: 再关 OSD → 背景恢复纯透传
                            if (act_cnt != TOT_PIX || c_bg != TOT_PIX) begin
                                err_cnt <= err_cnt + 1;
                                $display("t=%0t [FAIL] 复旁路段 有效=%0d 透传=%0d 期望=%0d/%0d",
                                         $time, act_cnt, c_bg, TOT_PIX, TOT_PIX);
                            end
                            $display("t=%0t [%s] 帧#%0d 复旁路段 (有效=%0d 透传=%0d)",
                                     $time, (act_cnt == TOT_PIX &&
                                             c_bg == TOT_PIX) ? "PASS" : "FAIL",
                                     valid_cnt, act_cnt, c_bg);
                        end
                        default: ;  // 额外帧不再判(控制提前结束)
                    endcase
                end
                chk_frame <= chk_frame + 1;
                act_cnt   <= 32'd0;
                c_bg      <= 32'd0;  c_gold  <= 32'd0;
                c_title   <= 32'd0;  c_accl  <= 32'd0;
                c_accr    <= 32'd0;  c_card  <= 32'd0;
                c_wtxt    <= 32'd0;  c_orng  <= 32'd0;
                c_dark    <= 32'd0;
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
        wait (valid_cnt == 1);                // 段0(旁路)结束 → 开 OSD
        welcome_en = 1'b1;
        wait (valid_cnt == 3);                // 段1/2(两帧 OSD)结束 → 关闭
        welcome_en = 1'b0;
        wait (valid_cnt == 4);                // 段3(复旁路)结束
        #1000;
        if (err_cnt == 0 && phase_bad == 0)
            $display("=== osd_welcome 仿真结束: 全部通过(校验 %0d 帧) ===",
                     valid_cnt);
        else
            $display("=== osd_welcome 仿真结束: 失败数=%0d 相位异常=%0d ===",
                     err_cnt, phase_bad);
        $finish;
    end

    // 超时兜底(约 17ms/帧, 4 有效帧+空窗<120ms)
    initial begin
        #250000000 $finish;
    end

endmodule
