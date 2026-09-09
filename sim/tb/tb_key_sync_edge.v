`timescale 1ns/1ps

module tb_key_sync_edge;

reg clk;
reg rst_n;
reg key_in;
wire key_level;
wire key_pos_pulse;
wire key_neg_pulse;

integer pos_cnt;
integer neg_cnt;

key_sync_debounce #(
    .CLK_FREQ_HZ(1000000),
    .DEBOUNCE_MS(1),
    .ACTIVE_LOW(1)
) u_key_sync_debounce (
    .clk       (clk),
    .rst_n     (rst_n),
    .key_in    (key_in),
    .key_level (key_level)
);

key_edge_detect u_key_edge_detect (
    .clk           (clk),
    .rst_n         (rst_n),
    .key_level     (key_level),
    .key_pos_pulse (key_pos_pulse),
    .key_neg_pulse (key_neg_pulse)
);

initial begin
    clk = 1'b0;
    forever #500 clk = ~clk;  // 1 MHz
end

always @(posedge clk) begin
    #1;
    if (key_pos_pulse)
        pos_cnt = pos_cnt + 1;
    if (key_neg_pulse)
        neg_cnt = neg_cnt + 1;
end

task press_with_bounce;
    begin
        key_in = 1'b0; #100000;
        key_in = 1'b1; #80000;
        key_in = 1'b0; #120000;
        key_in = 1'b1; #60000;
        key_in = 1'b0;
    end
endtask

task release_with_bounce;
    begin
        key_in = 1'b1; #90000;
        key_in = 1'b0; #70000;
        key_in = 1'b1; #110000;
        key_in = 1'b0; #50000;
        key_in = 1'b1;
    end
endtask

initial begin
    rst_n   = 1'b0;
    key_in  = 1'b1;
    pos_cnt = 0;
    neg_cnt = 0;

    repeat (10) @(negedge clk);
    rst_n = 1'b1;
    repeat (10) @(negedge clk);

    press_with_bounce();
    #1500000;

    if (key_level !== 1'b1) begin
        $display("FAIL: key_level should be pressed after debounce.");
        $stop;
    end

    if (pos_cnt !== 1) begin
        $display("FAIL: key_pos_pulse count=%0d, expected 1.", pos_cnt);
        $stop;
    end

    release_with_bounce();
    #1500000;

    if (key_level !== 1'b0) begin
        $display("FAIL: key_level should be released after debounce.");
        $stop;
    end

    if (neg_cnt !== 1) begin
        $display("FAIL: key_neg_pulse count=%0d, expected 1.", neg_cnt);
        $stop;
    end

    if (pos_cnt !== 1) begin
        $display("FAIL: key_pos_pulse changed after release, count=%0d.", pos_cnt);
        $stop;
    end

    $display("PASS: tb_key_sync_edge completed.");
    $stop;
end

endmodule
