`timescale 1ns/1ps

module tb_quiz_key_chain;

reg        clk;
reg        rst_n;
reg        quiz_enable;
reg        quiz_clear;
reg  [3:0] key_in;
wire [3:0] key_level;
wire [3:0] key_press_pulse;
wire [3:0] key_release_pulse;
wire       locked;
wire [1:0] winner_id;
wire [3:0] winner_onehot;

genvar i;
generate
    for (i = 0; i < 4; i = i + 1) begin : gen_key_path
        key_sync_debounce #(
            .CLK_FREQ_HZ(1000000),
            .DEBOUNCE_MS(1),
            .ACTIVE_LOW(1)
        ) u_key_sync_debounce (
            .clk       (clk),
            .rst_n     (rst_n),
            .key_in    (key_in[i]),
            .key_level (key_level[i])
        );

        key_edge_detect u_key_edge_detect (
            .clk           (clk),
            .rst_n         (rst_n),
            .key_level     (key_level[i]),
            .key_pos_pulse (key_press_pulse[i]),
            .key_neg_pulse (key_release_pulse[i])
        );
    end
endgenerate

quiz_arbiter_4ch u_quiz_arbiter_4ch (
    .clk           (clk),
    .rst_n         (rst_n),
    .quiz_enable   (quiz_enable),
    .quiz_clear    (quiz_clear),
    .player_pulse  (key_press_pulse),
    .locked        (locked),
    .winner_id     (winner_id),
    .winner_onehot (winner_onehot)
);

initial begin
    clk = 1'b0;
    forever #500 clk = ~clk;  // 1 MHz, period = 1 us
end

task press_key_with_bounce;
    input integer key_index;
    begin
        key_in[key_index] = 1'b0; #100000;
        key_in[key_index] = 1'b1; #80000;
        key_in[key_index] = 1'b0; #120000;
        key_in[key_index] = 1'b1; #60000;
        key_in[key_index] = 1'b0;
    end
endtask

task release_key_with_bounce;
    input integer key_index;
    begin
        key_in[key_index] = 1'b1; #90000;
        key_in[key_index] = 1'b0; #70000;
        key_in[key_index] = 1'b1; #110000;
        key_in[key_index] = 1'b0; #50000;
        key_in[key_index] = 1'b1;
    end
endtask

task clear_quiz;
    begin
        @(negedge clk);
        quiz_clear = 1'b1;
        @(negedge clk);
        quiz_clear = 1'b0;
    end
endtask

task check_result;
    input       exp_locked;
    input [1:0] exp_id;
    input [3:0] exp_onehot;
    begin
        #1;
        if (locked !== exp_locked ||
            winner_id !== exp_id ||
            winner_onehot !== exp_onehot) begin
            $display("FAIL at %0t: locked=%b id=%0d onehot=%b, expected locked=%b id=%0d onehot=%b",
                     $time, locked, winner_id, winner_onehot,
                     exp_locked, exp_id, exp_onehot);
            $stop;
        end
    end
endtask

initial begin
    rst_n       = 1'b0;
    quiz_enable = 1'b0;
    quiz_clear  = 1'b0;
    key_in      = 4'b1111;

    repeat (10) @(negedge clk);
    rst_n = 1'b1;
    quiz_enable = 1'b1;
    repeat (10) @(negedge clk);

    press_key_with_bounce(1);
    #1500000;
    check_result(1'b1, 2'd1, 4'b0010);

    press_key_with_bounce(0);
    #1500000;
    check_result(1'b1, 2'd1, 4'b0010);

    release_key_with_bounce(1);
    release_key_with_bounce(0);
    #1500000;

    clear_quiz();
    #10000;
    check_result(1'b0, 2'd0, 4'b0000);

    press_key_with_bounce(3);
    #1500000;
    check_result(1'b1, 2'd3, 4'b1000);

    release_key_with_bounce(3);
    #1500000;
    clear_quiz();
    #10000;
    check_result(1'b0, 2'd0, 4'b0000);

    fork
        press_key_with_bounce(2);
        begin
            #400000;
            press_key_with_bounce(0);
        end
    join
    #1500000;
    check_result(1'b1, 2'd2, 4'b0100);

    $display("PASS: tb_quiz_key_chain completed.");
    $stop;
end

endmodule
