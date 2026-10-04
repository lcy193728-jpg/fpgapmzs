//====================================================================
// tb_fat32_scanner.v —— fat32_volume_scanner 单元测试
//
// 验证目标:
//   1. 扫描器能正确解析无 MBR(超级软盘)FAT32 镜像的 BPB
//   2. 能扫出根目录里 12 个素材文件的起始簇号 + 大小
//   3. resource_valid 位与 resourceX_cluster/size 对应正确
//
// 构造的 FAT32 镜像(最小, 无 MBR, 引导扇区在 LBA0):
//   LBA0   引导扇区(BPB: 512B/扇区, 1 扇区/簇, reserved=1, fat_count=1,
//          root_cluster=2, fat_sectors=1, total_sectors=1024)
//   LBA1   FAT 表(簇0/1 保留, 其余标记)
//   LBA2   根目录第一扇区(簇2), 含 12 个素材目录项
//   数据区: 簇3 起放各文件数据(本 tb 只验扫描器, 不读数据)
//====================================================================
`timescale 1ns/1ps

module tb_fat32_scanner;

    reg         clk;
    reg         rst_n;
    reg         scan_start;
    wire        scan_busy;
    wire        scan_done;
    wire [7:0]  fs_error;
    wire [31:0] partition_lba;
    wire [7:0]  sectors_per_cluster;
    wire [2:0]  sectors_per_cluster_shift;
    wire [31:0] fat_start_lba;
    wire [31:0] data_start_lba;
    wire [31:0] max_cluster;
    wire [11:0] resource_valid;
    wire [31:0] r0c, r1c, r2c, r3c, r4c, r5c, r6c, r7c, r8c, r9c, r10c, r11c;
    wire [31:0] r0s, r1s, r2s, r3s, r4s, r5s, r6s, r7s, r8s, r9s, r10s, r11s;

    // 扇区读接口(扫描器侧) —— 连到模拟 SD 卡
    wire        sector_req;
    wire [31:0] sector_lba;
    wire        sector_busy;
    wire        sector_valid;
    wire [7:0]  sector_byte;
    wire [8:0]  sector_byte_index;
    wire        sector_done;
    wire [7:0]  sector_error;

    fat32_volume_scanner dut(
        .clk(clk), .rst_n(rst_n), .scan_start(scan_start),
        .scan_busy(scan_busy), .scan_done(scan_done), .fs_error(fs_error),
        .partition_lba(partition_lba), .sectors_per_cluster(sectors_per_cluster),
        .sectors_per_cluster_shift(sectors_per_cluster_shift),
        .fat_start_lba(fat_start_lba), .data_start_lba(data_start_lba),
        .max_cluster(max_cluster),
        .resource_valid(resource_valid),
        .resource0_cluster(r0c), .resource1_cluster(r1c), .resource2_cluster(r2c),
        .resource3_cluster(r3c), .resource4_cluster(r4c), .resource5_cluster(r5c),
        .resource6_cluster(r6c), .resource7_cluster(r7c), .resource8_cluster(r8c),
        .resource9_cluster(r9c), .resource10_cluster(r10c), .resource11_cluster(r11c),
        .resource0_size(r0s), .resource1_size(r1s), .resource2_size(r2s),
        .resource3_size(r3s), .resource4_size(r4s), .resource5_size(r5s),
        .resource6_size(r6s), .resource7_size(r7s), .resource8_size(r8s),
        .resource9_size(r9s), .resource10_size(r10s), .resource11_size(r11s),
        .sector_req(sector_req), .sector_lba(sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
        .sector_done(sector_done), .sector_error(sector_error)
    );

    //====================================================================
    // 模拟 SD 卡: 内存里放 FAT32 镜像, 按 sector 请求逐字节回读
    //====================================================================
    reg [7:0] disk [0:1023][0:511];   // 1024 扇区 × 512 字节
    integer   i, j;

    // 模拟读状态机(与 sd_sector_adapter 交互): 见 sector_req 电平触发
    reg [31:0] cur_lba;
    reg [9:0]  byte_idx;    // 10bit: 0~511 数据, 512=完成标记
    reg        reading;

    assign sector_busy  = reading;
    assign sector_valid = reading && (byte_idx < 512);
    assign sector_byte  = reading ? disk[cur_lba][byte_idx] : 8'h00;
    assign sector_byte_index = byte_idx[8:0];
    assign sector_done  = reading && (byte_idx == 512);
    assign sector_error = 8'h00;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reading <= 0;
            cur_lba <= 0;
            byte_idx <= 0;
        end else begin
            if (sector_req && !reading) begin
                reading <= 1;
                cur_lba <= sector_lba;
                byte_idx <= 0;
            end else if (reading && byte_idx < 512) begin
                byte_idx <= byte_idx + 1;
            end else if (reading && byte_idx == 512) begin
                reading <= 0;
            end
        end
    end

    //====================================================================
    // 构造 FAT32 镜像
    //====================================================================
    // 目录项 helper: 填 32 字节目录项到 disk[sec][off]
    task write_dir_entry;
        input [31:0] sec;
        input [4:0]  off;          // 目录项在扇区内的 32 字节对齐偏移(0..15)
        input [7:0]  n0,n1,n2,n3,n4,n5,n6,n7;  // 8.3 主名(8 字节, 大写)
        input [7:0]  e0,e1,e2;                 // 扩展名(3 字节)
        input [31:0] cluster;                  // 起始簇号
        input [31:0] size;                     // 文件大小
        integer base;
        begin
            base = off * 32;
            disk[sec][base+0]  = n0; disk[sec][base+1]  = n1;
            disk[sec][base+2]  = n2; disk[sec][base+3]  = n3;
            disk[sec][base+4]  = n4; disk[sec][base+5]  = n5;
            disk[sec][base+6]  = n6; disk[sec][base+7]  = n7;
            disk[sec][base+8]  = e0; disk[sec][base+9]  = e1; disk[sec][base+10] = e2;
            disk[sec][base+11] = 8'h20;   // 属性: 归档普通文件
            // FAT32 目录项簇号(little-endian): offset20~21=高16位, offset26~27=低16位
            disk[sec][base+20] = cluster[23:16];  // 高16位低字节
            disk[sec][base+21] = cluster[31:24];  // 高16位高字节
            disk[sec][base+26] = cluster[7:0];    // 低16位低字节
            disk[sec][base+27] = cluster[15:8];   // 低16位高字节
            disk[sec][base+28] = size[7:0];
            disk[sec][base+29] = size[15:8];
            disk[sec][base+30] = size[23:16];
            disk[sec][base+31] = size[31:24];
        end
    endtask

    task build_image;
        begin
            // 全盘清零
            for (i = 0; i < 1024; i = i + 1)
                for (j = 0; j < 512; j = j + 1)
                    disk[i][j] = 8'h00;

            // ---- LBA0: 引导扇区(BPB) ----
            disk[0][0]   = 8'hEB;   // 跳转指令(直接引导, 无 MBR)
            disk[0][1]   = 8'h3C;
            disk[0][2]   = 8'h90;
            // 偏移 3~10: OEM 名(忽略)
            // BPB 关键字段:
            // offset 11: bytes_per_sector = 512 (小端)
            disk[0][11]  = 8'h00; disk[0][12] = 8'h02;
            // offset 13: sectors_per_cluster = 1
            disk[0][13]  = 8'h01;
            // offset 14: reserved_sectors = 1
            disk[0][14]  = 8'h01; disk[0][15] = 8'h00;
            // offset 16: fat_count = 1
            disk[0][16]  = 8'h01;
            // offset 17~18: root_entries = 0 (FAT32)
            disk[0][17]  = 8'h00; disk[0][18] = 8'h00;
            // offset 22~23: sectors_per_fat16 = 0 (FAT32)
            disk[0][22]  = 8'h00; disk[0][23] = 8'h00;
            // offset 32: total_sectors = 1024 (小端)
            disk[0][32]  = 8'h00; disk[0][33] = 8'h04; disk[0][34] = 8'h00; disk[0][35] = 8'h00;
            // offset 36: fat_sectors = 1 (小端)
            disk[0][36]  = 8'h01; disk[0][37] = 8'h00; disk[0][38] = 8'h00; disk[0][39] = 8'h00;
            // offset 44: root_cluster = 2 (小端)
            disk[0][44]  = 8'h02; disk[0][45] = 8'h00; disk[0][46] = 8'h00; disk[0][47] = 8'h00;
            // 引导签名
            disk[0][510] = 8'h55; disk[0][511] = 8'hAA;

            // ---- LBA1: FAT 表(簇0/1 保留) ----
            disk[1][0] = 8'hF8; disk[1][1] = 8'hFF; disk[1][2] = 8'hFF; disk[1][3] = 8'h0F;
            disk[1][4] = 8'hFF; disk[1][5] = 8'hFF; disk[1][6] = 8'hFF; disk[1][7] = 8'h0F;

            // ---- LBA2: 根目录第一扇区(簇2), 12 个素材目录项 ----
            // 资源号 → 文件名 → 起始簇号 → 大小
            // 0:  1_MEET.BMP  → 簇 3  → 921654
            write_dir_entry(2, 0, "1","_","M","E","E","T"," "," ", "B","M","P", 3, 921654);
            // 1:  2_QUIZ.BMP  → 簇 182 → 921654
            write_dir_entry(2, 1, "2","_","Q","U","I","Z"," "," ", "B","M","P", 182, 921654);
            // 2:  3_EXTRA.BMP → 簇 361 → 921654
            write_dir_entry(2, 2, "3","_","E","X","T","R","A"," ", "B","M","P", 361, 921654);
            // 3:  4_EXTRA.BMP → 簇 540 → 921654
            write_dir_entry(2, 3, "4","_","E","X","T","R","A"," ", "B","M","P", 540, 921654);
            // 4:  W1_320A.BMP → 簇 719 → 230454
            write_dir_entry(2, 4, "W","1","_","3","2","0","A"," ", "B","M","P", 719, 230454);
            // 5:  W2_640A.BMP → 簇 720 → 921654
            write_dir_entry(2, 5, "W","2","_","6","4","0","A"," ", "B","M","P", 720, 921654);
            // 6:  W3_1024A.BMP→ 簇 721 → 2359350
            write_dir_entry(2, 6, "W","3","_","1","0","2","4","A", "B","M","P", 721, 2359350);
            // 7:  W4_320B.BMP → 簇 722 → 230454
            write_dir_entry(2, 7, "W","4","_","3","2","0","B"," ", "B","M","P", 722, 230454);
            // 8:  W5_640B.BMP → 簇 723 → 921654
            write_dir_entry(2, 8, "W","5","_","6","4","0","B"," ", "B","M","P", 723, 921654);
            // 9:  W6_1024B.BMP→ 簇 724 → 2359350
            write_dir_entry(2, 9, "W","6","_","1","0","2","4","B", "B","M","P", 724, 2359350);
            // 10: MTG1.CFG    → 簇 725 → 1272
            write_dir_entry(2, 10, "M","T","G","1"," "," "," "," ", "C","F","G", 725, 1272);
            // 11: WEL.BIN     → 簇 726 → 67108864 (64MB 音乐)
            write_dir_entry(2, 11, "W","E","L"," "," "," "," "," ", "B","I","N", 726, 67108864);
        end
    endtask

    //====================================================================
    // 测试主流程
    //====================================================================
    integer pass_cnt;
    integer fail_cnt;
    reg [31:0] expected_c [0:11];
    reg [31:0] expected_s [0:11];

    initial begin
        // 期望值
        expected_c[0]=3;   expected_s[0]=921654;
        expected_c[1]=182; expected_s[1]=921654;
        expected_c[2]=361; expected_s[2]=921654;
        expected_c[3]=540; expected_s[3]=921654;
        expected_c[4]=719; expected_s[4]=230454;
        expected_c[5]=720; expected_s[5]=921654;
        expected_c[6]=721; expected_s[6]=2359350;
        expected_c[7]=722; expected_s[7]=230454;
        expected_c[8]=723; expected_s[8]=921654;
        expected_c[9]=724; expected_s[9]=2359350;
        expected_c[10]=725; expected_s[10]=1272;
        expected_c[11]=726; expected_s[11]=67108864;

        build_image();

        clk = 0; rst_n = 0; scan_start = 0;
        pass_cnt = 0; fail_cnt = 0;

        #100 rst_n = 1;
        #50 scan_start = 1;
        #20 scan_start = 0;

        // 等扫描完成(带超时保护, 最多 50000 拍)
        begin : wait_done
            integer t;
            for (t = 0; t < 5000; t = t + 1) begin
                @(posedge clk);
                if (t < 40 || t % 100 == 0)
                    $display("t=%0d state=%d req=%d busy=%d lba=%d done=%d valid=%d idx=%d",
                        t, dut.state, sector_req, sector_busy, sector_lba,
                        sector_done, sector_valid, sector_byte_index);
                if (scan_done == 1) disable wait_done;
            end
            $display("[TIMEOUT] scan 未在 5000 拍内完成");
            $finish;
        end
        #20;

        // ---- 校验文件系统参数 ----
        $display("===== 扫描结果 =====");
        $display("fs_error       = %h (期望 00)", fs_error);
        $display("partition_lba  = %d (期望 0)", partition_lba);
        $display("sectors_per_cluster = %d (期望 1)", sectors_per_cluster);
        $display("fat_start_lba  = %d (期望 1)", fat_start_lba);
        $display("data_start_lba = %d (期望 2)", data_start_lba);
        $display("max_cluster    = %d", max_cluster);
        $display("resource_valid = %h (期望 fff)", resource_valid);

        if (fs_error == 8'h00)        begin pass_cnt = pass_cnt + 1; $display("[PASS] fs_error=0"); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] fs_error=%h", fs_error); end
        if (partition_lba == 0)       begin pass_cnt = pass_cnt + 1; $display("[PASS] partition_lba=0"); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] partition_lba=%d", partition_lba); end
        if (sectors_per_cluster == 1) begin pass_cnt = pass_cnt + 1; $display("[PASS] spc=1"); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] spc=%d", sectors_per_cluster); end
        if (fat_start_lba == 1)       begin pass_cnt = pass_cnt + 1; $display("[PASS] fat_start=1"); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] fat_start=%d", fat_start_lba); end
        if (data_start_lba == 2)      begin pass_cnt = pass_cnt + 1; $display("[PASS] data_start=2"); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] data_start=%d", data_start_lba); end
        if (resource_valid == 12'hfff) begin pass_cnt = pass_cnt + 1; $display("[PASS] resource_valid=fff"); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] resource_valid=%h", resource_valid); end

        // ---- 校验 12 个资源的簇号 + 大小 ----
        if (r0c == expected_c[0] && r0s == expected_s[0]) begin pass_cnt = pass_cnt + 1; $display("[PASS] r0=1_MEET cluster=%d size=%d", r0c, r0s); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] r0 cluster=%d(期望%d) size=%d(期望%d)", r0c, expected_c[0], r0s, expected_s[0]); end
        if (r1c == expected_c[1] && r1s == expected_s[1]) begin pass_cnt = pass_cnt + 1; $display("[PASS] r1=2_QUIZ cluster=%d size=%d", r1c, r1s); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] r1 cluster=%d(期望%d)", r1c, expected_c[1]); end
        if (r2c == expected_c[2] && r2s == expected_s[2]) begin pass_cnt = pass_cnt + 1; $display("[PASS] r2=3_EXTRA cluster=%d", r2c); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] r2 cluster=%d(期望%d)", r2c, expected_c[2]); end
        if (r3c == expected_c[3] && r3s == expected_s[3]) begin pass_cnt = pass_cnt + 1; $display("[PASS] r3=4_EXTRA cluster=%d", r3c); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] r3 cluster=%d(期望%d)", r3c, expected_c[3]); end
        if (r4c == expected_c[4] && r4s == expected_s[4]) begin pass_cnt = pass_cnt + 1; $display("[PASS] r4=W1_320A cluster=%d size=%d", r4c, r4s); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] r4 cluster=%d(期望%d)", r4c, expected_c[4]); end
        if (r5c == expected_c[5] && r5s == expected_s[5]) begin pass_cnt = pass_cnt + 1; $display("[PASS] r5=W2_640A cluster=%d", r5c); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] r5 cluster=%d(期望%d)", r5c, expected_c[5]); end
        if (r6c == expected_c[6] && r6s == expected_s[6]) begin pass_cnt = pass_cnt + 1; $display("[PASS] r6=W3_1024A cluster=%d size=%d", r6c, r6s); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] r6 cluster=%d(期望%d)", r6c, expected_c[6]); end
        if (r7c == expected_c[7] && r7s == expected_s[7]) begin pass_cnt = pass_cnt + 1; $display("[PASS] r7=W4_320B cluster=%d", r7c); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] r7 cluster=%d(期望%d)", r7c, expected_c[7]); end
        if (r8c == expected_c[8] && r8s == expected_s[8]) begin pass_cnt = pass_cnt + 1; $display("[PASS] r8=W5_640B cluster=%d", r8c); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] r8 cluster=%d(期望%d)", r8c, expected_c[8]); end
        if (r9c == expected_c[9] && r9s == expected_s[9]) begin pass_cnt = pass_cnt + 1; $display("[PASS] r9=W6_1024B cluster=%d", r9c); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] r9 cluster=%d(期望%d)", r9c, expected_c[9]); end
        if (r10c == expected_c[10] && r10s == expected_s[10]) begin pass_cnt = pass_cnt + 1; $display("[PASS] r10=MTG1.CFG cluster=%d size=%d", r10c, r10s); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] r10 cluster=%d(期望%d)", r10c, expected_c[10]); end
        if (r11c == expected_c[11] && r11s == expected_s[11]) begin pass_cnt = pass_cnt + 1; $display("[PASS] r11=WEL.BIN cluster=%d size=%d", r11c, r11s); end
        else begin fail_cnt = fail_cnt + 1; $display("[FAIL] r11 cluster=%d(期望%d)", r11c, expected_c[11]); end

        $display("===== 汇总: PASS=%d FAIL=%d =====", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");

        $finish;
    end

    // 时钟: 10ns 周期(100MHz)
    always #5 clk = ~clk;

endmodule
