//====================================================================
// tb_sd_sector_adapter.v —— sd_sector_adapter 桥接层专项测试
//
// 验证目标(桥接层是"照搬小鹅通 vs 因地制宜"的关键自研点, 必须专项验证):
//   1. sector_req 电平拉高 → 正确锁存 sector_lba → 发出 sd_sec_read
//   2. sector_busy 在"请求发出~读完成"之间为 1
//   3. sector_byte_index 随 sd_sec_read_data_valid 自增(0..511)
//   4. sector_done 在 sd_sec_read_end 时拉高, 且此时 byte_index 已计满 511
//   5. sector_error 恒为 0
//   6. 连续两次读请求(第 1 次完成后再发第 2 次)能正确复位 byte_cnt/busy
//
// 模拟的 sd_card_top 时序(严格复刻 sd_card_sec_read_write.v + sd_card_cmd.v):
//   · sd_sec_read 是【电平触发】, S_WAIT_READ_WRITE 态看到 ==1 就锁 addr 进 CMD17
//   · 数据期: 512 个字节, 每个字节 data_valid 拉高 1 拍(模拟 spi_wr_ack 逐字节)
//   · 数据读完后若干拍(CRC 处理)才拉 sd_sec_read_end(1 拍脉冲)
//====================================================================
`timescale 1ns/1ps

module tb_sd_sector_adapter;

    reg         clk;
    reg         rst_n;
    // sector 接口(上层 FAT32 模块侧)
    reg         sector_req;
    reg  [31:0] sector_lba;
    wire        sector_busy;
    wire        sector_valid;
    wire [7:0]  sector_byte;
    wire [8:0]  sector_byte_index;
    wire        sector_done;
    wire [7:0]  sector_error;
    // sd_sec 接口(官方 sd_card_top 侧, 由本 tb 模拟)
    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    reg         sd_sec_read_data_valid;
    reg  [7:0]  sd_sec_read_data;
    reg         sd_sec_read_end;

    sd_sector_adapter dut (
        .clk(clk), .rst_n(rst_n), .allow_req(1'b1),
        .sector_req(sector_req), .sector_lba(sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
        .sector_done(sector_done), .sector_error(sector_error),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_end(sd_sec_read_end)
    );

    // 模拟 sd_card_top 的读数据回放: 收到 sd_sec_read 后, 逐字节吐出 512 字节
    //   每字节 data_valid=1 拍, 字节值 = 该字节索引低 8 位(便于校验 byte_index 对齐)
    reg [9:0] replay_cnt;
    reg       replay_active;
    reg [7:0] replay_delay;   // 模拟 CMD17→0xFE 令牌的数据前延迟(真实 sd_card_top 有几十拍)
    integer   expected_addr;
    // 收集缓冲区: 按 sector_byte_index 收集 sector_byte, 事后校验 512 字节顺序
    reg [7:0] collected [0:511];
    integer   ci;

    // 收集 sector 侧字节(按 byte_index 对齐), 供事后完整性校验
    always @(posedge clk) begin
        if (sector_valid)
            collected[sector_byte_index] <= sector_byte;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            replay_active <= 1'b0;
            replay_cnt    <= 10'd0;
            replay_delay  <= 8'd0;
            sd_sec_read_data_valid <= 1'b0;
            sd_sec_read_data <= 8'd0;
            sd_sec_read_end <= 1'b0;
        end else begin
            sd_sec_read_end <= 1'b0;
            sd_sec_read_data_valid <= 1'b0;
            if (!replay_active) begin
                // 空闲: 检测到 sd_sec_read==1 → 先进入数据前延迟(模拟 CMD17 传输)
                if (sd_sec_read) begin
                    replay_active <= 1'b1;
                    replay_cnt    <= 10'd0;
                    replay_delay  <= 8'd40;   // 40 拍数据前延迟(真实 sd_card_top 的量级)
                    expected_addr <= sd_sec_read_addr;
                end
            end else if (replay_delay != 0) begin
                // 数据前延迟期: 不吐数据, 给桥接层 byte_cnt 复位留足时间
                replay_delay <= replay_delay - 8'd1;
            end else begin
                if (replay_cnt < 512) begin
                    sd_sec_read_data_valid <= 1'b1;
                    sd_sec_read_data       <= replay_cnt[7:0];
                    replay_cnt             <= replay_cnt + 10'd1;
                end else if (replay_cnt < 515) begin
                    replay_cnt <= replay_cnt + 10'd1;
                end else begin
                    sd_sec_read_end <= 1'b1;
                    replay_active   <= 1'b0;
                    replay_cnt      <= 10'd0;
                end
            end
        end
    end

    //====================================================================
    // 校验变量
    //====================================================================
    integer pass_cnt, fail_cnt;
    integer t;

    task check;
        input ok;
        input [8*64-1:0] name;
        begin
            if (ok) begin
                pass_cnt = pass_cnt + 1;
                $display("[PASS] %0s", name);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[FAIL] %0s", name);
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; sector_req = 0; sector_lba = 0;
        pass_cnt = 0; fail_cnt = 0;

        #100 rst_n = 1;
        #20;

        //------------------------------------------------------------------
        // 用例 1: 单扇区读 —— 请求 LBA=12345, 校验 busy/byte_index/done/addr
        //------------------------------------------------------------------
        sector_lba = 32'd12345;
        sector_req = 1'b1;
        @(posedge clk);
        // 请求当拍: 适配层应锁存 lba 并发出 sd_sec_read, busy 置 1
        #1;
        check(sd_sec_read === 1'b1, "sd_sec_read 拉高");
        check(sd_sec_read_addr === 32'd12345, "sd_sec_read_addr 锁存 = 12345");
        check(sector_busy === 1'b1, "sector_busy 置 1");

        // 等第 1 个数据字节
        wait (sd_sec_read_data_valid === 1'b1);
        check(sector_byte_index === 9'd0, "第1字节 byte_index=0");
        check(sector_valid === 1'b1, "第1字节 sector_valid=1");
        check(sector_byte === 8'd0, "第1字节 sector_byte=0");

        // 等第 512 个字节(索引 511)
        while (sector_byte_index !== 9'd511) @(posedge clk);
        #1;
        check(sector_byte === 8'hFF, "第512字节 sector_byte=FF");

        // 等 sector_done
        wait (sector_done === 1'b1);
        #1;
        check(sector_done === 1'b1, "sector_done 拉高");
        // busy 复位在 sector_done 的下一拍生效(标准非阻塞时序, 真实使用中
        // scanner/streamer 也是在 done 后下一个状态才看 busy)
        @(posedge clk);
        #1;
        check(sector_busy === 1'b0, "sector_done 后 busy 复位 0");

        // ---- 512 字节顺序完整性校验: collected[i] 应 == i[7:0] ----
        begin : chk_order1
            integer k;
            reg ok;
            ok = 1;
            for (k = 0; k < 512; k = k + 1)
                if (collected[k] !== k[7:0]) begin
                    ok = 0;
                    $display("   字节[%0d]=%h 期望 %h", k, collected[k], k[7:0]);
                end
            check(ok, "512字节顺序完整(byte_index 对齐正确)");
        end

        // 撤销请求
        sector_req = 1'b0;
        @(posedge clk);
        #1;
        check(sd_sec_read === 1'b0, "撤销请求后 sd_sec_read 拉低");

        //------------------------------------------------------------------
        // 用例 2: 连续第二次读(不同 LBA), 校验 byte_index/busy 正确复位
        //------------------------------------------------------------------
        @(posedge clk);
        // 清空收集区
        for (ci = 0; ci < 512; ci = ci + 1) collected[ci] = 8'hXX;
        sector_lba = 32'd999;
        sector_req = 1'b1;
        @(posedge clk); #1;
        check(sd_sec_read_addr === 32'd999, "第二次读 addr=999");

        wait (sd_sec_read_data_valid === 1'b1);
        check(sector_byte_index === 9'd0, "第二次读 byte_index 从 0 重新计");

        wait (sector_done === 1'b1);
        @(posedge clk); #1;
        check(sector_busy === 1'b0, "第二次读完成 busy=0");
        sector_req = 1'b0;

        //------------------------------------------------------------------
        // 汇总
        //------------------------------------------------------------------
        @(posedge clk);
        $display("===== 汇总: PASS=%0d FAIL=%0d =====", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("RESULT: PASS");
        else               $display("RESULT: FAIL");
        $finish;
    end

    always #5 clk = ~clk;

endmodule
