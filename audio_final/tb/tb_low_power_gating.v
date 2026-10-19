`timescale 1ns/1ps

// Low-power invariants for scene_audio_final.
// The optimization is intentionally invisible at the PCM interface:
// samples continue at 48 kHz while unused DDS phase state stays quiet.
module tb_low_power_gating;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg emergency = 1'b0;
    wire sample_valid;
    wire signed [15:0] sample_left;
    wire [2:0] state_debug;
    wire [31:0] sample_count;
    integer checks = 0;
    integer fails = 0;
    integer idle_ticks = 0;
    integer off_ticks = 0;

`ifdef POWER_ACTIVITY
    // Optional activity capture for the low-power evidence flow.  Normal
    // regressions do not emit a VCD, so the fast release suite stays fast.
    initial begin
        $dumpfile("scene_audio_lp_activity.vcd");
        $dumpvars(0, dut);
    end
`endif

    always #20 clk = ~clk; // 25 MHz

    scene_audio_final #(
        .BURST_ON_SAMPLES(32),
        .BURST_OFF_SAMPLES(32),
        .RAMP_SAMPLES(8)
    ) dut (
        .clk(clk), .rst_n(rst_n), .event_valid(1'b0),
        .menu_active(1'b0), .emergency(emergency),
        .welcome_active(1'b0), .active_scene(2'b11),
        .event_kind(2'b0), .media_id(2'b0),
        .sample_valid(sample_valid), .sample_ready(1'b1),
        .sample_left(sample_left), .sample_right(), .sample_gain(),
        .overflow(), .state_debug(state_debug), .sample_count(sample_count)
    );

    task check;
        input condition;
        input [1023:0] message;
        begin
            checks = checks + 1;
            if (condition) $display("[PASS] %0s", message);
            else begin
                fails = fails + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && dut.tick && state_debug == 3'd0) begin
            idle_ticks = idle_ticks + 1;
            check(dut.phase == 32'd0 && dut.phase2 == 32'd0 && dut.phase3 == 32'd0,
                  "DDS phases stay frozen in IDLE");
        end
        if (rst_n && dut.tick && state_debug == 3'd3 && !dut.burst_on) begin
            off_ticks = off_ticks + 1;
            check(dut.full_raw == 19'sd0, "alarm rest segment remains exact silence");
            if (off_ticks > 1)
                check(dut.phase == 32'd0 && dut.phase2 == 32'd0 && dut.phase3 == 32'd0,
                      "DDS phases stay frozen during alarm rest");
        end
    end

    initial begin
        integer count_before_rest;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        wait (idle_ticks >= 8);
        // sample_count is updated nonblocking on the same edge as idle_ticks,
        // so it may be one count behind at this observation point.
        check(sample_count >= idle_ticks - 1,
              "48 kHz sample cadence continues in IDLE");
        emergency = 1'b1;
        wait (state_debug == 3'd3 && !dut.burst_on);
        count_before_rest = sample_count;
        wait (off_ticks >= 16);
        check(state_debug == 3'd3, "emergency state remains ALARM");
        check(sample_count >= count_before_rest + 15,
              "48 kHz sample cadence continues during alarm rest");
        if (fails == 0) $display("ALL TESTS PASSED (checks %0d)", checks);
        else $display("TEST FAILED (%0d/%0d failed)", fails, checks);
        $finish;
    end
endmodule
