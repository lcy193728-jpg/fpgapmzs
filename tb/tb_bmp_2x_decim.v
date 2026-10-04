//====================================================================
// 模块名 : tb_bmp_2x_decim.v
// 目的   : 专项验证 1280×960(2× 源) → 640×480 的 2×1 抽取降采样通路
//
// 为什么单独写这个 TB:
//   原 tb_bmp_read_auto.v 只连了 img_2x 端口、**没有任何 2× 源用例**
//   (假卡全部是 640×480 头), 所以 2026-10-02 的均值位宽截断 bug
//   ((a+b)>>1 按 8bit 运算丢进位) 在仿真里完全没被覆盖, 只能上板才暴露。
//   本 TB 针对性地喂"通道和 ≥ 256"的像素对, 使该缺陷必然被抓到。
//
// 被测行为:
//   1. 头校验放行 1280×960×24bit(白名单 dim_2x), 且 img_2x 输出为 1
//   2. 水平相邻 2 像素取**逐通道**均值 (R/G/B 独立求和, 不跨通道进位)
//   3. 奇数源行整行丢弃 → 960 行变 480 行
//   4. 输出总像素数 = 640(本 TB 用 2 行源 = 1 行有效输出, 故 640 个)
//
// 假卡(扇区 30000 起):
//   头 54 字节: "BM" + file_len=7734 + pixel_offset=54 + DIB=40 +
//               1280×960 + planes=1 + 24bit + 无压缩
//   像素数据 2560 源像素 = 2 行 × 1280:
//     第 0 行(有效行): 前 640 列像素对 = (R200,G100,B50) —— R 的和 400 ≥ 256
//                     后 640 列像素对 = (R255,G255,B255) —— 三通道和 510 ≥ 256
//     第 1 行(应被丢弃): 全部 = (R1,G2,B3)
//   期望输出 640 个像素: 前 320 个 = 200/100/50, 后 320 个 = 255/255/255
//
// 位宽陷阱复现依据:
//   修复前 (200+200)>>1 按 8bit 算 = ((400 mod 256))>>1 = 144>>1 = 72 (错, 应 200)
//          (255+255)>>1 按 8bit 算 = ((510 mod 256))>>1 = 254>>1 = 127 (错, 应 255)
//   修复后 先零扩展 9bit 求和再取 [8:1] → 400>>1=200 ✓ / 510>>1=255 ✓
//   依据: 小鹅通 第五讲/第4课 bmp24_decoder.v average_four 官方同款做法
//====================================================================

