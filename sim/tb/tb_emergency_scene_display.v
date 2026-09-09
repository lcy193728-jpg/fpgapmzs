`timescale 1ns/1ps

module tb_emergency_scene_display;

reg         clk;
reg         rst_n;
reg         emergency_active;
reg         de;
reg  [10:0] x;
reg  [10:0] y;
reg  [23:0] bg_rgb;
reg         scroll_hit;
wire        blink_on;
wire        led_flash;
wire        beep_en;
wire [23:0] out_rgb;
wire        alarm_osd_hit;

alarm_blink_beep_ctrl #(
    .CLK_FREQ_HZ (1000),
    .BLINK_HZ    (4),
    .BEEP_HZ     (2)
) u_alarm_blink_beep_ctrl (
    .clk              (clk),
    .rst_n            (rst_n),
    .emergency_active (emergency_active),
    .blink_on         (blink_on),
    .led_flash        (led_flash),
    .beep_en          (beep_en)
);

emergency_osd_overlay u_emergency_osd_overlay (
    .de               (de),
    .x                (x),
    .y                (y),
    .bg_rgb           (bg_rgb),
    .emergency_active (emergency_active),
    .blink_on         (blink_on),
    .scroll_hit       (scroll_hit),
    .out_rgb          (out_rgb),
    .alarm_osd_hit    (alarm_osd_hit)
);

initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
end

task check_pixel;
    input [10:0] set_x;
    input [10:0] set_y;
    input        set_scroll_hit;
    input        exp_hit;
    input [23:0] exp_rgb;
    begin
        x = set_x;
        y = set_y;
        scroll_hit = set_scroll_hit;
        #1;
        $display("CHECK pixel x=%0d y=%0d hit=%b rgb=%h", x, y, alarm_osd_hit, out_rgb);
        if (alarm_osd_hit !== exp_hit || out_rgb !== exp_rgb) begin
            $display("FAIL at %0t: hit=%b rgb=%h, expected hit=%b rgb=%h",
                     $time, alarm_osd_hit, out_rgb, exp_hit, exp_rgb);
            $stop;
        end
    end
endtask

initial begin
    rst_n            = 1'b0;
    emergency_active = 1'b0;
    de               = 1'b1;
    x                = 11'd0;
    y                = 11'd0;
    bg_rgb           = 24'h102030;
    scroll_hit       = 1'b0;

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    check_pixel(11'd50, 11'd20, 1'b0, 1'b0, 24'h102030);

    emergency_active = 1'b1;
    repeat (130) @(negedge clk);
    if (blink_on !== 1'b1 || led_flash !== 1'b1) begin
        $display("FAIL at %0t: blink_on=%b led_flash=%b, expected both 1", $time, blink_on, led_flash);
        $stop;
    end
    check_pixel(11'd50, 11'd20, 1'b0, 1'b1, 24'hff2020);
    check_pixel(11'd40, 11'd90, 1'b0, 1'b1, 24'hffd24a);
    check_pixel(11'd200, 11'd100, 1'b0, 1'b1, 24'hfff0f0);
    check_pixel(11'd300, 11'd440, 1'b1, 1'b1, 24'hffffff);
    check_pixel(11'd320, 11'd240, 1'b0, 1'b0, 24'h102030);

    repeat (130) @(negedge clk);
    if (blink_on !== 1'b0 || led_flash !== 1'b0 || beep_en !== 1'b1) begin
        $display("FAIL at %0t: blink_on=%b led_flash=%b beep_en=%b, expected 0/0/1",
                 $time, blink_on, led_flash, beep_en);
        $stop;
    end
    check_pixel(11'd50, 11'd20, 1'b0, 1'b1, 24'h8a0000);

    emergency_active = 1'b0;
    repeat (2) @(negedge clk);
    if (blink_on !== 1'b0 || led_flash !== 1'b0 || beep_en !== 1'b0) begin
        $display("FAIL at %0t: outputs should clear after emergency inactive", $time);
        $stop;
    end
    check_pixel(11'd50, 11'd20, 1'b0, 1'b0, 24'h102030);

    de = 1'b0;
    emergency_active = 1'b1;
    check_pixel(11'd50, 11'd20, 1'b0, 1'b0, 24'h102030);

    $display("PASS: tb_emergency_scene_display completed.");
    $stop;
end

endmodule
