`timescale 1ns/1ps

module tb_scene_selector;

reg        clk;
reg        rst_n;
reg        next_pulse;
reg        prev_pulse;
reg        direct_en;
reg  [1:0] direct_scene;
wire [1:0] scene_normal;
wire       scene_changed;

scene_selector dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .next_pulse    (next_pulse),
    .prev_pulse    (prev_pulse),
    .direct_en     (direct_en),
    .direct_scene  (direct_scene),
    .scene_normal  (scene_normal),
    .scene_changed (scene_changed)
);

initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
end

task send_next;
    begin
        @(negedge clk);
        next_pulse = 1'b1;
        @(negedge clk);
        next_pulse = 1'b0;
    end
endtask

task send_prev;
    begin
        @(negedge clk);
        prev_pulse = 1'b1;
        @(negedge clk);
        prev_pulse = 1'b0;
    end
endtask

task send_direct;
    input [1:0] value;
    begin
        @(negedge clk);
        direct_scene = value;
        direct_en = 1'b1;
        @(negedge clk);
        direct_en = 1'b0;
    end
endtask

task check_scene;
    input [1:0] exp_scene;
    begin
        #1;
        if (scene_normal !== exp_scene) begin
            $display("FAIL at %0t: scene=%0d, expected scene=%0d",
                     $time, scene_normal, exp_scene);
            $stop;
        end
    end
endtask

initial begin
    rst_n        = 1'b0;
    next_pulse   = 1'b0;
    prev_pulse   = 1'b0;
    direct_en    = 1'b0;
    direct_scene = 2'd0;

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
    check_scene(2'd0);

    send_next();
    @(posedge clk);
    check_scene(2'd1);

    send_next();
    @(posedge clk);
    check_scene(2'd2);

    send_next();
    @(posedge clk);
    check_scene(2'd0);

    send_prev();
    @(posedge clk);
    check_scene(2'd2);

    send_direct(2'd1);
    @(posedge clk);
    check_scene(2'd1);

    send_direct(2'd3);
    @(posedge clk);
    check_scene(2'd1);

    @(negedge clk);
    next_pulse = 1'b1;
    prev_pulse = 1'b1;
    @(negedge clk);
    next_pulse = 1'b0;
    prev_pulse = 1'b0;
    @(posedge clk);
    check_scene(2'd1);

    $display("PASS: tb_scene_selector completed.");
    $stop;
end

endmodule