`timescale 1ns/1ps
module tb_bmp_2x_decim;

    localparam CLK_PERIOD = 10;                 // 100MHz
    localparam [31:0] FILE_LEN = 32'd7734;      // 54 + 2560*3
    localparam integer SRC_PX  = 2560;          // 2 行 × 1280
    localparam integer EXP_OUT = 640;           // 只有第 0 行产出
    // 用 1920 字节(640 像素)作 1× 基准 → 2× 目标 = 640<<2 = 2560 源像素
    localparam [31:0] BMP_PIX_BYTES_SIM = 32'd1920;

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
    wire [1:0]  img_res;                 // 源分辨率码 0=320x240 1=640x480 2=1024x768 3=1280x960
    wire        img_v2x;                 // 1=源高 240(只出 240 行, bmp_scale 补纵向 2×)
    wire        ready, img_busy;

    integer     fail_cnt  = 0;
    integer     out_n     = 0;                  // 输出像素计数
    reg  [23:0] outpix [0:4095];                // 输出像素捕获
    reg         is2x_at_read   = 1'b0;   // S_READ 期间 dut/is_2x(内部判定)采样
    reg  [1:0]  img_res_pub    = 2'd0;   // 整帧读完后 img_res(对外输出)采样
    reg         img_v2x_pub    = 1'b1;   // 整帧读完后 img_v2x(对外输出)采样

    bmp_read_auto #(
        .SLIDE_INTERVAL      (32'd10_000_000),
        .MIN_PERIOD_CYCLES   (32'd1000),
        .ZONE_MAX_IMAGES     (32'd1),
        .BMP_PIXEL_BYTES     (BMP_PIX_BYTES_SIM),
        .BMP_PIXEL_BYTES_1024(32'd480),
        .SD_READ_TIMEOUT_MS  (16'd20),
        .CLK_FREQ_HZ         (32'd1_000_000),
        .MAX_RETRIES         (4'd1),
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

    //---------------- 检查任务 -----------------
    task check(input cond, input [255:0] msg);
        begin
            if (cond) $display("t=%0t  [PASS] %0s", $time, msg);
            else begin
                fail_cnt = fail_cnt + 1;
                $display("t=%0t  [FAIL] %0s", $time, msg);
            end
        end
    endtask

    //---------------- 假 SD 卡(单扇区 512B) -----------------
    //   FAT32 化后删除: bmp_read_auto 改用 file 接口, 不再有 sd_sec_read。
    //   文件字节流由 feed_file task 直接按 file_* 接口吐出。

    // 文件字节生成: 按文件内字节偏移 gpos(0..FILE_LEN-1)生成 BMP 内容
    function [7:0] file_byte_at;
        input [31:0] gpos;
        reg [31:0] p, n, ch;
        begin
            file_byte_at = 8'h00;
            if (gpos < 32'd54) begin
                // ---- BMP 头(小端) ----
                case (gpos)
                    32'd0 : file_byte_at = "B";
                    32'd1 : file_byte_at = "M";
                    32'd2 : file_byte_at = 8'h36;   // file_len = 7734 = 0x1E36
                    32'd3 : file_byte_at = 8'h1E;
                    32'd4 : file_byte_at = 8'h00;
                    32'd5 : file_byte_at = 8'h00;
                    32'd10: file_byte_at = 8'h36;   // pixel_offset = 54
                    32'd14: file_byte_at = 8'h28;   // DIB = 40
                    32'd18: file_byte_at = 8'h00;   // width  = 1280 = 0x0500
                    32'd19: file_byte_at = 8'h05;
                    32'd22: file_byte_at = 8'hC0;   // height = 960  = 0x03C0
                    32'd23: file_byte_at = 8'h03;
                    32'd26: file_byte_at = 8'h01;   // planes = 1
                    32'd28: file_byte_at = 8'h18;   // bits   = 24
                    32'd30: file_byte_at = 8'h00;   // compression = 0 (BI_RGB)
                    32'd34: file_byte_at = 8'h00;   // biSizeImage = 7680 = 0x1E00
                    32'd35: file_byte_at = 8'h1E;
                    default: file_byte_at = 8'h00;
                endcase
            end
            else begin
                // ---- 像素数据(BMP 字节序 = B, G, R) ----
                p  = gpos - 32'd54;
                n  = p / 32'd3;          // 源像素序号
                ch = p - n * 32'd3;      // 0=B, 1=G, 2=R
                if (n < 32'd1280) begin
                    // 第 0 行: 有效行
                    if ((n >> 1) < 32'd320) begin
                        // 像素对 (R=200, G=100, B=50): R 和 = 400 ≥ 256 → 命中位宽陷阱
                        case (ch)
                            32'd0: file_byte_at = 8'd50;    // B
                            32'd1: file_byte_at = 8'd100;   // G
                            32'd2: file_byte_at = 8'd200;   // R
                        endcase
                    end
                    else begin
                        // 像素对 (255,255,255): 三通道和 = 510 ≥ 256 → 三通道均命中
                        file_byte_at = 8'd255;
                    end
                end
                else begin
                    // 第 1 行: 奇数行, 必须整行丢弃; 若泄漏到输出即为 FAIL
                    case (ch)
                        32'd0: file_byte_at = 8'd3;    // B
                        32'd1: file_byte_at = 8'd2;    // G
                        32'd2: file_byte_at = 8'd1;    // R
                    endcase
                end
            end
        end
    endfunction

    // 文件流响应: 检测到 file_start 后逐字节吐整个文件(头 + 像素 + file_done)
    //   每字节用 @(negedge clk) 驱动, file_valid=1 覆盖一个 clk 上升沿, 相位鲁棒。
    task feed_file;
        integer g;
        begin
            wait (file_start == 1'b1);
            @(negedge clk);
            // 吐文件头 54 字节
            for (g = 0; g < 54; g = g + 1) begin
                @(negedge clk);
                file_byte  = file_byte_at(g);
                file_valid = 1'b1;
                @(negedge clk);
                file_valid = 1'b0;
            end
            // 等 write_req_ack(S_READ 已进入)再吐像素, 模拟真实 SPI 节奏
            wait (write_req_ack == 1'b1);
            @(posedge clk);
            // 吐像素字节(offset 54 .. FILE_LEN-1)
            for (g = 54; g < FILE_LEN; g = g + 1) begin
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

    //---------------- 输出像素捕获 -----------------
    //   bmp_data_wr_en 与 bmp_data 由同一 always 块在同一拍赋值, 故同一沿读到的
    //   两者是配套的一对(读的是上一沿写入的值), 直接配对采样即正确。
    always @(posedge clk) begin
        if (bmp_data_wr_en) begin
            if (out_n < 4096) outpix[out_n] = bmp_data;
            out_n = out_n + 1;
        end
        //   ※ 采样时机: 内部 res_r(本帧分辨率码, 在文件头命中 rd_cnt=54 即锁存)
        //     在 S_READ 期间有效; 对外 img_res 只在"整帧完整读完"那一拍才更新
        //     (随状态进 S_HOLD) —— 故两者必须分别在其有效窗口采样, 不可混用。
        //     2026-10-02: 原 dut/is_2x 已并入多分辨率实现 → 用 res_r==2'd3 判 1280 档。
        if (state_code == 4'd4 && (dut.res_r == 2'd3)) is2x_at_read = 1'b1;
        if (state_code == 4'd5) begin
            img_res_pub = img_res;
            img_v2x_pub = img_v2x;
        end
    end

    //---------------- 主激励 -----------------
    integer i;
    integer c200, c255, cbad;
    reg [23:0] px;

    initial begin
        rst = 1'b1; sd_init_done = 1'b0;
        key_trigger = 1'b0; key_prev = 1'b0; slide_en = 1'b1;
        slide_interval = 32'd10_000_000;
        zone_cluster0 = 32'd30000; zone_size0 = FILE_LEN; zone_max_img = 32'd1;
        zone_load = 1'b0; reload_req = 1'b0;
        file_valid = 1'b0; file_byte = 8'd0; file_done = 1'b0; file_error = 8'd0;

        $display("========================================================");
        $display(" tb_bmp_2x_decim : 1280×960 → 640×480 2×1 抽取降采样验证");
        $display("========================================================");

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
            begin : feeder
                feed_file;
            end
        join_none

        // 等"整帧真正读完"= 进入 S_HOLD(state_code=5)
        //   ※ 不能只等 out_n 满 640: 最后一个输出像素来自第 0 行 dcol=1279
        //     (= 第 1280 个源像素), 之后第 1 行的 1280 个源像素仍要被读完
        //     (只丢弃不输出) 才会置 frame_read_done → 进 S_HOLD。
        //     故必须等状态而非等输出计数, 否则会早探到 img_2x(见清单 C2)。
        i = 0;
        while (state_code !== 4'd5 && i < 400000) begin
            @(posedge clk);
            i = i + 1;
        end
        if (i >= 400000) $display("  [WARN] 等待 S_HOLD 超时, state_code=%0d", state_code);
        repeat (100) @(posedge clk);

        $display("--------------------------------------------------------");
        $display(" 输出像素总数 = %0d (期望 %0d)", out_n, EXP_OUT);
        $display(" bmp_error    = %0d (期望 0)", bmp_error);
        $display(" img_no       = %0d", img_no);
        $display(" 样例: outpix[0]=%h outpix[319]=%h outpix[320]=%h outpix[639]=%h",
                 outpix[0], outpix[319], outpix[320], outpix[639]);
        $display("--------------------------------------------------------");

        check(out_n == EXP_OUT, "输出像素数 = 640 (偶数源行全输出, 奇数源行全丢弃)");
        check(bmp_error == 4'd0, "bmp_error = 0 (头校验通过, 无截断/超时)");
        check(is2x_at_read == 1'b1, "S_READ 期间内部 res_r = 3 (1280×960 源已识别)");
        check(img_res_pub  == 2'd3, "整帧读完后对外 img_res = 3 (1280x960 字幕数据源正确)");
        check(img_v2x_pub  == 1'b0, "1280×960 源 img_v2x = 0 (纵向走隔行抽取, 不走 2× 放大)");

        // 逐像素核对: 前 320 个 = 200/100/50, 后 320 个 = 255/255/255
        c200 = 0; c255 = 0; cbad = 0;
        for (i = 0; i < EXP_OUT; i = i + 1) begin
            px = outpix[i];
            if (i < 320) begin
                if (px == 24'hC86432) c200 = c200 + 1;   // R=200,G=100,B=50
                else begin
                    cbad = cbad + 1;
                    if (cbad <= 5)
                        $display("   [值错] outpix[%0d] = %h, 期望 C86432 (R200 G100 B50)", i, px);
                end
            end
            else begin
                if (px == 24'hFFFFFF) c255 = c255 + 1;   // 255/255/255
                else begin
                    cbad = cbad + 1;
                    if (cbad <= 5)
                        $display("   [值错] outpix[%0d] = %h, 期望 FFFFFF (R255 G255 B255)", i, px);
                end
            end
        end
        $display(" 匹配 (200,100,50) 的像素 = %0d / 320", c200);
        $display(" 匹配 (255,255,255) 的像素 = %0d / 320", c255);
        $display(" 不匹配像素 = %0d", cbad);

        check(c200 == 320, "前 320 像素 = (R200,G100,B50): 逐通道均值且进位不丢失");
        check(c255 == 320, "后 320 像素 = (255,255,255): 三通道和 510 仍得 255");
        check(cbad == 0,    "无任何像素值错误(奇数行未泄漏)");

        $display("========================================================");
        if (fail_cnt == 0) $display(" 结果: 全部 PASS  (fail_cnt=0)");
        else               $display(" 结果: 存在 %0d 处 FAIL", fail_cnt);
        $display("========================================================");
        $finish;
    end

endmodule
