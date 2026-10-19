`timescale 1ns/1ps

// bmp_scale 行缓存读使能专项回归。
// 激励只在下降沿改变，避免 testbench 与 DUT 在上升沿的调度竞争。
module tb_bmp_scale_bram_gate;
    localparam SW = 16;
    localparam SH = 12;
    localparam CW = 16;
    localparam CH = 12;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg [3:0] scale_sel = 4'd4;
    reg frame_start = 1'b0;
    reg src_v2x = 1'b0;
    reg in_en = 1'b0;
    reg [31:0] in_data = 32'd0;
    wire out_en;
    wire [31:0] out_data;

    integer out_count = 0;
    integer errors = 0;
    integer ox = 0;
    integer oy = 0;
    integer hold_checks = 0;
    integer input_events = 0;
    integer frame_events = 0;
    reg [31:0] exp_data;
    reg [31:0] d0_prev, d1_prev, d2_prev;
    reg rd_en_prev = 1'b0;

    always #5 clk = ~clk;

    bmp_scale #(
        .SRC_W(SW), .SRC_H(SH), .CANV_W(CW), .CANV_H(CH)
    ) dut (
        .clk(clk), .rst(rst), .scale_sel(scale_sel),
        .frame_start(frame_start), .src_v2x(src_v2x),
        .in_en(in_en), .in_data(in_data),
        .out_en(out_en), .out_data(out_data)
    );

    function [31:0] pixel;
        input integer x;
        input integer y;
        reg [7:0] pr, pg, pb;
        begin
            pr = x + 3*y;
            pg = 2*x + y;
            pb = x ^ y;
            pixel = {pr, pg, pb, 8'h00};
        end
    endfunction

    function [31:0] expected;
        input integer x;
        input integer y;
        input [3:0] sel;
        integer u;
        begin
            if (sel == 4'd4)
                expected = pixel(x, y);
            else begin
                u = x - 4;
                if ((u >= 0) && (u < 8) && (y < 6))
                    expected = pixel(2*u, 2*y);
                else
                    expected = 32'd0;
            end
        end
    endfunction

    // 在输出稳定的下降沿采集，逐点检查输出序列。
    always @(negedge clk) begin
        if (!rst && out_en) begin
            exp_data = expected(ox, oy, scale_sel);
            if (out_data !== exp_data) begin
                errors = errors + 1;
                if (errors < 8)
                    $display("[FAIL] sel=%0d (%0d,%0d) got=%08x exp=%08x",
                             scale_sel, ox, oy, out_data, exp_data);
            end
            out_count = out_count + 1;
            if (ox == CW-1) begin
                ox = 0;
                oy = (oy == CH-1) ? 0 : oy + 1;
            end else begin
                ox = ox + 1;
            end
        end

        // 非读状态必须保持 BRAM 输出寄存器，证明原生读使能有效。
        if (!rst && !rd_en_prev && (dut.d0 !== 32'hxxxxxxxx)) begin
            if ((dut.d0 !== d0_prev) || (dut.d1 !== d1_prev) || (dut.d2 !== d2_prev)) begin
                errors = errors + 1;
                $display("[FAIL] line-buffer output toggled while read enable was low");
            end
            hold_checks = hold_checks + 1;
        end
        d0_prev = dut.d0;
        d1_prev = dut.d1;
        d2_prev = dut.d2;
        rd_en_prev = dut.line_rd_en;
    end

    always @(posedge clk) begin
        if (dut.in_pix) input_events = input_events + 1;
        if (dut.fs_pulse) begin
            frame_events = frame_events + 1;
            $display("[NOTE] fs sel=%0d k=%0d dst=%0dx%0d src=%0dx%0d state=%0d",
                     scale_sel, dut.cfg_k, dut.cfg_dstw, dut.cfg_dsth,
                     SW, SH, dut.state);
        end
    end

    task pulse_frame_start;
        begin
            @(negedge clk); frame_start = 1'b1;
            repeat (4) @(negedge clk);
            frame_start = 1'b0;
            repeat (6) @(negedge clk);
        end
    endtask

    task send_source_frame;
        integer x, y;
        begin
            for (y = 0; y < SH; y = y + 1) begin
                for (x = 0; x < SW; x = x + 1) begin
                    @(negedge clk);
                    in_data = pixel(x, y);
                    in_en = 1'b1;
                    @(negedge clk);
                    in_en = 1'b0;
                    repeat (95) @(negedge clk);
                end
            end
        end
    endtask

    task run_frame;
        input [3:0] sel;
        integer timeout;
        begin
            // 先改变一次选择值，确保纯组合配置块在所有仿真器中都被求值。
            scale_sel = 4'hf;
            @(negedge clk);
            scale_sel = sel;
            @(negedge clk);
            out_count = 0;
            ox = 0;
            oy = 0;
            pulse_frame_start;
            send_source_frame;
            timeout = 0;
            while ((out_count < CW*CH) && (timeout < 100000)) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (out_count != CW*CH) begin
                errors = errors + 1;
                $display("[FAIL] sel=%0d output count=%0d expected=%0d state=%0d in=%0d fs=%0d vld=%b",
                         sel, out_count, CW*CH, dut.state, input_events, frame_events, dut.buf_vld);
            end else begin
                $display("[PASS] sel=%0d complete frame count and pixel values", sel);
            end
            repeat (20) @(negedge clk);
        end
    endtask

    initial begin
        repeat (8) @(negedge clk);
        rst = 1'b0;
        repeat (8) @(negedge clk);

        run_frame(4'd4); // 100% 旁路
        run_frame(4'd2); // 50% 双线性路径（整数采样点）

        if (hold_checks == 0) begin
            errors = errors + 1;
            $display("[FAIL] no disabled-read hold interval observed");
        end

        if (errors == 0)
            $display("[PASS] bmp_scale BRAM read gating regression, hold_checks=%0d", hold_checks);
        else
            $display("[FAIL] bmp_scale BRAM read gating regression, errors=%0d", errors);
        $finish;
    end
endmodule
