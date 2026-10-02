`timescale 1ns/1ps

module tb_quiz_ctrl;

reg        clk;
reg        rst_n;
reg        start_pulse;
reg        clear_pulse;
reg  [3:0] player_pulse;
wire       running;
wire       quiz_enable;
wire       time_up;
wire [7:0] time_left;
wire       locked;
wire [1:0] winner_id;
wire [3:0] winner_onehot;

quiz_ctrl #(
    .CLK_FREQ_HZ(1000),
    .TIME_SEC(3)
) dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .start_pulse   (start_pulse),
    .clear_pulse   (clear_pulse),
    .player_pulse  (player_pulse),
    .running       (running),
    .quiz_enable   (quiz_enable),
    .time_up       (time_up),
    .time_left     (time_left),
    .locked        (locked),
    .winner_id     (winner_id),
    .winner_onehot (winner_onehot)
);

initial begin
    clk = 1'b0;
    forever #500000 clk = ~clk;  // 1 kHz, period = 1 ms
end

task send_start;
    begin
        @(negedge clk);
        start_pulse = 1'b1;
        @(negedge clk);
        start_pulse = 1'b0;
    end
endtask

task send_clear;
    begin
        @(negedge clk);
        clear_pulse = 1'b1;
        @(negedge clk);
        clear_pulse = 1'b0;
    end
endtask

task pulse_player;
    input [3:0] value;
    begin
        @(negedge clk);
        player_pulse = value;
        @(negedge clk);
        player_pulse = 4'b0000;
    end
endtask

task check_result;
    input       exp_running;
    input       exp_quiz_enable;
    input       exp_time_up;
    input [7:0] exp_time_left;
    input       exp_locked;
    input [1:0] exp_winner_id;
    input [3:0] exp_winner_onehot;
    begin
        #1;
        if (running !== exp_running ||
            quiz_enable !== exp_quiz_enable ||
            time_up !== exp_time_up ||
            time_left !== exp_time_left ||
            locked !== exp_locked ||
            winner_id !== exp_winner_id ||
            winner_onehot !== exp_winner_onehot) begin
            $display("FAIL at %0t: run=%b en=%b up=%b left=%0d lock=%b id=%0d onehot=%b",
                     $time, running, quiz_enable, time_up, time_left,
                     locked, winner_id, winner_onehot);
            $display("Expected: run=%b en=%b up=%b left=%0d lock=%b id=%0d onehot=%b",
                     exp_running, exp_quiz_enable, exp_time_up, exp_time_left,
                     exp_locked, exp_winner_id, exp_winner_onehot);
            $stop;
        end
    end
endtask

initial begin
    rst_n        = 1'b0;
    start_pulse  = 1'b0;
    clear_pulse  = 1'b0;
    player_pulse = 4'b0000;

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
    check_result(1'b0, 1'b0, 1'b0, 8'd3, 1'b0, 2'd0, 4'b0000);

    pulse_player(4'b0010);
    @(posedge clk);
    check_result(1'b0, 1'b0, 1'b0, 8'd3, 1'b0, 2'd0, 4'b0000);

    send_start();
    @(posedge clk);
    check_result(1'b1, 1'b1, 1'b0, 8'd3, 1'b0, 2'd0, 4'b0000);

    repeat (500) @(posedge clk);
    pulse_player(4'b0100);
    @(posedge clk);
    check_result(1'b0, 1'b0, 1'b0, 8'd3, 1'b1, 2'd2, 4'b0100);

    pulse_player(4'b0001);
    @(posedge clk);
    check_result(1'b0, 1'b0, 1'b0, 8'd3, 1'b1, 2'd2, 4'b0100);

    send_clear();
    @(posedge clk);
    check_result(1'b0, 1'b0, 1'b0, 8'd3, 1'b0, 2'd0, 4'b0000);

    send_start();
    repeat (3000) @(posedge clk);
    check_result(1'b0, 1'b0, 1'b1, 8'd0, 1'b0, 2'd0, 4'b0000);

    pulse_player(4'b1000);
    @(posedge clk);
    check_result(1'b0, 1'b0, 1'b1, 8'd0, 1'b0, 2'd0, 4'b0000);

    send_clear();
    @(posedge clk);
    check_result(1'b0, 1'b0, 1'b0, 8'd3, 1'b0, 2'd0, 4'b0000);

    $display("PASS: tb_quiz_ctrl completed.");
    $stop;
end

endmodule
