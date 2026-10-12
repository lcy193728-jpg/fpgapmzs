`timescale 1ns/1ps

module tb_video_first_frame_gate;
    reg         mem_clk = 1'b0;
    reg         video_clk = 1'b0;
    reg         rst_mem = 1'b1;
    reg         rst_video = 1'b1;
    reg         frame_write_finish = 1'b0;
    reg         video_vs = 1'b0;
    reg  [23:0] data_i = 24'h12_34_56;
    wire [23:0] data_o;
    wire        frame_ready;
    integer     fails = 0;

    always #4  mem_clk = ~mem_clk;
    always #20 video_clk = ~video_clk;

    video_first_frame_gate dut (
        .mem_clk(mem_clk),
        .rst_mem(rst_mem),
        .frame_write_finish(frame_write_finish),
        .video_clk(video_clk),
        .rst_video(rst_video),
        .video_vs(video_vs),
        .data_i(data_i),
        .data_o(data_o),
        .frame_ready(frame_ready)
    );

    task check_black;
        begin
            #1;
            if (data_o !== 24'h000000 || frame_ready !== 1'b0) begin
                $display("[FAIL] pre-commit output data=%h ready=%b", data_o, frame_ready);
                fails = fails + 1;
            end
        end
    endtask

    initial begin
        // 冷启动：即使读端数据非黑，也必须保持黑背景。
        repeat (3) @(posedge video_clk);
        rst_mem = 1'b0;
        rst_video = 1'b0;
        repeat (3) begin
            @(posedge video_clk);
            check_black;
        end

        // 首帧写完；跨域同步完成但尚未到帧边界时仍不得放行。
        @(posedge mem_clk);
        frame_write_finish = 1'b1;
        @(posedge mem_clk);
        frame_write_finish = 1'b0;
        repeat (3) @(posedge video_clk);
        check_black;

        // 下一帧 VS 上升沿才整帧放行。
        video_vs = 1'b1;
        @(posedge video_clk);
        #1;
        if (data_o !== data_i || frame_ready !== 1'b1) begin
            $display("[FAIL] frame-boundary release data=%h ready=%b", data_o, frame_ready);
            fails = fails + 1;
        end
        video_vs = 1'b0;

        data_i = 24'hA5_5A_C3;
        @(posedge video_clk);
        #1;
        if (data_o !== data_i) begin
            $display("[FAIL] post-release data did not pass through: %h", data_o);
            fails = fails + 1;
        end

        // 重新复位后必须立即恢复黑场。
        rst_video = 1'b1;
        rst_mem = 1'b1;
        #1;
        check_black;

        if (fails == 0)
            $display("[PASS] cold boot stays black until first complete frame and VS boundary");
        else
            $display("[FAIL] tb_video_first_frame_gate failures=%0d", fails);
        $finish;
    end
endmodule
