`timescale 1ns/1ps

module tb_welcome_scene_effects_v2;

reg         clk;
reg         rst_n;
reg         de;
reg  [10:0] x;
reg  [10:0] y;
reg  [23:0] bg_rgb;
reg         osd_enable;
reg         scroll_enable;
reg         transition_start;
reg  [3:0]  brightness_level;

wire [23:0] osd_rgb;
wire        osd_hit;
wire [10:0] scroll_x;
wire        scroll_hit;
wire        transition_busy;
wire        transition_done;
wire [7:0]  alpha;
wire [23:0] bright_rgb;

welcome_osd_overlay u_welcome_osd_overlay (
    .de         (de),
    .x          (x),
    .y          (y),
    .bg_rgb     (bg_rgb),
    .osd_enable (osd_enable),
    .out_rgb    (osd_rgb),
    .osd_hit    (osd_hit)
);

scroll_text_ctrl #(
    .H_ACTIVE   (640),
    .TEXT_WIDTH (260),
    .STEP_MAX   (2)
) u_scroll_text_ctrl (
    .clk           (clk),
    .rst_n         (rst_n),
    .scroll_enable (scroll_enable),
    .x             (x),
    .y             (y),
    .scroll_x      (scroll_x),
    .scroll_hit    (scroll_hit)
);

fade_transition_ctrl #(
    .STEP_MAX(2)
) u_fade_transition_ctrl (
    .clk              (clk),
    .rst_n            (rst_n),
    .transition_start (transition_start),
    .transition_busy  (transition_busy),
    .transition_done  (transition_done),
    .alpha            (alpha)
);

brightness_adjust u_brightness_adjust (
    .rgb_in           (osd_rgb),
    .brightness_level (brightness_level),
    .rgb_out          (bright_rgb)
);

initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
end

task set_and_check_pixel;
    input [10:0] px;
    input [10:0] py;
    input        exp_hit;
    input [23:0] exp_rgb;
    begin
        @(negedge clk);
        x = px;
        y = py;
        repeat (2) @(posedge clk);
        #5;
        $display("CHECK pixel x=%0d y=%0d de=%b osd_en=%b hit=%b rgb=%h",
                 x, y, de, osd_enable, osd_hit, osd_rgb);
        if (osd_hit !== exp_hit || osd_rgb !== exp_rgb) begin
            $display("FAIL: pixel check mismatch. expected hit=%b rgb=%h",
                     exp_hit, exp_rgb);
            $stop;
        end
    end
endtask

initial begin
    rst_n            = 1'b0;
    de               = 1'b0;
    x                = 11'd0;
    y                = 11'd0;
    bg_rgb           = 24'h102030;
    osd_enable       = 1'b0;
    scroll_enable    = 1'b0;
    transition_start = 1'b0;
    brightness_level = 4'd0;

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    de = 1'b1;
    osd_enable = 1'b1;

    set_and_check_pixel(11'd50,  11'd40,  1'b1, 24'hffd24a);
    set_and_check_pixel(11'd100, 11'd390, 1'b1, 24'h2f80ff);
    set_and_check_pixel(11'd500, 11'd390, 1'b1, 24'h26c281);
    set_and_check_pixel(11'd620, 11'd470, 1'b0, bg_rgb);

    brightness_level = 4'd4;
    repeat (2) @(posedge clk);
    #5;
    if (bright_rgb <= bg_rgb) begin
        $display("FAIL: brightness output should be greater than background at level 4.");
        $stop;
    end

    scroll_enable = 1'b1;
    @(negedge clk);
    x = 11'd639;
    y = 11'd440;
    repeat (4) @(posedge clk);
    #5;
    if (scroll_x >= 11'd640) begin
        $display("FAIL: scroll_x should move left after enable.");
        $stop;
    end

    @(negedge clk);
    transition_start = 1'b1;
    @(negedge clk);
    transition_start = 1'b0;
    wait (transition_done == 1'b1);
    #5;
    if (alpha !== 8'd255) begin
        $display("FAIL: alpha should reach 255 when transition_done.");
        $stop;
    end

    $display("PASS: tb_welcome_scene_effects_v2 completed.");
    $stop;
end

endmodule
