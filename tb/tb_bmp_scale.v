//====================================================================
// 模块名 : tb_bmp_scale.v
// 功能   : 双线性插值缩放引擎(bmp_scale)仿真
// 验证点 :
//   1. 档位配置表(默认 640x480 源/画布)与设计规格逐项一致
//      → 用默认参数的第 2 个实例只看组合查表结果, 不做数据流(便宜)
//   2. 数据流(用小尺寸实例 64x48 / 画布 64x48 加速仿真):
//      · 100%(档4): 逐像素恒等 out(x,y) == src(x,y)
//      · 50%(档2) : 逐像素 out(x,y) == src(2*(x-x0), 2*y), 区外=黑
//      · 25%(档0) : 逐像素 out(x,y) == src(4*(x-x0), 4*y), 区外=黑
//      · 300%(档7): 只查"整帧正好 307200/小画布 3072 个像素 + 不死锁"
//      · 每帧输出像素数必须精确 = CANV_W*CANV_H(多/少都算错)
//   3. 输入节拍两种都覆盖: 单拍脉冲 / 连续 3 拍电平(模拟真实 SPI 字节节拍)
// 注意   : 喂数速率必须**≈实机 SPI 速率(96 拍/像素)**, 本 tb 用 97 拍。
//          若喂太快(如 33 拍), 放大档会出现"输出跟不上输入 → 等到的源行
//          已被覆盖"的假死锁, 与设计无关(缩小档已验证不受此影响)。
//          另外缩小档图像**垂直顶部对齐**(y0=0)、水平居中 —— 见 bmp_scale 头注释。
//====================================================================

