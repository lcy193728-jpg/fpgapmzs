//====================================================================
// 模块名 : tb_bmp_multires.v
// 目的   : 多分辨率自适应(小鹅通第十三讲)专项验证 —— bmp_read_auto 的
//          320×240 / 640×480 / 1024×768 三种源 → 统一产出 640 列
//          (1280×960 由 tb_bmp_2x_decim.v 覆盖, 两者合起来守住四档白名单)
//
// 为什么必须单独写:
//   · tb_bmp_read_auto.v 的假卡全是 640×480 头 → 只覆盖 640 直通;
//   · tb_bmp_2x_decim.v     只覆盖 1280 箱式平均;
//   → 2026-10-02 新写的"320 横向复制 2 次(up_ph 小状态机 en=1,0,1)"和
//     "1024 箱式平均(每 8 源像素 5 箱, 宽 2,2,1,2,1)"**零覆盖**,
//     而这两条正是迎新场景 6 张新照片里 4 张要走的路。
//
// 核对方式: **逐输出像素流式比对**(不存整帧, 用 (col,row) 反查期望值):
//   · 320 : 横向线性插值 [s0,(s0+s1)/2,s1,(s1+s2)/2,…] →
//           偶列 out(2k)=s(k), 奇列 out(2k+1)=mid(s(k),s(k+1)) 且末列边缘钳位;
//           纵向全 240 行选中; img_res=0, img_v2x=1(纵向 2× 交 bmp_scale)
//   · 640 : 相位累加器退化为逐像素 1 箱 → out(col,row)==src(col,row);
//           纵向全 480 行; img_res=1, img_v2x=0
//   · 1024: 横向相位每 8 源像素产 5 箱(宽 2,2,1,2,1 = 640/1024 精确);
//           纵向每 8 源行选 5 行(0,2,4,5,7 = 480/768 精确); img_res=2, img_v2x=0
//   同时必查"整帧输出像素数"精确等于 行数×640(多一列/少一列都会在这里暴露)。
//
// 位宽陷阱(清单 C11):
//   1024/1280 的 2 像素箱求和会 ≥256(本 TB 的像素图案保证了这一点),
//   期望值必须 **宽中间量求和后 >>1**; 若在 tb 里写成 8bit 相加, 会自己先截断
//   而误报 FAIL(写本 TB 时就踩过一次)。
//
// 喂数节拍: 320 用例按 4 拍/字节(≈12 拍/源像素) —— 见 bmp_read_auto.v 的
//   "源像素间隔必须 ≥6 拍" 约束(320 行尾要连发 3 列, 需 5 拍才收得完);
//   640/1024 用例单次发射无此约束, 用 1 拍/字节提速。
//====================================================================

