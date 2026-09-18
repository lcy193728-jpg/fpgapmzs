//====================================================================
// 模块名 : tb_osd_engine.v —— OSD 叠加底座仿真
// 场景   : 生成 VGA 640×480 时序(带 hs/vs 负脉冲与消隐), 模拟 video_delay
//          输出的"已对齐像素流", 验证:
//   1. 重建坐标正确: 每帧首像素(px_x,px_y)=(0,0), 末像素=(639,479),
//      且跨帧后 y 归零
//   2. 测试矩形叠加: (160,120)~(480,360) 内橙色 FFA000, 矩形外保持背景
//   3. 管线对齐: 每完整帧橙色像素=320×240=76800, 有效像素=307200
// 结算方式 : 以 osd_engine 输出 vs 的下降沿结算每个"窗口"。复位释放瞬间
//           vs_o_r 仍为低、而监测器 vs_lat 预置为高, 会产生 1~2 个无像素
//           的假窗口 → 直接跳过; 之后每个窗口恰含一帧 → 逐帧校验, 累计
//           满 3 个完整帧即结束。
//====================================================================

`timescale 1ns/1ps
module tb_osd_engine;

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

    localparam BG      = 24'h204080;                     // 背景
    localparam OVL     = 24'hFFA000;                     // 测试矩形色

    // 测试矩形范围(与 osd_engine 参数一致)
    localparam RX0 = 160, RY0 = 120, RX1 = 480, RY1 = 360;

    //--------------- 信号 ----------------
    reg         clk;
    reg         rst;
    wire        hs_i, vs_i, de_i;        // 时序发生器组合输出(与 data 同拍)
    wire [23:0] data_i;
    wire        hs_o, vs_o, de_o;
    wire [23:0] data_o;
    wire [11:0] px_x, px_y;

    // 结算/统计
    integer     err_cnt;                 // 累计失败数
    integer     chk_frame;               // 已遇到的 vs_o 下降沿(窗口)数
    integer     valid_cnt;               // 已校验的满帧窗口数
    reg  [31:0] ovl_cnt;                 // 当前窗口内橙色像素
    reg  [31:0] act_cnt;                 // 当前窗口内有效像素(de_o=1)
    reg         de_o_d;                  // de_o 延迟一拍(上升沿检测)
    reg         vs_o_d;                  // vs_o 延迟一拍(下降沿检测)
    reg  [11:0] first_x, first_y;        // 首有效像素坐标
    reg         first_done;              // 是否已捕获首像素坐标
    reg         first_checked;           // 帧首坐标是否已核对
    reg  [11:0] last_x, last_y;          // 末有效像素坐标(随 de_o 刷新)

    //--------------- 例化被测模块 ----------------
    osd_engine #(
        .DATA_WIDTH  (24),
        .H_ACTIVE    (H_ACT),
        .V_ACTIVE    (V_ACT),
        .TEST_RECT_EN(1'b1),             // 打开测试矩形
        .TEST_X0     (RX0),
        .TEST_Y0     (RY0),
        .TEST_X1     (RX1),
        .TEST_Y1     (RY1)
    ) uut (
        .video_clk(clk),
        .rst      (rst),
        .hs_i     (hs_i),
        .vs_i     (vs_i),
        .de_i     (de_i),
        .data_i   (data_i),
        .ovl_en   (1'b0),
        .ovl_rgb  (24'h000000),
        .hs_o     (hs_o),
        .vs_o     (vs_o),
        .de_o     (de_o),
        .data_o   (data_o),
        .px_x     (px_x),
        .px_y     (px_y)
    );

    //--------------- 时钟 / 复位 ----------------
    initial clk = 1'b0;
    always #(CLK/2) clk = ~clk;

    initial begin
        rst = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
    end

    //--------------- 视频时序发生器(模拟 video_delay 出口) ----------------
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
    assign hs_i  = hs_r;
    assign vs_i  = vs_r;
    assign de_i  = de_r;
    assign data_i = de_r ? BG : 24'h000000;    // 与 de 同拍(已对齐)

    //--------------- 自动检查 ----------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            err_cnt      <= 0;
            chk_frame    <= 0;
            valid_cnt    <= 0;
            ovl_cnt      <= 32'd0;
            act_cnt      <= 32'd0;
            de_o_d       <= 1'b0;
            vs_o_d       <= 1'b1;
            first_done   <= 1'b0;
            first_checked<= 1'b0;
            first_x      <= 12'd0;
            first_y      <= 12'd0;
            last_x       <= 12'd0;
            last_y       <= 12'd0;
        end
        else begin
            de_o_d <= de_o;
            vs_o_d <= vs_o;

            // ---- 有效像素内: 坐标跟踪 + 逐像素比对 ----
            if (de_o) begin
                last_x <= px_x;                // 刷新末坐标(仅有效像素)
                last_y <= px_y;
                act_cnt <= act_cnt + 32'd1;

                if (~de_o_d) begin             // de_o 上升沿 = 帧首行首像素
                    if (!first_done) begin
                        first_x <= px_x;
                        first_y <= px_y;
                        first_done <= 1'b1;
                    end
                end

                if (px_x >= RX0 && px_x < RX1 && px_y >= RY0 && px_y < RY1) begin
                    ovl_cnt <= ovl_cnt + 32'd1;
                    if (data_o !== OVL) begin
                        err_cnt <= err_cnt + 1;
                        $display("t=%0t [FAIL] (%0d,%0d) 应在测试矩形内=橙 got=%h",
                                 $time, px_x, px_y, data_o);
                    end
                end
                else if (data_o !== BG) begin
                    err_cnt <= err_cnt + 1;
                    $display("t=%0t [FAIL] (%0d,%0d) 矩形外应背景 got=%h",
                             $time, px_x, px_y, data_o);
                end
            end

            // ---- 帧边界: vs_o 下降沿 → 结算刚结束的窗口 ----
            if (vs_o_d && ~vs_o) begin
                if (act_cnt == 0) begin
                    // 启动期空窗口(复位期间 vs_o_r 被拉低, 释放后 vs_lat
                    // 预置为高会误判一两次"下降"), 无像素→不判错
                    $display("t=%0t [NOTE] 窗口#%0d为空, 跳过", $time, chk_frame);
                end
                else begin
                    valid_cnt <= valid_cnt + 1;
                    if (act_cnt != H_ACT * V_ACT) begin
                        err_cnt <= err_cnt + 1;
                        $display("t=%0t [FAIL] 帧#%0d有效像素=%0d, 期望%0d",
                                 $time, valid_cnt, act_cnt, H_ACT * V_ACT);
                    end
                    if (ovl_cnt != (RX1 - RX0) * (RY1 - RY0)) begin
                        err_cnt <= err_cnt + 1;
                        $display("t=%0t [FAIL] 帧#%0d橙色像素=%0d, 期望%0d",
                                 $time, valid_cnt, ovl_cnt,
                                 (RX1 - RX0) * (RY1 - RY0));
                    end
                    if (last_x != H_ACT - 1 || last_y != V_ACT - 1) begin
                        err_cnt <= err_cnt + 1;
                        $display("t=%0t [FAIL] 帧#%0d末像素=(%0d,%0d), 期望(%0d,%0d)",
                                 $time, valid_cnt, last_x, last_y,
                                 H_ACT - 1, V_ACT - 1);
                    end
                    // 帧首坐标(每帧首像素应为 (0,0), 只需核对一次)
                    if (!first_checked) begin
                        first_checked <= 1'b1;
                        if (!first_done) begin
                            err_cnt <= err_cnt + 1;
                            $display("t=%0t [FAIL] 首有效像素从未出现(de_o 未上升)",
                                     $time);
                        end
                        else if (first_x != 0 || first_y != 0) begin
                            err_cnt <= err_cnt + 1;
                            $display("t=%0t [FAIL] 首像素=(%0d,%0d), 期望(0,0)",
                                     $time, first_x, first_y);
                        end
                        else
                            $display("t=%0t [PASS] 帧首像素=(%0d,%0d) 坐标重建正确",
                                     $time, first_x, first_y);
                    end
                    $display("t=%0t [%s] 帧#%0d结算完成 (橙=%0d 有效=%0d 末=(%0d,%0d))",
                             $time, (ovl_cnt == (RX1-RX0)*(RY1-RY0) &&
                                     act_cnt == H_ACT*V_ACT &&
                                     last_x == H_ACT-1 && last_y == V_ACT-1)
                                    ? "PASS" : "FAIL",
                             valid_cnt, ovl_cnt, act_cnt, last_x, last_y);
                end
                chk_frame <= chk_frame + 1;
                ovl_cnt   <= 32'd0;
                act_cnt   <= 32'd0;
            end
        end
    end

    //--------------- 主流程 ----------------
    initial begin
        #160000000 $finish;    // 160ms 超时兜底(约 9.5 帧)
    end

    initial begin
        @(negedge rst);
        wait (valid_cnt == 3);               // 校验满 3 个完整帧
        #1000;
        if (err_cnt == 0)
            $display("=== osd_engine 仿真结束: 全部通过(校验 %0d 帧) ===",
                     valid_cnt);
        else
            $display("=== osd_engine 仿真结束: 失败数=%0d ===", err_cnt);
        $finish;
    end

endmodule
