//====================================================================
// tb_bmp_read_auto_file.v —— bmp_read_auto FAT32 化(file 接口)完整测试
//
// 覆盖(原 tb_bmp_read_auto.v 的容错用例全部迁移到 file 接口语义):
//   1. 上电 → file_start + 簇号(clu0) → 解析 54 字节头(9 项校验) → 读像素
//      → file_done → S_HOLD, bmp_error=0, img_no=1
//   2. key_trigger 切下一张 → clu1 → img_no=2
//   3. key_prev 上一张 → 回到 clu0 → img_no=1
//   4. 坏图(头 planes=0) → ERR_HEADER → 回 S_IDLE 跳过本张, 不粘死
//   5. 读卡死锁(file_done 不来) → 超时 → ERR_TIMEOUT → 重试 1 次 → 仍失败跳过
//   6. reload_req 原地重读当前图(图序号不变)
//   7. 轮播间隔 slide_interval(非法值忽略 + 合法值计时到切图)
//
// FAT32 化关键语义差异(相对旧扇区版):
//   · 找图由簇号表直接给出(clu0..5 + siz0..5), 不再扫扇区找 BM 魔数。
//   · 坏图 = 该簇号文件头 9 项校验不过(planes=0), 报 ERR_HEADER 回 S_IDLE。
//   · 卡死 = 该文件 streamer 不吐 file_done, 由 sd_timeout 兜住报 ERR_TIMEOUT。
//====================================================================
`timescale 1ns/1ps

module tb_bmp_read_auto_file;

    localparam CLK_PERIOD = 10;              // 100MHz -> 10ns
    localparam BMP_PIXEL_BYTES_SIM = 32'd120;  // 每帧 40 像素 = 120 字节(小子集)
    localparam FILE_LEN_SIM = 32'd174;         // 54 头 + 120 像素 = 174 字节

    reg         clk;
    reg         rst;
    reg         sd_init_done;
    reg         key_trigger;
    reg         key_prev;
    reg         slide_en;
    reg         write_req_ack;
    reg         reload_req;
    reg  [31:0] slide_interval;

    // 簇号表输入
    reg  [31:0] zone_cluster0, zone_cluster1, zone_cluster2;
    reg  [31:0] zone_cluster3, zone_cluster4, zone_cluster5;
    reg  [31:0] zone_size0, zone_size1, zone_size2;
    reg  [31:0] zone_size3, zone_size4, zone_size5;
    reg  [31:0] zone_max_img;
    reg         zone_load;

    wire [3:0]  state_code;
    wire        write_req;
    wire        file_start;
    wire [31:0] file_cluster;
    wire [31:0] file_len_out;
    reg         file_valid;
    reg  [7:0]  file_byte;
    reg         file_done;
    reg  [7:0]  file_error;
    wire        bmp_data_wr_en;
    wire [23:0] bmp_data;
    wire [7:0]  img_no;
    wire        img_busy;
    wire [3:0]  bmp_error;
    wire [1:0]  img_res;
    wire        img_v2x;

    bmp_read_auto #(
        .BMP_PIXEL_BYTES    (BMP_PIXEL_BYTES_SIM),
        .BMP_PIXEL_BYTES_1024(32'd480),
        .SLIDE_INTERVAL     (32'd10_000_000),
        .MIN_PERIOD_CYCLES  (32'd1000),     // 调小下限, 便于测小间隔切图
        .SD_READ_TIMEOUT_MS (16'd2),
        .CLK_FREQ_HZ        (32'd1_000_000),
        .MAX_RETRIES        (4'd1)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .ready          (),
        .sd_init_done   (sd_init_done),
        .key_trigger    (key_trigger),
        .key_prev       (key_prev),
        .slide_en       (slide_en),
        .slide_interval (slide_interval),
        .zone_start     (32'd0),
        .zone_wrap      (32'd0),
        .zone_max_img   (zone_max_img),
        .zone_load      (zone_load),
        .zone_cluster0  (zone_cluster0),
        .zone_cluster1  (zone_cluster1),
        .zone_cluster2  (zone_cluster2),
        .zone_cluster3  (zone_cluster3),
        .zone_cluster4  (zone_cluster4),
        .zone_cluster5  (zone_cluster5),
        .zone_size0     (zone_size0),
        .zone_size1     (zone_size1),
        .zone_size2     (zone_size2),
        .zone_size3     (zone_size3),
        .zone_size4     (zone_size4),
        .zone_size5     (zone_size5),
        .reload_req     (reload_req),
        .state_code     (state_code),
        .bmp_width      (16'd640),
        .write_req      (write_req),
        .write_req_ack  (write_req_ack),
        .file_start     (file_start),
        .file_cluster   (file_cluster),
        .file_len_out   (file_len_out),
        .file_valid     (file_valid),
        .file_byte      (file_byte),
        .file_done      (file_done),
        .file_error     (file_error),
        .bmp_data_wr_en (bmp_data_wr_en),
        .bmp_data       (bmp_data),
        .img_no         (img_no),
        .img_busy       (img_busy),
        .bmp_error      (bmp_error),
        .img_res        (img_res),
        .img_v2x        (img_v2x)
    );

    //====================================================================
    // 文件模型: 按簇号返回对应 BMP 文件内容
    //   clu 100 → 正常图(像素基址 0x10)
    //   clu 200 → 正常图(像素基址 0x40)
    //   clu 300 → 坏图(planes=0)
    //   clu 400 → 卡死图(头合法, 但不吐 file_done, 模拟读卡死锁)
    //====================================================================
    // 当前正在响应的簇号(由 file_start 捕获)
    reg [31:0] cur_clu_r;
    // 当前文件是否"卡死"(不吐 file_done)
    reg        cur_stall;

    task send_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            file_byte  = b;
            file_valid = 1'b1;
            @(negedge clk);
            file_valid = 1'b0;
        end
    endtask

    task gen_bmp_header;
        input [31:0] file_len;
        input [15:0] planes_val;
        begin
            send_byte("B");                // 0
            send_byte("M");                // 1
            send_byte(file_len[7:0]);       // 2..5: file_len 小端
            send_byte(file_len[15:8]);
            send_byte(file_len[23:16]);
            send_byte(file_len[31:24]);
            send_byte(8'd0);               // 6..9: 保留
            send_byte(8'd0);
            send_byte(8'd0);
            send_byte(8'd0);
            send_byte(8'd54);              // 10..13: pixel_offset = 54
            send_byte(8'd0);
            send_byte(8'd0);
            send_byte(8'd0);
            send_byte(8'd40);              // 14..17: DIB = 40
            send_byte(8'd0);
            send_byte(8'd0);
            send_byte(8'd0);
            send_byte(8'h80);              // 18..21: width = 640
            send_byte(8'h02);
            send_byte(8'd0);
            send_byte(8'd0);
            send_byte(8'hE0);              // 22..25: height = 480
            send_byte(8'h01);
            send_byte(8'd0);
            send_byte(8'd0);
            send_byte(planes_val[7:0]);     // 26..27: planes
            send_byte(planes_val[15:8]);
            send_byte(8'd24);              // 28..29: bit_cnt = 24
            send_byte(8'd0);
            send_byte(8'd0);               // 30..33: compression = 0
            send_byte(8'd0);
            send_byte(8'd0);
            send_byte(8'd0);
            begin : pad
                integer i;
                for (i = 34; i < 54; i = i + 1)
                    send_byte(8'd0);
            end
        end
    endtask

    // 吐一张正常图的完整文件(头 + 40 像素 + file_done)
    task feed_normal;
        input [7:0] base;
        integer j;
        begin
            gen_bmp_header(FILE_LEN_SIM, 16'd1);
            wait (write_req_ack == 1);
            @(posedge clk);
            for (j = 0; j < 40; j = j + 1) begin
                send_byte(base + j[7:0]);  // B
                send_byte(8'h20 + j[7:0]); // G
                send_byte(8'h30 + j[7:0]); // R
            end
            @(posedge clk);
            file_done = 1;
            @(posedge clk);
            file_done = 0;
        end
    endtask

    // 吐一张坏图(planes=0, 头校验必失败)
    task feed_bad;
        begin
            gen_bmp_header(FILE_LEN_SIM, 16'd0);   // planes=0 → 9 项校验失败
            // 坏图不发像素(头校验在 rd_cnt=54 就失败), 但需 file_done 让 streamer 语义完整
            @(posedge clk);
            file_done = 1;
            @(posedge clk);
            file_done = 0;
        end
    endtask

    integer pass_count;
    integer fail_count;
    integer k;
    integer stall_round;

    // 断言
    task chk;
        input cond;
        input [255:0] msg;
        begin
            if (cond) begin
                $display("[PASS] %0s", msg);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s", msg);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // 等待 file_start 并捕获簇号
    task wait_start;
        begin
            wait (file_start == 1);
            @(negedge clk);
            cur_clu_r  = file_cluster;
            cur_stall  = (file_cluster == 32'd400);   // 簇 400 = 卡死图
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        sd_init_done = 0;
        key_trigger = 0;
        key_prev = 0;
        slide_en = 0;
        reload_req = 0;
        slide_interval = 32'd10_000_000;
        zone_cluster0 = 32'd100;
        zone_cluster1 = 32'd200;
        zone_cluster2 = 32'd300;   // 坏图
        zone_cluster3 = 32'd400;   // 卡死图
        zone_cluster4 = 32'd0;
        zone_cluster5 = 32'd0;
        zone_size0 = FILE_LEN_SIM;
        zone_size1 = FILE_LEN_SIM;
        zone_size2 = FILE_LEN_SIM;
        zone_size3 = FILE_LEN_SIM;
        zone_size4 = 32'd0;
        zone_size5 = 32'd0;
        zone_max_img = 32'd4;
        zone_load = 0;
        file_valid = 0;
        file_byte = 0;
        file_done = 0;
        file_error = 0;
        cur_clu_r = 32'd0;
        cur_stall = 0;
        pass_count = 0;
        fail_count = 0;

        // 复位
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (3) @(posedge clk);

        // 加载簇号表(4 张: 100/200/300坏/400卡死)
        @(posedge clk);
        zone_load = 1;
        @(posedge clk);
        zone_load = 0;

        @(posedge clk);
        sd_init_done = 1;

        //======== 1. 上电读第 1 张(clu0=100) ========
        wait_start;
        chk(cur_clu_r == 32'd100, "1.1 第 1 张簇号=100");
        feed_normal(8'h10);
        wait (img_busy == 0);
        @(posedge clk);
        chk(bmp_error == 4'd0, "1.2 第 1 张整帧读完 bmp_error=0");
        chk(img_no == 8'd1,     "1.3 第 1 张 img_no=1");

        //======== 2. 切下一张(clu1=200) ========
        @(posedge clk);
        key_trigger = 1;
        @(posedge clk);
        key_trigger = 0;
        wait_start;
        chk(cur_clu_r == 32'd200, "2.1 切图后簇号=200");
        feed_normal(8'h40);
        wait (img_busy == 0);
        @(posedge clk);
        chk(img_no == 8'd2, "2.2 切图后 img_no=2");

        //======== 3. 上一张(clu1=200 回 clu0=100) ========
        @(posedge clk);
        key_prev = 1;
        @(posedge clk);
        key_prev = 0;
        wait_start;
        chk(cur_clu_r == 32'd100, "3.1 上一张簇号回到 100");
        feed_normal(8'h10);
        wait (img_busy == 0);
        @(posedge clk);
        chk(img_no == 8'd1, "3.2 上一张 img_no 回到 1");

        //======== 4. 坏图(clu0=300, planes=0) → ERR_HEADER 跳过 ========
        // 独立分区: [300坏, 200好] z_max=2。上电读图 1(坏图) → 跳过 → 读图 2(好图)。
        @(posedge clk);
        zone_cluster0 = 32'd300;   // 坏图
        zone_cluster1 = 32'd200;   // 正常图
        zone_max_img  = 32'd2;
        @(posedge clk); zone_load = 1; @(posedge clk); zone_load = 0;
        // zone_load 在 S_HOLD 应用 → 读坏图(300)
        wait_start;
        chk(cur_clu_r == 32'd300, "4.1 坏图簇号=300");
        feed_bad();                        // planes=0 头校验失败
        // 坏图报 ERR_HEADER 后 img_cnt+1 跳到下一张(200), 回 S_IDLE 读正常图
        // 观测: 下一次 file_start 的簇号应为 200(跳过坏图)
        wait_start;
        chk(cur_clu_r == 32'd200, "4.2 坏图跳过, 读到下一张簇号=200");
        feed_normal(8'h40);
        wait (img_busy == 0);
        @(posedge clk);
        chk(bmp_error == 4'd0, "4.3 正常图读完后 bmp_error 清除为 0");
        chk(img_no == 8'd2,     "4.4 坏图被跳过, 正常图 img_no=2");

        //======== 5. 卡死图(clu0=400) → 超时重试 → 跳过 ========
        // 独立分区: [400卡死, 100好] z_max=2。
        @(posedge clk);
        zone_cluster0 = 32'd400;   // 卡死图
        zone_cluster1 = 32'd100;   // 正常图
        zone_max_img  = 32'd2;
        @(posedge clk); zone_load = 1; @(posedge clk); zone_load = 0;
        wait_start;
        chk(cur_clu_r == 32'd400, "5.1 卡死图簇号=400");
        // 吐头(合法, 能被命中), 但不吐 file_done → 读卡死锁
        gen_bmp_header(FILE_LEN_SIM, 16'd1);
        // 不吐 file_done, 等超时(2ms@1MHz = 2000 周期)。超时后报 ERR_TIMEOUT,
        //   重试 1 次(MAX_RETRIES=1), 再失败则 img_cnt-1 回退跳过。
        // 重试时 bmp 会再次 file_start(仍读 400), 需再喂一次头(仍不吐 done)。
        stall_round = 0;
        while (stall_round < 2) begin
            wait (file_start == 1);
            @(negedge clk);
            gen_bmp_header(FILE_LEN_SIM, 16'd1);   // 重试再喂头, 仍不吐 done
            stall_round = stall_round + 1;
        end
        // 重试用尽后 img_cnt+1 跳过(回卷), 回 S_IDLE 读下一张(100)
        wait (img_busy == 0);
        @(posedge clk);
        chk(bmp_error == 4'd2, "5.2 卡死图报 bmp_error=2(ERR_TIMEOUT)");
        // 卡死图跳过 → 读到下一张正常图(100)
        wait_start;
        chk(cur_clu_r == 32'd100, "5.3 卡死图跳过后读到下一张簇号=100");
        feed_normal(8'h10);
        wait (img_busy == 0);
        @(posedge clk);
        chk(img_no == 8'd2, "5.4 卡死图跳过后正常图 img_no=2");

        //======== 6. reload_req 原地重读(图序号不变) ========
        // 独立分区: [100好] z_max=1。
        @(posedge clk);
        zone_cluster0 = 32'd100; zone_max_img = 32'd1;
        @(posedge clk); zone_load = 1; @(posedge clk); zone_load = 0;
        wait_start; feed_normal(8'h10);
        wait (img_busy == 0);
        @(posedge clk);
        chk(img_no == 8'd1, "6.1 重载分区后 img_no=1");
        // reload_req 原地重读同一张(簇号不变, 图序号不变)
        @(posedge clk); reload_req = 1; @(posedge clk); reload_req = 0;
        wait_start;
        chk(cur_clu_r == 32'd100, "6.2 reload 重读簇号仍=100");
        feed_normal(8'h10);
        wait (img_busy == 0);
        @(posedge clk);
        chk(img_no == 8'd1, "6.3 reload 后 img_no 仍=1");

        //======== 7. 轮播间隔 slide_interval ========
        // 分区 [100, 200] z_max=2。
        @(posedge clk);
        zone_cluster0 = 32'd100; zone_cluster1 = 32'd200; zone_max_img = 32'd2;
        @(posedge clk); zone_load = 1; @(posedge clk); zone_load = 0;
        wait_start; feed_normal(8'h10);
        wait (img_busy == 0);
        @(posedge clk);
        chk(img_no == 8'd1, "7.1 前置: 图 1 保持");
        // (a) 非法值 0 → 忽略, 保持上一次有效间隔
        slide_en = 1;
        slide_interval = 32'd0;
        repeat (500) @(posedge clk);
        chk(img_busy == 0 && img_no == 8'd1, "7.2 slide_interval=0 被忽略(不疯狂切图)");
        // (b) 合法小间隔(5000 周期) → 计时到切图
        slide_interval = 32'd5000;
        wait (img_busy == 1);   // 开始切图(进 S_IDLE/S_FIND)
        wait_start;
        feed_normal(8'h40);
        wait (img_busy == 0);
        @(posedge clk);
        chk(img_no == 8'd2, "7.3 小间隔计时到自动切到图 2");

        $display("===== 汇总: PASS=%0d FAIL=%0d =====", pass_count, fail_count);
        if (fail_count == 0) $display("RESULT: PASS");
        else                 $display("RESULT: FAIL");
        $finish;
    end

    always #(CLK_PERIOD/2) clk = ~clk;

    // 自动应答写帧请求: write_req 上升沿后单拍 ack
    reg wr_req_d;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_req_d <= 0;
            write_req_ack <= 0;
        end else begin
            wr_req_d <= write_req;
            write_req_ack <= write_req && !wr_req_d;
        end
    end

    // 总超时兜底
    initial begin
        #50_000_000;
        $display("===== [TIMEOUT] 仿真超时, PASS=%0d FAIL=%0d =====", pass_count, fail_count);
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
