`timescale 1ns/1ps

// 验证切场提交保护的两个关键竞态：
// 1) 请求发出到 img_busy 拉高之间的旧 idle 窗口不能提前释放；
// 2) img_busy=1 期间到达的旧帧 write_finish 必须被吞掉，目标帧真正
//    write_finish 后才能释放。
module tb_scene_load_guard;
    reg mem_clk = 1'b0;
    reg sd_clk  = 1'b0;
    always #4 mem_clk = ~mem_clk;
    always #5 sd_clk  = ~sd_clk;

    reg rst_mem = 1'b1;
    reg rst_sd  = 1'b1;
    reg write_finish = 1'b0;
    reg scene_change = 1'b0;
    reg img_busy = 1'b0;
    wire guard_busy;

    scene_load_guard dut (
        .mem_clk(mem_clk), .rst_mem(rst_mem), .write_finish(write_finish),
        .sd_clk(sd_clk), .rst_sd(rst_sd), .scene_change(scene_change),
        .img_busy(img_busy), .guard_busy(guard_busy)
    );

    task pulse_commit;
        begin
            @(negedge mem_clk); write_finish = 1'b1;
            @(negedge mem_clk); write_finish = 1'b0;
        end
    endtask

    task require_guard;
        input expected;
        input [127:0] label;
        begin
            if (guard_busy !== expected) begin
                $display("[FAIL] %0s guard=%b expected=%b busy_seen=%b commit=%b base=%b",
                         label, guard_busy, expected, dut.source_busy_seen,
                         dut.commit_s1, dut.commit_base);
                $finish;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge sd_clk);
        rst_mem = 1'b0;
        rst_sd  = 1'b0;

        // 切场请求；img_busy 尚未拉高的空窗必须保持 guard。
        @(negedge sd_clk); scene_change = 1'b1;
        @(negedge sd_clk); scene_change = 1'b0;
        repeat (3) @(posedge sd_clk);
        #1 require_guard(1'b1, "idle gap");

        // 目标加载期间先来一个“旧帧迟到提交”，不得释放。
        img_busy = 1'b1;
        repeat (3) @(posedge sd_clk);
        pulse_commit;
        repeat (4) @(posedge sd_clk);
        #1 require_guard(1'b1, "stale commit while source busy");

        // 源端读完但 FIFO/SDRAM 未提交，仍不得释放。
        img_busy = 1'b0;
        repeat (4) @(posedge sd_clk);
        #1 require_guard(1'b1, "source done before target commit");

        // 目标帧真正提交后，toggle 跨域到达即释放。
        pulse_commit;
        repeat (5) @(posedge sd_clk);
        #1 require_guard(1'b0, "target frame committed");

        $display("[PASS] scene guard waits for source completion and target SDRAM commit");
        $finish;
    end

    initial begin
        #10000;
        $display("[FAIL] timeout");
        $finish;
    end
endmodule
