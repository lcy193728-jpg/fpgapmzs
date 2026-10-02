`timescale 1ns/1ps

module tb_quiz_timer;

reg       clk;
reg       rst_n;
reg       start_pulse;
reg       clear_pulse;
reg       locked;
wire      running;
wire      quiz_enable;
wire      time_up;
wire [7:0] time_left;

quiz_timer #(
    .CLK_FREQ_HZ(1000),
    .TIME_SEC(5)
) dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .start_pulse (start_pulse),
    .clear_pulse (clear_pulse),
    .locked      (locked),
    .running     (running),
    .quiz_enable (quiz_enable),
    .time_up     (time_up),
    .time_left   (time_left)
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

task check_result;
    input       exp_running;
    input       exp_quiz_enable;
    input       exp_time_up;
    input [7:0] exp_time_left;
    begin
        #1;
        if (running !== exp_running ||
            quiz_enable !== exp_quiz_enable ||
            time_up !== exp_time_up ||
            time_left !== exp_time_left) begin
            $display("FAIL at %0t: running=%b enable=%b time_up=%b left=%0d, expected running=%b enable=%b time_up=%b left=%0d",
                     $time, running, quiz_enable, time_up, time_left,
                     exp_running, exp_quiz_enable, exp_time_up, exp_time_left);
            $stop;
        end
    end
endtask

initial begin
    rst_n       = 1'b0;
    start_pulse = 1'b0;
    clear_pulse = 1'b0;
    locked      = 1'b0;

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
    check_result(1'b0, 1'b0, 1'b0, 8'd5);

    send_start();
    @(posedge clk);
    check_result(1'b1, 1'b1, 1'b0, 8'd5);

    repeat (1000) @(posedge clk);
    check_result(1'b1, 1'b1, 1'b0, 8'd4);

    repeat (1000) @(posedge clk);
    check_result(1'b1, 1'b1, 1'b0, 8'd3);

    locked = 1'b1;
    repeat (1500) @(posedge clk);
    check_result(1'b0, 1'b0, 1'b0, 8'd3);

    locked = 1'b0;
    send_clear();
    @(posedge clk);
    check_result(1'b0, 1'b0, 1'b0, 8'd5);

    send_start();
    repeat (5000) @(posedge clk);
    check_result(1'b0, 1'b0, 1'b1, 8'd0);

    send_clear();
    @(posedge clk);
    check_result(1'b0, 1'b0, 1'b0, 8'd5);

    $display("PASS: tb_quiz_timer completed.");
    $stop;
end

endmodule
