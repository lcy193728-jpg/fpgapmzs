//====================================================================
// tb_fat32_streamer.v —— fat32_file_streamer 单元测试
//
// 验证目标: FAT 链遍历正确性(碎片化文件)
//   构造一个"碎片化"文件: 起始簇=3, FAT 链 3→7→5(EOF),
//   每簇 1 扇区(512B), 文件大小 1200 字节(跨 3 个簇)。
//   验证流读器按 3→7→5 顺序输出正确字节流, 无花屏式串簇。
//
// FAT32 布局(spc=1, 1扇区/簇):
//   fat_start_lba=1, data_start_lba=2
//   簇3→扇区2, 簇7→扇区6, 簇5→扇区4
//   FAT 表: FAT[3]=7, FAT[7]=5, FAT[5]=EOF(0x0FFFFFFF)
//====================================================================
`timescale 1ns/1ps

module tb_fat32_streamer;

    reg         clk;
    reg         rst_n;
    reg         file_start;
    reg  [31:0] first_cluster;
    reg  [31:0] file_size;
    reg  [7:0]  sectors_per_cluster;
    reg  [2:0]  sectors_per_cluster_shift;
    reg  [31:0] fat_start_lba;
    reg  [31:0] data_start_lba;
    reg  [31:0] max_cluster;
    wire        file_busy;
    wire        file_done;
    wire        file_valid;
    wire [7:0]  file_byte;
    wire [31:0] file_byte_offset;
    wire [7:0]  fs_error;

    wire        sector_req;
    wire [31:0] sector_lba;
    wire        sector_busy;
    wire        sector_valid;
    wire [7:0]  sector_byte;
    wire [8:0]  sector_byte_index;
    wire        sector_done;
    wire [7:0]  sector_error;

    fat32_file_streamer dut(
        .clk(clk), .rst_n(rst_n), .file_start(file_start),
        .first_cluster(first_cluster), .file_size(file_size),
        .sectors_per_cluster(sectors_per_cluster),
        .sectors_per_cluster_shift(sectors_per_cluster_shift),
        .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .file_busy(file_busy), .file_done(file_done),
        .file_valid(file_valid), .file_byte(file_byte),
        .file_byte_offset(file_byte_offset), .fs_error(fs_error),
        .sector_req(sector_req), .sector_lba(sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
        .sector_done(sector_done), .sector_error(sector_error)
    );

    //====================================================================
    // 模拟 SD 卡
    //====================================================================
    reg [7:0] disk [0:15][0:511];
    integer   i, j;
    reg [31:0] cur_lba;
    reg [9:0]  byte_idx;
    reg        reading;

    assign sector_busy  = reading;
    assign sector_valid = reading && (byte_idx < 512);
    assign sector_byte  = reading ? disk[cur_lba][byte_idx] : 8'h00;
    assign sector_byte_index = byte_idx[8:0];
    assign sector_done  = reading && (byte_idx == 512);
    assign sector_error = 8'h00;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reading <= 0; cur_lba <= 0; byte_idx <= 0;
        end else begin
            if (sector_req && !reading) begin
                reading <= 1; cur_lba <= sector_lba; byte_idx <= 0;
            end else if (reading && byte_idx < 512) begin
                byte_idx <= byte_idx + 1;
            end else if (reading && byte_idx == 512) begin
                reading <= 0;
            end
        end
    end

    //====================================================================
    // 构造 FAT32 数据区 + FAT 表(碎片化文件: 3→7→5→EOF)
    //====================================================================
    // 文件内容约定: 扇区 N 的每字节 = 该簇号(便于验证读取顺序)
    //   簇3(扇区2) → 全 0x33
    //   簇7(扇区6) → 全 0x77
    //   簇5(扇区4) → 全 0x55
    // 文件大小 1200 字节 = 簇3(512) + 簇7(512) + 簇5(176 字节)
    task build_image;
        integer k;
        begin
            for (i = 0; i < 16; i = i + 1)
                for (j = 0; j < 512; j = j + 1)
                    disk[i][j] = 8'h00;

            // 数据区: 簇N → 扇区 = data_start_lba + (N-2)*spc = 2 + (N-2)
            //   簇3 → 扇区3 (0x33), 簇7 → 扇区7 (0x77), 簇5 → 扇区5 (0x55)
            for (k = 0; k < 512; k = k + 1) begin
                disk[3][k] = 8'h33;   // 簇3
                disk[7][k] = 8'h77;   // 簇7
                disk[5][k] = 8'h55;   // 簇5
            end

            // FAT 表在扇区1(每扇区128条目×4字节):
            //   FAT[3]=7 → offset 12 (3*4)
            //   FAT[7]=5 → offset 28 (7*4)
            //   FAT[5]=EOF(0x0FFFFFFF) → offset 20 (5*4)
            disk[1][12] = 8'h07; disk[1][13] = 8'h00; disk[1][14] = 8'h00; disk[1][15] = 8'h00; // FAT[3]=7
            disk[1][28] = 8'h05; disk[1][29] = 8'h00; disk[1][30] = 8'h00; disk[1][31] = 8'h00; // FAT[7]=5
            disk[1][20] = 8'hFF; disk[1][21] = 8'hFF; disk[1][22] = 8'hFF; disk[1][23] = 8'h0F; // FAT[5]=EOF
        end
    endtask

    //====================================================================
    // 测试: 记录输出字节流, 验证顺序
    //====================================================================
    reg [7:0]  out_buf [0:1199];   // 期望 1200 字节
    integer    out_cnt;
    integer    err_cnt;
    reg [7:0]  expected_byte;

    initial begin
        build_image();
        clk = 0; rst_n = 0;
        file_start = 0;
        first_cluster = 3;
        file_size = 1200;
        sectors_per_cluster = 1;
        sectors_per_cluster_shift = 0;   // log2(1) = 0
        fat_start_lba = 1;
        data_start_lba = 2;
        max_cluster = 100;
        out_cnt = 0;
        err_cnt = 0;

        #100 rst_n = 1;
        #30 file_start = 1;
        #20 file_start = 0;

        // 收集输出字节直到 file_done
        begin : collect
            integer t;
            for (t = 0; t < 50000; t = t + 1) begin
                @(posedge clk);
                if (file_valid) begin
                    if (out_cnt < 1200) begin
                        out_buf[out_cnt] = file_byte;
                        out_cnt = out_cnt + 1;
                    end
                end
                if (file_done) disable collect;
            end
            $display("[TIMEOUT] file 读取未完成");
            $finish;
        end
        #20;

        // ---- 校验 ----
        $display("===== 流读器结果 =====");
        $display("fs_error = %h (期望 00)", fs_error);
        $display("输出字节数 = %d (期望 1200)", out_cnt);

        if (fs_error == 8'h00) $display("[PASS] fs_error=0"); else begin err_cnt=err_cnt+1; $display("[FAIL] fs_error=%h", fs_error); end
        if (out_cnt == 1200) $display("[PASS] 字节数=1200"); else begin err_cnt=err_cnt+1; $display("[FAIL] 字节数=%d", out_cnt); end

        // 逐字节校验顺序: 前512字节=0x33, 中512=0x77, 后176=0x55
        begin : check
            integer k;
            integer wrong;
            wrong = 0;
            for (k = 0; k < 1200; k = k + 1) begin
                if (k < 512)      expected_byte = 8'h33;
                else if (k < 1024) expected_byte = 8'h77;
                else              expected_byte = 8'h55;
                if (out_buf[k] !== expected_byte) begin
                    if (wrong < 10) $display("  [错] offset=%d 读出=%h 期望=%h", k, out_buf[k], expected_byte);
                    wrong = wrong + 1;
                end
            end
            if (wrong == 0) $display("[PASS] 全部 %d 字节顺序正确(FAT链 3→7→5)", out_cnt);
            else begin err_cnt = err_cnt + 1; $display("[FAIL] %d 字节错误", wrong); end
        end

        $display("===== 汇总: err=%d =====", err_cnt);
        if (err_cnt == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
        $finish;
    end

    always #5 clk = ~clk;

endmodule
