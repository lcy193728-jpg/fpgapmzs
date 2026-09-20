`timescale 1ns/1ps
//=====================================================================
// Verifies the on-chip SYNTHESIZED air-raid siren in scene_audio_final:
//   * enters ALARM when emergency rises
//   * tone frequency sweeps 400 -> 1000 -> 400 Hz with a 3 s period
//     (measured as zero-crossings per 0.5 s of audio time == Hz)
//   * continuous output (no audible silence) and the same peak as the PC
//     preview siren_preview_400-1000Hz.wav
// Expected block readings (0.5 s averages, 1.5 s per sweep direction):
//   blk1 ~500  blk2 ~700  blk3 ~900  blk4 ~900  blk5 ~700  blk6 ~500 Hz
//=====================================================================
module tb_siren_dds;
    reg clk=0, rst_n=0, emergency=0;
    wire sample_valid; reg sample_ready=1;
    wire signed [15:0] sample_left, sample_right;
    wire [8:0] sample_gain;
    wire overflow; wire [2:0] state_debug; wire [31:0] sample_count;

    always #20 clk = ~clk;                       // 25 MHz

    scene_audio_final dut(
      .clk(clk), .rst_n(rst_n), .event_valid(1'b0), .menu_active(1'b0),
      .emergency(emergency), .active_scene(2'b11), .event_kind(2'b0), .media_id(2'b0),
      .sample_valid(sample_valid), .sample_ready(sample_ready),
      .sample_left(sample_left), .sample_right(sample_right),
      .sample_gain(sample_gain), .overflow(overflow), .state_debug(state_debug),
      .sample_count(sample_count));

    integer nsamp=0, zc=0, peak=0, zeros=0, run=0, maxrun=0;
    integer blk=0, f1=0, f3=0, f6=0, f_last=0;
    integer checks=0, fails=0;
    reg signed [15:0] prev=0;

    always @(posedge clk) begin
        if (sample_valid && sample_ready) begin
            if (nsamp>0 && ((sample_left>=0) != (prev>=0))) zc = zc + 1;
            if (sample_left > peak)  peak = sample_left;
            if (-sample_left > peak) peak = -sample_left;
            if (sample_left == 0) begin zeros=zeros+1; run=run+1; end
            else begin if (run>maxrun) maxrun=run; run=0; end
            prev = sample_left;
            nsamp = nsamp + 1;
            if (nsamp % 24000 == 0) begin
                blk = blk + 1;
                $display("  [AUDIO] t=%0.2f s   freq~%0d Hz   state=%0d", nsamp/48000.0, zc, state_debug);
                if (blk==1) f1 = zc;
                if (blk==3) f3 = zc;
                if (blk==6) f6 = zc;
                f_last = zc;
                zc = 0;
            end
        end
    end

    task check; input cond; input [255:0] msg;
    begin
        checks = checks + 1;
        if (cond) $display("  [PASS] %0s", msg);
        else begin fails = fails + 1; $display("  [FAIL] %0s", msg); end
    end endtask

    initial begin
        repeat(20) @(posedge clk);
        rst_n = 1;
        #100000;
        $display("======== synthesized siren (emergency=1) ========");
        emergency = 1;
        wait (nsamp >= 168000);                  // 3.5 s of audio time (>= 1 full 3 s sweep)
        $display("---- summary ----");
        $display("  samples=%0d  peak=%0d  zero-samples=%0d  longest zero run=%0d",
                 nsamp, peak, zeros, maxrun);
        $display("  0.5s block freq: blk1=%0d Hz  blk3=%0d Hz  blk6=%0d Hz  last=%0d Hz",
                 f1, f3, f6, f_last);
        check(state_debug==3'd3,  "state is ALARM(3)");
        check(peak>17000 && peak<22000, "peak matches the PC preview (~19900)");
        check(maxrun<4800,        "no audible silence (longest zero run < 100 ms)");
        check(f1>440 && f1<560,   "at 0.5 s the tone is rising from the low end (~500 Hz)");
        check(f3>820 && f3<980,   "at 1.5 s the tone is near the high end (~900 Hz)");
        check(f6>440 && f6<560,   "at 3.0 s the sweep returned to the low end (~500 Hz, 3 s period)");
        if (fails==0) $display("ALL TESTS PASSED  (checks %0d)", checks);
        else          $display("TEST FAILED  (%0d/%0d failed)", fails, checks);
        $finish;
    end
endmodule