`timescale 1ns/1ps
module tb_bmp_scale;

    localparam CLK_PERIOD = 10;      // 100MHz -> 10ns
    localparam SW = 64;              // 小尺寸源宽
    localparam SH = 48;              // 小尺寸源高
    localparam CW = 64;              // 小尺寸画布宽
    localparam CH = 48;              // 小尺寸画布高

    reg         clk, rst;
    reg  [3:0]  scale_sel;
    reg         frame_start, in_en;
    reg  [31:0] in_data;
    wire        out_en;
    wire [31:0] out_data;

    integer     fail_cnt = 0;
    integer     out_cnt;             // 本帧已输出像素数
    integer     ox, oy;              // 输出像素坐标
    integer     err_pix;             // 本帧数据不符像素数
    integer     skip_cmp;            // 1=本帧不做逐点比对(只查数量)

    // ---- 小尺寸实例(数据流) ----
    bmp_scale #(
        .SRC_W  (SW), .SRC_H  (SH),
        .CANV_W (CW), .CANV_H (CH)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .scale_sel   (scale_sel),
        .frame_start (frame_start),
        .in_en       (in_en),
        .in_data     (in_data),
        .out_en      (out_en),
        .out_data    (out_data)
    );

    // ---- 默认尺寸实例(仅查档位配置表, 不喂数据) ----
    reg  [3:0]  cfg_sel;
    bmp_scale u_cfg (
        .clk (clk), .rst (rst), .scale_sel (cfg_sel),
        .frame_start (1'b0), .in_en (1'b0), .in_data (32'd0),
        .out_en (), .out_data ()
    );

    //--------------------------------------------------------------
    // 源图像素图案(确定性, 便于恒等/取样比对)
    //--------------------------------------------------------------
    function [31:0] src_word;
        input integer x, y;
        reg [7:0] r, g, b;
        begin
            r = (x + 3*y) & 8'hFF;
            g = (2*x + y) & 8'hFF;
            b = (x ^ y)     & 8'hFF;
            src_word = {r, g, b, 8'h00};
        end
    endfunction

    //--------------------------------------------------------------
    // 期望输出像素(小尺寸画布)
    //--------------------------------------------------------------
    function [31:0] exp_word;
        input integer x, y;
        input [3:0]   sel;
        integer u, v;
        begin
            exp_word = 32'd0;
            case (sel)
            // 100%: 恒等
            4'd4: exp_word = src_word(x, y);
            // 50%: dstw=32 dsth=24 → x0=(64-32)/2=16, y0=0(缩小档顶部对齐)
            4'd2: begin
                u = x - 16; v = y;
                if ((u >= 0) && (u < 32) && (v >= 0) && (v < 24))
                    exp_word = src_word(2*u, 2*v);
            end
            // 25%: dstw=16 dsth=12 → x0=24, y0=0
            4'd0: begin
                u = x - 24; v = y;
                if ((u >= 0) && (u < 16) && (v >= 0) && (v < 12))
                    exp_word = src_word(4*u, 4*v);
            end
            default: exp_word = 32'hxxxx_xxxx;   // 不比对
            endcase
        end
    endfunction

    //--------------------------------------------------------------
    // 输出采集 + 比对
    //--------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            out_cnt <= 0;
            ox      <= 0;
            oy      <= 0;
            err_pix <= 0;
        end
        else if (out_en) begin
            if (!skip_cmp) begin
                if (out_data !== exp_word(ox, oy, scale_sel)) begin
                    err_pix <= err_pix + 1;
                    if (err_pix < 5)
                        $display("  [比对] t=%0t out(%0d,%0d)=%08x 期望 %08x (sel=%0d)",
                                 $time, ox, oy, out_data,
                                 exp_word(ox, oy, scale_sel), scale_sel);
                end
            end
            out_cnt <= out_cnt + 1;
            if (ox == CW-1) begin
                ox <= 0;
                if (oy == CH-1) oy <= 0;
                else            oy <= oy + 1;
            end
            else ox <= ox + 1;
        end
    end

    task check(input cond, input [255:0] msg);
        begin
            if (cond) $display("t=%0t  [PASS] %0s", $time, msg);
            else begin
                fail_cnt = fail_cnt + 1;
                $display("t=%0t  [FAIL] %0s", $time, msg);
            end
        end
    endtask

    //--------------------------------------------------------------
    // 送一帧源图: hold=in_en 高电平拍数(1=单拍脉冲 / 3=电平保持),
    //             gap = 像素间隔低电平拍数(1 像素总周期 = hold+gap)
    //--------------------------------------------------------------
    task send_frame(input integer hold, input integer gap);
        integer x, y;
        begin
            // 帧起点(写通路应答): 高 4 拍 → 内部两级同步后产生 fs_pulse
            frame_start = 1'b1;
            repeat (4) @(posedge clk);
            frame_start = 1'b0;
            repeat (6) @(posedge clk);
            for (y = 0; y < SH; y = y + 1) begin
                for (x = 0; x < SW; x = x + 1) begin
                    in_en   = 1'b1;
                    in_data = src_word(x, y);
                    repeat (hold) @(posedge clk);
                    in_en   = 1'b0;
                    repeat (gap)  @(posedge clk);
                end
            end
        end
    endtask

    // 等一帧输出结束(输出像素数到齐 或 超时)
    task wait_frame(input integer to);
        integer n;
        begin
            for (n = 0; n < to; n = n + 1) begin
                @(posedge clk);
                if (out_cnt >= CW*CH) n = to;
            end
            if (out_cnt < CW*CH)
                $display("  [STALL] out_cnt=%0d row=%0d col=%0d state=%0d sy0=%0d sy1=%0d vld=%b brow=%0d/%0d/%0d",
                         out_cnt, dut.out_row, dut.out_col, dut.state, dut.sy0_r, dut.sy1_r,
                         dut.buf_vld, dut.buf_row[0], dut.buf_row[1], dut.buf_row[2]);
        end
    endtask

    //--------------------------------------------------------------
    // 单帧测试流程
    //--------------------------------------------------------------
    task run_frame(input [3:0] sel, input integer hold, input integer gap,
                   input integer cmp, input [255:0] msg);
        begin
            $display("---- 档位 %0d : %0s ----", sel, msg);
            scale_sel = sel;
            skip_cmp  = (cmp == 0) ? 1 : 0;
            in_en = 1'b0; frame_start = 1'b0;
            repeat (4) @(posedge clk);
            out_cnt = 0; ox = 0; oy = 0; err_pix = 0;
            send_frame(hold, gap);
            wait_frame(600000);
            if (out_cnt == CW*CH)
                $display("t=%0t  [PASS] 整帧输出像素数 = %0d (%0s)", $time, out_cnt, msg);
            else begin
                fail_cnt = fail_cnt + 1;
                $display("t=%0t  [FAIL] 整帧输出像素数 = %0d, 期望 %0d (%0s)",
                         $time, out_cnt, CW*CH, msg);
            end
            if (cmp != 0) begin
                if (err_pix == 0)
                    $display("t=%0t  [PASS] 逐像素值与期望完全一致 (%0s)", $time, msg);
                else begin
                    fail_cnt = fail_cnt + 1;
                    $display("t=%0t  [FAIL] %0d 个像素值与期望不符 (%0s)",
                             $time, err_pix, msg);
                end
            end
        end
    endtask

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        #80000000;   // 80ms 超时兜底
        $display("=== [TIMEOUT] 仿真超时,失败数=%0d (out_cnt=%0d) ===", fail_cnt, out_cnt);
        $finish;
    end

    initial begin
        rst = 1'b1; scale_sel = 4'd4; frame_start = 1'b0;
        in_en = 1'b0; in_data = 32'd0;
        out_cnt = 0; ox = 0; oy = 0; err_pix = 0; skip_cmp = 1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (10) @(posedge clk);

        //========================================================
        // 1. 默认尺寸(640x480)档位配置表逐项核对
        //    K=SRC/dst 的 Q16, dstw/dsth 为缩放后尺寸,
        //    x0 为水平居中偏移 / y0 为垂直锚点(缩小档=0 顶部对齐, 放大档<0 中心裁剪)
        //========================================================
        $display("---- 档位配置表(默认 640x480 源 / 640x480 画布) ----");
        cfg_sel = 4'd0; #1;
        check(u_cfg.cfg_k == 19'd262144 && u_cfg.cfg_dstw == 12'd160 &&
              u_cfg.cfg_dsth == 12'd120 && u_cfg.cfg_x0 == 13'sd240 &&
              u_cfg.cfg_y0 == 13'sd0, "档0 25% : 160x120 x居中240/y顶部0");
        cfg_sel = 4'd1; #1;
        check(u_cfg.cfg_k == 19'd196608 && u_cfg.cfg_dstw == 12'd213 &&
              u_cfg.cfg_dsth == 12'd160 && u_cfg.cfg_x0 == 13'sd213 &&
              u_cfg.cfg_y0 == 13'sd0, "档1 33% : 213x160 x居中213/y顶部0");
        cfg_sel = 4'd2; #1;
        check(u_cfg.cfg_k == 19'd131072 && u_cfg.cfg_dstw == 12'd320 &&
              u_cfg.cfg_dsth == 12'd240 && u_cfg.cfg_x0 == 13'sd160 &&
              u_cfg.cfg_y0 == 13'sd0, "档2 50% : 320x240 x居中160/y顶部0");
        cfg_sel = 4'd3; #1;
        check(u_cfg.cfg_k == 19'd98304 && u_cfg.cfg_dstw == 12'd426 &&
              u_cfg.cfg_dsth == 12'd320 && u_cfg.cfg_x0 == 13'sd107 &&
              u_cfg.cfg_y0 == 13'sd0, "档3 67% : 426x320 x居中107/y顶部0");
        cfg_sel = 4'd4; #1;
        check(u_cfg.cfg_k == 19'd65536 && u_cfg.cfg_dstw == 12'd640 &&
              u_cfg.cfg_dsth == 12'd480 && u_cfg.cfg_x0 == 13'sd0 &&
              u_cfg.cfg_y0 == 13'sd0, "档4 100%: 640x480 全画布(0,0)");
        cfg_sel = 4'd5; #1;
        check(u_cfg.cfg_k == 19'd43691 && u_cfg.cfg_dstw == 12'd960 &&
              u_cfg.cfg_dsth == 12'd720 && u_cfg.cfg_x0 == -13'sd160 &&
              u_cfg.cfg_y0 == -13'sd120, "档5 150%: 960x720 中心裁剪(-160,-120)");
        cfg_sel = 4'd6; #1;
        check(u_cfg.cfg_k == 19'd32768 && u_cfg.cfg_dstw == 12'd1280 &&
              u_cfg.cfg_dsth == 12'd960 && u_cfg.cfg_x0 == -13'sd320 &&
              u_cfg.cfg_y0 == -13'sd240, "档6 200%: 1280x960 中心裁剪(-320,-240)");
        cfg_sel = 4'd7; #1;
        check(u_cfg.cfg_k == 19'd21845 && u_cfg.cfg_dstw == 12'd1920 &&
              u_cfg.cfg_dsth == 12'd1440 && u_cfg.cfg_x0 == -13'sd640 &&
              u_cfg.cfg_y0 == -13'sd480, "档7 300%: 1920x1440 中心裁剪(-640,-480)");

        //========================================================
        // 2. 数据流(小尺寸实例 64x48)
        //    喂数 1 像素 = 1+96 = 97 拍(对齐实机 SPI 25MHz 的 ~96 拍/像素)
        //========================================================
        // 100%: 恒等(最严格)
        run_frame(4'd4, 1, 96, 1, "100% 恒等");
        // 50%: 2:1 精确取样(整数映射, 无插值误差) + 下方大黑区
        run_frame(4'd2, 1, 96, 1, "50% 2:1 取样");
        // 25%: 4:1 精确取样 + 大片黑区
        run_frame(4'd0, 1, 96, 1, "25% 4:1 取样");
        // 300%: 只查整帧数量与不死锁(每源像素产出 3 个输出像素, 最吃带宽)
        run_frame(4'd7, 1, 96, 0, "300% 放大裁剪");
        // 100% + 输入电平保持 3 拍(模拟真实 SPI 字节节拍)
        run_frame(4'd4, 3, 96, 1, "100% 恒等(输入电平保持 3 拍)");

        $display("=== bmp_scale 仿真结束,失败数=%0d ===", fail_cnt);
        if (fail_cnt == 0) $display("=== [ALL PASS] ===");
        $finish;
    end

endmodule
