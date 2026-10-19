`timescale 1ns/1ps

// 菜单→场景黑场握手专项：请求发出后 img_busy 可能晚于一个帧边界才拉高。
// 正确行为是 HOLD 先等到 busy=1，再等 busy=0；旧实现会把最初的 busy=0
// 当作“加载完成”并提前进入 FIN。
module tb_display_adjust_busy_handshake;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg vs_i = 1'b0;
    reg menu_active = 1'b1;
    reg bmp_busy = 1'b0;
    wire hs_o, vs_o, de_o;
    wire [23:0] data_o;

    display_adjust #(
        .H_ACT(4), .V_ACT(2), .TIMEOUT_FRAMES(16'd12),
        .BAR_HOLD_FRAMES(0), .RES_HOLD_FRAMES(0),
        .MAN_HOLD_FRAMES(0), .VOL_HOLD_FRAMES(0),
        .RESW_HOLD_FRAMES(0), .SCB_HOLD_FRAMES(0),
        .IRIS_FRAMES(0), .WIPE_FRAMES(0)
    ) dut (
        .video_clk(clk), .rst(rst),
        .hs_i(1'b0), .vs_i(vs_i), .de_i(1'b1), .data_i(24'hA0B0C0),
        .px_x(12'd0), .px_y(12'd0),
        .menu_active(menu_active), .emerg(1'b0), .bmp_busy(bmp_busy),
        .iris_trig(1'b0), .wipe_trig(1'b0),
        .bri_level(4'd8), .vol_level(4'd8), .res_level(4'd4),
        .con_level(4'd8), .img_res(2'd1), .pic_manual(1'b0), .res_info_always(1'b0),
        .ui_mode(3'd0), .quiz_on(1'b0), .meeting_on(1'b0),
        .q_state(2'd0), .q_end(1'b0),
        .sc0(8'sd0), .sc1(8'sd0), .sc2(8'sd0), .sc3(8'sd0),
        .sc_evt(1'b0), .sc_team(2'd0),
        .hs_o(hs_o), .vs_o(vs_o), .de_o(de_o), .data_o(data_o)
    );

    // 每 16 个像素时钟产生一次帧起点脉冲。
    initial begin
        forever begin
            repeat (15) @(posedge clk);
            vs_i <= 1'b1;
            @(posedge clk);
            vs_i <= 1'b0;
        end
    end

    task next_frame;
        begin
            @(posedge dut.vs_rise);
            #1;
        end
    endtask

    task require_black_hold;
        input [127:0] label;
        begin
            if (dut.fsm !== 2'd2 || dut.alpha !== 8'd0) begin
                $display("[FAIL] %0s fsm=%0d alpha=%0d seen=%0d busy=%0d",
                         label, dut.fsm, dut.alpha, dut.busy_seen, dut.busy_s);
                $finish;
            end
        end
    endtask

    integer guard;
    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (8) @(posedge clk);

        menu_active <= 1'b0;
        // 菜单关闭发生在帧中间：无需等待下一个 VS，2FF 同步一到就应
        // 立即输出黑色，不能让旧迎新底图或新场景 OSD 漏出一帧。
        repeat (5) @(posedge clk);
        #1;
        if (dut.entry_blank !== 1'b1 || data_o !== 24'h000000) begin
            $display("[FAIL] no immediate entry blank blank=%b data=%h fsm=%0d alpha=%0d",
                     dut.entry_blank, data_o, dut.fsm, dut.alpha);
            $finish;
        end
        guard = 0;
        while (dut.fsm != 2'd2 && guard < 8) begin
            next_frame;
            guard = guard + 1;
        end
        require_black_hold("enter hold");

        // 关键竞态：连续两个帧边界仍是旧事务的 idle(0)。不得提前淡入。
        next_frame;
        require_black_hold("idle gap frame 1");
        next_frame;
        require_black_hold("idle gap frame 2");

        bmp_busy <= 1'b1;
        repeat (4) @(posedge clk); // 通过 2FF 同步
        next_frame;
        require_black_hold("new load busy");

        bmp_busy <= 1'b0;
        repeat (4) @(posedge clk); // 通过 2FF 同步
        guard = 0;
        while (dut.fsm != 2'd3 && guard < 4) begin
            next_frame;
            if (dut.fsm == 2'd2 && dut.alpha !== 8'd0) begin
                $display("[FAIL] non-black while waiting for commit alpha=%0d", dut.alpha);
                $finish;
            end
            guard = guard + 1;
        end
        if (dut.fsm !== 2'd3 || dut.alpha !== 8'd0) begin
            $display("[FAIL] commit frame fsm=%0d alpha=%0d", dut.fsm, dut.alpha);
            $finish;
        end
        next_frame;
        if (dut.alpha !== 8'd64) begin
            $display("[FAIL] first fade-in alpha=%0d expected=64", dut.alpha);
            $finish;
        end

        repeat (3) next_frame;
        if (dut.fsm !== 2'd0 || dut.alpha !== 8'd255) begin
            $display("[FAIL] finish fsm=%0d alpha=%0d", dut.fsm, dut.alpha);
            $finish;
        end

        $display("[PASS] delayed busy rise is transaction-qualified; no stale-frame fade-in");
        $finish;
    end

    initial begin
        #200000;
        $display("[FAIL] timeout");
        $finish;
    end
endmodule
