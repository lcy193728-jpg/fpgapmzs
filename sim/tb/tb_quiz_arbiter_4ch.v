`timescale 1ns/1ps

module tb_quiz_arbiter_4ch;

reg        clk;
reg        rst_n;
reg        quiz_enable;
reg        quiz_clear;
reg  [3:0] player_pulse;
wire       locked;
wire [1:0] winner_id;
wire [3:0] winner_onehot;

quiz_arbiter_4ch dut(
    .clk           (clk),
    .rst_n         (rst_n),
    .quiz_enable   (quiz_enable),
    .quiz_clear    (quiz_clear),
    .player_pulse  (player_pulse),
    .locked        (locked),
    .winner_id     (winner_id),
    .winner_onehot (winner_onehot)
);

initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
end

task pulse_player;
    input [3:0] pulse_value;
    begin
        @(negedge clk);
        player_pulse = pulse_value;
        @(negedge clk);
        player_pulse = 4'b0000;
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
    rst_n         = 1'b0;
    quiz_enable   = 1'b0;
    quiz_clear    = 1'b0;
    player_pulse  = 4'b0000;

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    quiz_enable = 1'b1;
    repeat (2) @(negedge clk);

    pulse_player(4'b0001);
    @(posedge clk);
    check_result(1'b1, 2'd0, 4'b0001);

    pulse_player(4'b0100);
    @(posedge clk);
    check_result(1'b1, 2'd0, 4'b0001);

    clear_quiz();
    @(posedge clk);
    check_result(1'b0, 2'd0, 4'b0000);

    pulse_player(4'b0100);
    @(posedge clk);
    check_result(1'b1, 2'd2, 4'b0100);

    clear_quiz();
    @(posedge clk);
    check_result(1'b0, 2'd0, 4'b0000);

    pulse_player(4'b1010);
    @(posedge clk);
    check_result(1'b1, 2'd1, 4'b0010);

    clear_quiz();
    quiz_enable = 1'b0;
    pulse_player(4'b1000);
    @(posedge clk);
    check_result(1'b0, 2'd0, 4'b0000);

    $display("PASS: tb_quiz_arbiter_4ch completed.");
    $stop;
end

endmodule