`timescale 1ns/1ps
module tb_bmp_multires;

    localparam CLK_PERIOD = 10;                 // 100MHz

    reg         clk, rst;
    reg         sd_init_done;
    reg         key_trigger, key_prev, slide_en;
    reg  [31:0] slide_interval;
    reg  [31:0] zone_cluster0, zone_size0, zone_max_img;
    reg         zone_load, reload_req;
    reg  [7:0]  file_byte;
    reg         file_valid, file_done;
    reg  [7:0]  file_error;
    reg         write_req_ack;

    wire [3:0]  state_code;
    wire        write_req;
    wire        file_start;
    wire [31:0] file_cluster;
    wire [31:0] file_len_out;
    wire        bmp_data_wr_en;
    wire [23:0] bmp_data;
    wire [7:0]  img_no;
    wire [3:0]  bmp_error;
    wire [1:0]  img_res;
    wire        img_v2x;
    wire        ready, img_busy;

    //==============================================================
    // 用例配置(0=320x240  1=640x480  2=1024x768)
    //==============================================================
    reg  [1:0]  casemode;
    reg  [31:0] cur_w, cur_h, cur_len;
    integer     byte_div;            // 每字节占的时钟数(320 用例须 ≥4)
    integer     exp_rows;            // 期望输出行数
    integer     exp_total;           // 期望输出像素总数
    reg  [1:0]  exp_res;
    reg         exp_v2x;

    always @* begin
        case (casemode)
            2'd0: begin
                cur_w = 32'd320;  cur_h = 32'd240;
                cur_len = 32'd54 + 32'd230400;      // 320×240×3 = 230400
                exp_rows = 240; exp_total = 240*640;
                exp_res = 2'd0; exp_v2x = 1'b1;
            end
            2'd1: begin
                cur_w = 32'd640;  cur_h = 32'd480;
                cur_len = 32'd54 + 32'd921600;      // 640×480×3 = 921600
                exp_rows = 480; exp_total = 480*640;
                exp_res = 2'd1; exp_v2x = 1'b0;
            end
            default: begin
                cur_w = 32'd1024; cur_h = 32'd768;
                cur_len = 32'd54 + 32'd2359296;     // 1024×768×3 = 2359296
                exp_rows = 480; exp_total = 480*640;
                exp_res = 2'd2; exp_v2x = 1'b0;
            end
        endcase
    end

    bmp_read_auto #(
        .SLIDE_INTERVAL      (32'd10_000_000),
        .MIN_PERIOD_CYCLES   (32'd1000),
        .ZONE_MAX_IMAGES     (32'd1),
        .BMP_PIXEL_BYTES     (32'd921600),
        .BMP_PIXEL_BYTES_1024(32'd2359296),
        .SD_READ_TIMEOUT_MS  (16'd200),
        .CLK_FREQ_HZ         (32'd1_000_000),
        .MAX_RETRIES         (4'd0),
        .ALLOW_2X_SOURCE     (1'b1)
    ) dut (
        .clk                    (clk),
        .rst                    (rst),
        .ready                  (ready),
        .sd_init_done           (sd_init_done),
        .key_trigger            (key_trigger),
        .key_prev               (key_prev),
        .slide_en               (slide_en),
        .slide_interval         (slide_interval),
        .zone_start             (32'd0),
        .zone_wrap              (32'd0),
        .zone_max_img           (zone_max_img),
        .zone_load              (zone_load),
        .zone_cluster0          (zone_cluster0),
        .zone_cluster1          (32'd0),
        .zone_cluster2          (32'd0),
        .zone_cluster3          (32'd0),
        .zone_cluster4          (32'd0),
        .zone_cluster5          (32'd0),
        .zone_size0             (zone_size0),
        .zone_size1             (32'd0),
        .zone_size2             (32'd0),
        .zone_size3             (32'd0),
        .zone_size4             (32'd0),
        .zone_size5             (32'd0),
        .reload_req             (reload_req),
        .state_code             (state_code),
        .bmp_width              (16'd640),
        .write_req              (write_req),
        .write_req_ack          (write_req_ack),
        .file_start             (file_start),
        .file_cluster           (file_cluster),
        .file_len_out           (file_len_out),
        .file_valid             (file_valid),
        .file_byte              (file_byte),
        .file_done              (file_done),
        .file_error             (file_error),
        .bmp_data_wr_en         (bmp_data_wr_en),
        .bmp_data               (bmp_data),
        .img_no                 (img_no),
        .img_busy               (img_busy),
        .bmp_error              (bmp_error),
        .img_res                (img_res),
        .img_v2x                (img_v2x)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;
    always @(posedge clk) write_req_ack <= write_req;

    //==============================================================
    // 检查任务
    //==============================================================
    integer fail_cnt = 0;
    task check(input cond, input [255:0] msg);
        begin
            if (cond) $display("t=%0t  [PASS] %0s", $time, msg);
            else begin
                fail_cnt = fail_cnt + 1;
                $display("t=%0t  [FAIL] %0s", $time, msg);
            end
        end
    endtask

    //==============================================================
    // 文件字节流: 按 casemode 生成对应分辨率的 BMP 字节流
    //   像素图案(三档统一, 便于同一套期望函数):
    //     R = x & 0xFF      G = y & 0xFF      B = (x ^ y) & 0xFF
    //   → 行内 G 恒定、R 随 x 线性变, 相邻像素对 R 之和在 x≈128 处越过 256,
    //     且 G≥128 时同值相加也 ≥256 → 稳定命中"9bit 求和"位宽陷阱。
    //   FAT32 化后: 不再走假 SD 扇区, 由 feed_file task 直接按 file_* 接口吐。
    //==============================================================

    // 文件字节: 按文件内字节偏移 gpos 生成
    function [7:0] file_byte_at;
        input [31:0] gpos;
        reg [31:0] p, n, ch, x, y;
        begin
            file_byte_at = 8'h00;
            if (gpos < 32'd54) begin
                // ---- BMP 头(小端) ----
                case (gpos)
                    32'd0 : file_byte_at = "B";
                    32'd1 : file_byte_at = "M";
                    32'd2 : file_byte_at = cur_len[7:0];     // file_len
                    32'd3 : file_byte_at = cur_len[15:8];
                    32'd4 : file_byte_at = cur_len[23:16];
                    32'd5 : file_byte_at = cur_len[31:24];
                    32'd10: file_byte_at = 8'h36;            // pixel_offset = 54
                    32'd14: file_byte_at = 8'h28;            // DIB = 40
                    32'd18: file_byte_at = cur_w[7:0];       // width
                    32'd19: file_byte_at = cur_w[15:8];
                    32'd20: file_byte_at = cur_w[23:16];
                    32'd21: file_byte_at = cur_w[31:24];
                    32'd22: file_byte_at = cur_h[7:0];       // height(正 = 自底向上)
                    32'd23: file_byte_at = cur_h[15:8];
                    32'd24: file_byte_at = cur_h[23:16];
                    32'd25: file_byte_at = cur_h[31:24];
                    32'd26: file_byte_at = 8'h01;            // planes = 1
                    32'd28: file_byte_at = 8'h18;            // bits = 24
                    32'd30: file_byte_at = 8'h00;            // compression = BI_RGB
                    default: file_byte_at = 8'h00;
                endcase
            end
            else begin
                // ---- 像素数据(BMP 字节序 = B, G, R) ----
                p  = gpos - 32'd54;
                n  = p / 32'd3;
                ch = p - n * 32'd3;
                x  = n % cur_w;
                y  = n / cur_w;
                case (ch)
                    32'd0: file_byte_at = (x ^ y) & 32'hFF;   // B
                    32'd1: file_byte_at = y & 32'hFF;         // G
                    32'd2: file_byte_at = x & 32'hFF;         // R
                    default: file_byte_at = 8'h00;
                endcase
            end
        end
    endfunction

    // 文件流响应: 检测到 file_start 后逐字节吐整个文件(带 byte_div 节奏控制)
    //   每字节用 @(negedge clk) 驱动 file_valid=1 一个上升沿; byte_div 控制间隔。
    //   ⚠ 头/像素阶段统一 byte_div 节奏; 头读完需等 write_req_ack(S_READ 已进入)
    //     再吐像素 —— 否则 tb 每字节几拍太快, S_READ_WAIT 期间会丢字节。
    //   320 档源像素间隔 = 3×byte_div 拍, 须 ≥6 拍 → byte_div≥4。
    task feed_file;
        integer g;
        begin
            wait (file_start == 1'b1);
            @(negedge clk);
            // 吐文件头 54 字节(与像素同节奏, 保证头→像素无节奏突变)
            for (g = 0; g < 54; g = g + 1) begin
                repeat (byte_div - 1) @(negedge clk);
                @(negedge clk);
                file_byte  = file_byte_at(g);
                file_valid = 1'b1;
                @(negedge clk);
                file_valid = 1'b0;
            end
            // 等 write_req_ack(S_READ 已进入)再吐像素, 模拟真实 SPI 节奏
            wait (write_req_ack == 1'b1);
            @(posedge clk);
            // 吐像素字节(offset 54 .. cur_len-1), 按 byte_div 节奏
            for (g = 54; g < cur_len; g = g + 1) begin
                repeat (byte_div - 1) @(negedge clk);
                @(negedge clk);
                file_byte  = file_byte_at(g);
                file_valid = 1'b1;
                @(negedge clk);
                file_valid = 1'b0;
            end
            // file_done
            @(posedge clk);
            file_done = 1'b1;
            @(posedge clk);
            file_done = 1'b0;
        end
    endtask

    //==============================================================
    // 期望值反查
    //==============================================================
    function integer pixR; input integer x, y; begin pixR = x & 255; end endfunction
    function integer pixG; input integer x, y; begin pixG = y & 255; end endfunction
    function integer pixB; input integer x, y; begin pixB = (x ^ y) & 255; end endfunction

    // 1024 档: 每 8 源行选 5 行, 组内偏移表 {0,2,4,5,7}
    function integer sel_row; input integer k; begin
        case (k)
            0: sel_row = 0;
            1: sel_row = 2;
            2: sel_row = 4;
            3: sel_row = 5;
            default: sel_row = 7;
        endcase
    end endfunction

    // (col,row) → 期望 24bit 像素
    function [23:0] exp_pixel;
        input integer col, row;
        integer g, r, sx, sy, sx2, sa, sb;
        reg [7:0] vr, vg, vb;
        begin
            sx2 = -1;
            if (casemode == 2'd0) begin            // 320×240: 横向线性插值
                // [s0,(s0+s1)/2,s1,(s1+s2)/2,…] ⇒ 偶列取原值, 奇列取相邻均值
                if ((col % 2) == 0) begin
                    sx = col >> 1;                  // out[2k] = s[k]
                end
                else begin
                    sx  = (col - 1) >> 1;           // out[2k+1] = mid(s[k],s[k+1])
                    sx2 = (sx == 319) ? 319 : (sx + 1);   // 末列边缘钳位(mid(s319,s319))
                end
                sy = row;
            end
            else if (casemode == 2'd1) begin       // 640×480: 1:1 直通
                sx = col;
                sy = row;
            end
            else begin                             // 1024×768: 每 8 源像素 5 箱
                g = col / 5;
                r = col - g * 5;
                case (r)
                    0: begin sx = g*8 + 0; sx2 = g*8 + 1; end
                    1: begin sx = g*8 + 2; sx2 = g*8 + 3; end
                    2: begin sx = g*8 + 4;                end   // 单像素箱
                    3: begin sx = g*8 + 5; sx2 = g*8 + 6; end
                    default: begin sx = g*8 + 7;          end   // 单像素箱
                endcase
                sy = 8 * (row / 5) + sel_row(row - 5 * (row / 5));
            end
            if (sx2 >= 0) begin
                // ★宽中间量求和(integer)再 >>1 —— 与 RTL 的 9bit 求和 + 取[8:1] 一致
                sa = pixR(sx, sy) + pixR(sx2, sy);  vr = sa >> 1;
                sb = pixG(sx, sy) + pixG(sx2, sy);  vg = sb >> 1;
                sa = pixB(sx, sy) + pixB(sx2, sy);  vb = sa >> 1;
            end
            else begin
                vr = pixR(sx, sy); vg = pixG(sx, sy); vb = pixB(sx, sy);
            end
            exp_pixel = {vr, vg, vb};
        end
    endfunction

    //==============================================================
    // 逐输出像素流式比对
    //==============================================================
    integer chk_n, chk_col, chk_row, cmp_err;
    reg [23:0] expv;
    reg [1:0]  res_at_hold;
    reg        v2x_at_hold;

    always @(posedge clk) begin
        if (bmp_data_wr_en) begin
            if (chk_row < exp_rows) begin
                expv = exp_pixel(chk_col, chk_row);
                if (bmp_data !== expv) begin
                    cmp_err = cmp_err + 1;
                    if (cmp_err <= 8)
                        $display("  [比对] t=%0t out(col=%0d,row=%0d)=%06x 期望 %06x (case=%0d)",
                                 $time, chk_col, chk_row, bmp_data, expv, casemode);
                end
            end
            chk_n = chk_n + 1;
            if (chk_col == 639) begin
                chk_col = 0;
                chk_row = chk_row + 1;
            end
            else chk_col = chk_col + 1;
        end
        if (state_code == 4'd5) begin
            res_at_hold = img_res;
            v2x_at_hold = img_v2x;
        end
    end

    //==============================================================
    // 单用例流程
    //==============================================================
    integer i;
    task run_case(input [1:0] cm, input integer bdiv, input [255:0] nm);
        begin
            $display("--------------------------------------------------------");
            $display(" 用例: %0s", nm);
            casemode = cm;
            byte_div = bdiv;
            zone_cluster0 = 32'd30000; zone_size0 = cur_len; zone_max_img = 32'd1;

            rst = 1'b1; sd_init_done = 1'b0;
            zone_load = 1'b0; reload_req = 1'b0;
            file_valid = 1'b0; file_byte = 8'd0; file_done = 1'b0; file_error = 8'd0;
            chk_n = 0; chk_col = 0; chk_row = 0; cmp_err = 0;
            res_at_hold = 2'd0; v2x_at_hold = 1'b1;
            write_req_ack = 1'b0;
            repeat (10) @(posedge clk);
            rst = 1'b0;
            @(posedge clk);
            // 加载簇号表
            zone_load = 1'b1;
            @(posedge clk);
            zone_load = 1'b0;
            @(posedge clk);
            sd_init_done = 1'b1;

            // 后台吐文件流(阻塞式 task, 用 fork 让主流程继续)
            fork
                feed_file;
            join_none

            // 等整帧读完(进 S_HOLD) —— 不能只等输出计数: 最后一行输出完
            // 之后还有若干源像素要读完(只计数不产出)
            i = 0;
            while (state_code !== 4'd5 && i < 80000000) begin
                @(posedge clk);
                i = i + 1;
            end
            if (i >= 80000000)
                $display("  [WARN] 等 S_HOLD 超时, state_code=%0d chk_n=%0d", state_code, chk_n);
            repeat (50) @(posedge clk);

            $display("  输出像素数 = %0d (期望 %0d)", chk_n, exp_total);
            $display("  bmp_error  = %0d", bmp_error);
            $display("  img_res    = %0d (期望 %0d)  img_v2x = %0d (期望 %0d)",
                     res_at_hold, exp_res, v2x_at_hold, exp_v2x);

            check(chk_n == exp_total, "整帧输出像素数精确 = 行数×640");
            check(cmp_err == 0,       "逐输出像素值与期望完全一致");
            check(bmp_error == 4'd0,  "bmp_error = 0 (头校验通过/无截断/无超时)");
            check(res_at_hold == exp_res, "img_res 分辨率码正确");
            check(v2x_at_hold == exp_v2x, "img_v2x 纵向 2× 标志正确");
        end
    endtask

    //==============================================================
    initial begin
        rst = 1'b1; sd_init_done = 1'b0;
        key_trigger = 1'b0; key_prev = 1'b0; slide_en = 1'b0;   // 手动单张: 不自动轮播
        slide_interval = 32'd10_000_000;
        zone_cluster0 = 32'd30000; zone_size0 = 32'd0; zone_max_img = 32'd1;
        zone_load = 1'b0; reload_req = 1'b0;
        file_valid = 1'b0; file_byte = 8'd0; file_done = 1'b0; file_error = 8'd0;
        casemode = 2'd1; byte_div = 1;

        $display("========================================================");
        $display(" tb_bmp_multires : 多分辨率自适应(320/640/1024 → 640 列)");
        $display("========================================================");

        // 320: 横向线性插值 2×, 须按 ≥4 拍/字节喂(见 RTL 的 "源像素间隔 ≥6 拍" 前提)
        run_case(2'd0, 4, "320x240  → 横向线性插值 2× + 全 240 行 (img_v2x=1)");
        // 640: 直通
        run_case(2'd1, 1, "640x480  → 1:1 直通 + 全 480 行");
        // 1024: 箱式平均 + 隔行抽取
        run_case(2'd2, 1, "1024x768 → 每 8 像素 5 箱 + 每 8 行 5 行");

        $display("========================================================");
        if (fail_cnt == 0) $display("=== [ALL PASS] tb_bmp_multires ===");
        else               $display("=== 失败数 = %0d ===", fail_cnt);
        $display("========================================================");
        $finish;
    end

endmodule
