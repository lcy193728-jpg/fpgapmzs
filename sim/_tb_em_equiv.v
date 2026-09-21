// 临时等价性 TB: 逐拍对照 emergency_multi_overlay(优化版) 与 ..._ref(改前版)。
// 覆盖 4 种 alarm_type × 3 帧(不同倒计时数字) × 全像素栅格，
// 逐像素比较 de/data/px; 任何 1 LSB 差异即报错。仅用于面积优化验证, 不进综合工程。
`timescale 1ns/1ps
module tb_em_equiv;

    reg clk = 0, rst = 1;
    reg hs_i = 0, vs_i = 0, de_i = 0;
    reg [23:0] data_i = 24'h204080;
    reg [11:0] px_x = 0, px_y = 0;
    reg        alarm_en = 0;
    reg [1:0]  alarm_type = 0;
    reg [3:0]  min_tens = 0, min_ones = 0, sec_tens = 0, sec_ones = 0;

    wire        hs_a, vs_a, de_a;
    wire [23:0] d_a;
    wire [11:0] xx_a, yy_a;
    wire        hs_b, vs_b, de_b;
    wire [23:0] d_b;
    wire [11:0] xx_b, yy_b;

    // BLINK_DIV 缩短到 100 拍, 让 blink 两相都被扫到
    emergency_multi_overlay #(.BLINK_DIV(22'd100)) dut(
        .clk(clk), .rst(rst), .hs_i(hs_i), .vs_i(vs_i), .de_i(de_i), .data_i(data_i),
        .px_x(px_x), .px_y(px_y), .alarm_en(alarm_en), .alarm_type(alarm_type),
        .min_tens(min_tens), .min_ones(min_ones), .sec_tens(sec_tens), .sec_ones(sec_ones),
        .hs_o(hs_a), .vs_o(vs_a), .de_o(de_a), .data_o(d_a), .px_x_o(xx_a), .px_y_o(yy_a));

    emergency_multi_overlay_ref #(.BLINK_DIV(22'd100)) ref(
        .clk(clk), .rst(rst), .hs_i(hs_i), .vs_i(vs_i), .de_i(de_i), .data_i(data_i),
        .px_x(px_x), .px_y(px_y), .alarm_en(alarm_en), .alarm_type(alarm_type),
        .min_tens(min_tens), .min_ones(min_ones), .sec_tens(sec_tens), .sec_ones(sec_ones),
        .hs_o(hs_b), .vs_o(vs_b), .de_o(de_b), .data_o(d_b), .px_x_o(xx_b), .px_y_o(yy_b));

    always #5 clk = ~clk;      // 100MHz

    integer errs, ty, fr, px, py;
    reg [3:0] tvals [0:2];
    reg [3:0] svals [0:2];

    initial begin
        errs = 0;
        tvals[0] = 4'd0; tvals[1] = 4'd3; tvals[2] = 4'd9;
        svals[0] = 4'd0; svals[1] = 4'd7; svals[2] = 4'd5;
        rst = 1;
        repeat (5) @(negedge clk);
        rst = 0;

        for (ty = 0; ty < 4; ty = ty + 1) begin
            alarm_type = ty[1:0];
            alarm_en   = 1'b1;
            for (fr = 0; fr < 3; fr = fr + 1) begin
                min_tens = tvals[fr]; min_ones = svals[fr];
                sec_tens = svals[fr]; sec_ones = tvals[fr];
                for (py = 0; py < 525; py = py + 1) begin
                    for (px = 0; px < 800; px = px + 1) begin
                        @(negedge clk);
                        px_x = (px < 640) ? px[11:0] : 12'd0;
                        px_y = (py < 480) ? py[11:0] : 12'd0;
                        de_i = (px < 640) && (py < 480);
                        hs_i = (px == 0);
                        vs_i = (py < 3);
                        data_i = 24'h204080 ^ {12'd0, px[11:0]} ^ {py[11:0], 12'd0};
                        if (de_a !== de_b || d_a !== d_b ||
                            xx_a !== xx_b || yy_a !== yy_b) begin
                            if (errs < 20)
                                $display("MISMATCH type=%0d fr=%0d px=%0d py=%0d : de %b/%b data %h/%h  px %0d/%0d  py %0d/%0d",
                                         ty, fr, px, py, de_a, de_b, d_a, d_b,
                                         xx_a, xx_b, yy_a, yy_b);
                            errs = errs + 1;
                        end
                    end
                end
            end
        end

        if (errs == 0) $display("=== EM EQUIV: ALL PASS (0 mismatches) ===");
        else           $display("=== EM EQUIV: FAIL (%0d mismatches) ===", errs);
        $finish;
    end

    // 看门狗: 12 帧 × 42 万拍 = 约 50ms 仿真时间
    initial begin
        #200_000_000;
        $display("=== EM EQUIV: TIMEOUT ===");
        $finish;
    end

endmodule
