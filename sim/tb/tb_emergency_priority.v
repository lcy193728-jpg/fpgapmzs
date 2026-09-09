`timescale 1ns/1ps

module tb_emergency_priority;

reg        clk;
reg        rst_n;
reg        emergency_pulse;
reg        alarm_clear_pulse;
reg  [1:0] scene_normal;
reg        quiz_active;
wire       emergency_active;
wire [1:0] scene_current;
wire       quiz_visible;
wire       emergency_visible;

emergency_latch u_emergency_latch (
    .clk               (clk),
    .rst_n             (rst_n),
    .emergency_pulse   (emergency_pulse),
    .alarm_clear_pulse (alarm_clear_pulse),
    .emergency_active  (emergency_active)
);

priority_scheduler u_priority_scheduler (
    .scene_normal      (scene_normal),
    .quiz_active       (quiz_active),
    .emergency_active  (emergency_active),
    .scene_current     (scene_current),
    .quiz_visible      (quiz_visible),
    .emergency_visible (emergency_visible)
);

initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
end

task send_emergency;
    begin
        @(negedge clk);
        emergency_pulse = 1'b1;
        @(negedge clk);
        emergency_pulse = 1'b0;
    end
endtask

task send_alarm_clear;
    begin
        @(negedge clk);
        alarm_clear_pulse = 1'b1;
        @(negedge clk);
        alarm_clear_pulse = 1'b0;
    end
endtask

task check_result;
    input       exp_emergency_active;
    input [1:0] exp_scene_current;
    input       exp_quiz_visible;
    input       exp_emergency_visible;
    begin
        #1;
        if (emergency_active !== exp_emergency_active ||
            scene_current !== exp_scene_current ||
            quiz_visible !== exp_quiz_visible ||
            emergency_visible !== exp_emergency_visible) begin
            $display("FAIL at %0t: emergency=%b scene=%0d quiz_vis=%b alarm_vis=%b",
                     $time, emergency_active, scene_current, quiz_visible, emergency_visible);
            $display("Expected: emergency=%b scene=%0d quiz_vis=%b alarm_vis=%b",
                     exp_emergency_active, exp_scene_current, exp_quiz_visible, exp_emergency_visible);
            $stop;
        end
    end
endtask

initial begin
    rst_n             = 1'b0;
    emergency_pulse   = 1'b0;
    alarm_clear_pulse = 1'b0;
    scene_normal      = 2'd0;
    quiz_active       = 1'b0;

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
    check_result(1'b0, 2'd0, 1'b0, 1'b0);

    scene_normal = 2'd1;
    repeat (2) @(negedge clk);
    check_result(1'b0, 2'd1, 1'b0, 1'b0);

    quiz_active = 1'b1;
    repeat (2) @(negedge clk);
    check_result(1'b0, 2'd1, 1'b0, 1'b0);

    scene_normal = 2'd2;
    repeat (2) @(negedge clk);
    check_result(1'b0, 2'd2, 1'b1, 1'b0);

    send_emergency();
    @(posedge clk);
    check_result(1'b1, 2'd3, 1'b0, 1'b1);

    quiz_active = 1'b0;
    scene_normal = 2'd0;
    repeat (5) @(negedge clk);
    check_result(1'b1, 2'd3, 1'b0, 1'b1);

    send_alarm_clear();
    @(posedge clk);
    check_result(1'b0, 2'd0, 1'b0, 1'b0);

    quiz_active = 1'b1;
    scene_normal = 2'd1;
    repeat (2) @(negedge clk);
    send_emergency();
    alarm_clear_pulse = 1'b1;
    @(negedge clk);
    alarm_clear_pulse = 1'b0;
    emergency_pulse = 1'b0;
    @(posedge clk);
    check_result(1'b0, 2'd1, 1'b0, 1'b0);

    $display("PASS: tb_emergency_priority completed.");
    $stop;
end

endmodule
