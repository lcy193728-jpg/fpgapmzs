`timescale 1ns/1ps
//=====================================================================
// Verifies the on-chip SYNTHESIZED air-raid siren in scene_audio_final
// after the 2026-09-21 national-standard rework (blast 6 s / rest 6 s loop):
//
//   DUT1 (default parameters, real 6 s/6 s):
//       * state becomes ALARM(3) after emergency rises
//       * peak matches the PC preview (~19900), i.e. the blast plays at
//         full loudness
//       * inside the blast the 400->1000->400 Hz triangle sweep is
//         unchanged (3 s period): blk1~500  blk3~900  blk6~500 Hz
//       * the default blast length MUST be 6.000 s @48 kHz = 288000 samples
//       * no silence inside the first 3.5 s (first blast is continuous)
//       * still inside the blast at 3.5 s (burst_on=1)
//
//   DUT2 (scaled parameters 2400/2400 = 50 ms, only to exercise the gating
//        logic itself in a short simulation):
//       * blast length is exactly 2400 samples, rest length exactly 2400
//       * the rest segment output is exactly 0 (true silence)
//       * the release ramp reaches gain 0 at the burst end and the next burst
//         starts from gain 1 (no click at either edge)
//       * every blast restarts the sweep at 400 Hz
//     Everything is strobed on dut2.tick (one per 48 kHz sample) so that
//     burst_on / burst_cnt / gain / full_raw are read from the SAME sample.
//     Counting runs of non-zero PCM instead cannot work: the 4:2:1 harmonic
//     mix passes through zero many times inside one blast, and the 32-deep
//     output FIFO shifts the edges seen at the port.
//=====================================================================
module tb_siren_dds;
    // ---------- DUT1: default parameters ----------
    reg clk=0, rst_n=0, emergency=0;
    wire sample_valid; reg sample_ready=1;
    wire signed [15:0] sample_left, sample_right;
    wire [8:0] sample_gain;
    wire overflow; wire [2:0] state_debug; wire [31:0] sample_count;
    wire [2:0] state2; wire signed [15:0] s2_left; wire [8:0] s2_gain;
    wire s2_valid; reg s2_ready=1;

    always #20 clk = ~clk;                       // 25 MHz

    scene_audio_final dut(
      .clk(clk), .rst_n(rst_n), .event_valid(1'b0), .menu_active(1'b0),
      .emergency(emergency), .active_scene(2'b11), .event_kind(2'b0), .media_id(2'b0),
      .sample_valid(sample_valid), .sample_ready(sample_ready),
      .sample_left(sample_left), .sample_right(sample_right),
      .sample_gain(sample_gain), .overflow(overflow), .state_debug(state_debug),
      .sample_count(sample_count));

    // ---------- DUT2: scaled burst length (50 ms/50 ms) ----------
    scene_audio_final #(
      .BURST_ON_SAMPLES(2400), .BURST_OFF_SAMPLES(2400)
    ) dut2(
      .clk(clk), .rst_n(rst_n), .event_valid(1'b0), .menu_active(1'b0),
      .emergency(emergency), .active_scene(2'b11), .event_kind(2'b0), .media_id(2'b0),
      .sample_valid(s2_valid), .sample_ready(s2_ready),
      .sample_left(s2_left), .sample_right(), .sample_gain(s2_gain),
      .overflow(), .state_debug(state2), .sample_count());

    integer nsamp=0, zc=0, peak=0, zeros=0, run=0, maxrun=0;
    integer blk=0, f1=0, f3=0, f6=0;
    integer checks=0, fails=0;
    reg signed [15:0] prev=0;
    reg burst_on_at_3p5s=0;

    always @(posedge clk) begin
        if (sample_valid && sample_ready) begin
            if (nsamp>0 && ((sample_left>=0) != (prev>=0))) zc = zc + 1;
            if (sample_left > peak)  peak = sample_left;
            if (-sample_left > peak) peak = -sample_left;
            if (sample_left == 0) begin zeros=zeros+1; run=run+1; end
            else begin if (run>maxrun) maxrun=run; run=0; end
            prev = sample_left;
            nsamp = nsamp + 1;
            if (nsamp == 168000) burst_on_at_3p5s = dut.burst_on;   // 3.5 s snapshot
            if (nsamp % 24000 == 0) begin
                blk = blk + 1;
                $display("  [DUT1] t=%0.2f s   freq~%0d Hz   state=%0d burst_on=%0d",
                         nsamp/48000.0, zc, state_debug, dut.burst_on);
                if (blk==1) f1 = zc;
                if (blk==3) f3 = zc;
                if (blk==6) f6 = zc;
                zc = 0;
            end
        end
    end

    // ---------- DUT2 burst-gating measurement ----------
    integer meas_en=0, prev_on=1, on_run=0, off_run=0, on_runs=0, off_runs=0;
    integer min_on=999999, max_on=0, min_off=999999, max_off=0;
    integer seg_errors=0, cycles=0, restart_ok=0, off_nonzero=0;
    integer on_first=0, off_first=0, rel_end_gain=-1, att_first_gain=-1;
    integer on_gmax=0, on_gmin=999;

    always @(posedge clk) begin
        if (dut2.tick && state2==3'd3) begin
            if (!meas_en) begin
                meas_en = 1;                       // first blast tick after entry
                prev_on = dut2.burst_on;
                on_run  = 1;
                on_gmax = dut2.gain;
                on_gmin = dut2.gain;
            end else if (dut2.burst_on) begin
                if (!prev_on) begin                // rest -> blast: a rest ended
                    off_runs = off_runs + 1;
                    if (off_first == 0) off_first = off_run;
                    if (off_run > max_off) max_off = off_run;
                    if (off_run < min_off) min_off = off_run;
                    if (off_run != dut2.BURST_OFF_SAMPLES) seg_errors = seg_errors + 1;
                    att_first_gain = dut2.gain;    // gain of the first blast sample
                    if ((dut2.siren_inc <= dut2.SIREN_INC_LOW + 64)
                        && (dut2.siren_rising == 1'b1)) restart_ok = restart_ok + 1;
                    cycles = cycles + 1;
                    on_run  = 1;
                    off_run = 0;
                    on_gmax = dut2.gain;
                    on_gmin = dut2.gain;
                end else begin
                    on_run = on_run + 1;
                    if (dut2.gain > on_gmax) on_gmax = dut2.gain;
                    if (dut2.gain < on_gmin) on_gmin = dut2.gain;
                end
                prev_on = 1;
            end else begin                         // rest segment: must be silence
                if (prev_on) begin                 // blast -> rest: a blast ended
                    on_runs = on_runs + 1;
                    if (on_first == 0) on_first = on_run;
                    if (on_run > max_on) max_on = on_run;
                    if (on_run < min_on) min_on = on_run;
                    if (on_run != dut2.BURST_ON_SAMPLES) seg_errors = seg_errors + 1;
                    rel_end_gain = on_gmin;        // release ramp must reach 0
                    if (on_gmax != 256) seg_errors = seg_errors + 1;
                end
                if (dut2.full_raw != 19'sd0) off_nonzero = off_nonzero + 1;
                off_run = off_run + 1;
                prev_on = 0;
            end
        end
    end

    task check; input cond; input [1023:0] msg;
    begin
        checks = checks + 1;
        if (cond) $display("  [PASS] %0s", msg);
        else begin fails = fails + 1; $display("  [FAIL] %0s", msg); end
    end endtask

    initial begin
        repeat(20) @(posedge clk);
        rst_n = 1;
        #100000;
        $display("======== DUT1: default 6 s / 6 s (emergency=1) ========");
        emergency = 1;
        wait (nsamp >= 168000);                  // 3.5 s of audio time
        $display("---- DUT1 summary ----");
        $display("  samples=%0d  peak=%0d  zero-samples=%0d  longest zero run=%0d",
                 nsamp, peak, zeros, maxrun);
        $display("  0.5s block freq: blk1=%0d Hz  blk3=%0d Hz  blk6=%0d Hz", f1, f3, f6);
        $display("  burst parameters: ON=%0d  OFF=%0d samples",
                 dut.BURST_ON_SAMPLES, dut.BURST_OFF_SAMPLES);
        check(state_debug==3'd3,  "state is ALARM(3)");
        check(peak>17000 && peak<22000, "peak matches the PC preview (~19900)");
        check(dut.BURST_ON_SAMPLES==288000 && dut.BURST_OFF_SAMPLES==288000,
              "burst length = 6.000 s @48 kHz (288000 samples)");
        check(maxrun<4800,        "no silence inside the first 3.5 s (first blast is continuous)");
        check(burst_on_at_3p5s==1'b1, "still inside the blast at 3.5 s (burst_on=1)");
        check(f1>440 && f1<560,   "at 0.5 s the tone is rising from the low end (~500 Hz)");
        check(f3>820 && f3<980,   "at 1.5 s the tone is near the high end (~900 Hz)");
        check(f6>440 && f6<560,   "at 3.0 s the sweep returned to the low end (~500 Hz, 3 s period)");

        // ---------- DUT2: gating logic with scaled burst length ----------
        $display("---- DUT2 (2400/2400 samples = 50 ms) waiting for 8 full cycles ----");
        wait (cycles >= 8);
        $display("---- DUT2 summary (%0d full cycles) ----", cycles);
        $display("  blast: first=%0d min=%0d max=%0d   rest: first=%0d min=%0d max=%0d",
                 on_first, min_on, max_on, off_first, min_off, max_off);
        $display("  gain inside blast: max=%0d (want 256)  release end=%0d  attack start=%0d",
                 on_gmax, rel_end_gain, att_first_gain);
        $display("  non-zero PCM during rest=%0d   sweep restarts at 400 Hz=%0d   seg_errors=%0d",
                 off_nonzero, restart_ok, seg_errors);
        check(min_on==dut2.BURST_ON_SAMPLES && max_on==dut2.BURST_ON_SAMPLES,
              "blast length is exactly 2400 samples (6 s scaled to 50 ms)");
        check(min_off==dut2.BURST_OFF_SAMPLES && max_off==dut2.BURST_OFF_SAMPLES,
              "rest length is exactly 2400 samples (6 s scaled to 50 ms)");
        check(seg_errors==0,      "every segment length exact and every blast reaches full gain");
        check(off_nonzero==0,     "the rest segment output is exactly 0 (true silence)");
        check(rel_end_gain==0,    "release ramp reaches gain 0 at the blast end (no click)");
        check(att_first_gain==1,  "the next blast starts from gain 1 (no click)");
        check(restart_ok>=6,      "every blast restarts the sweep at 400 Hz");

        if (fails==0) $display("ALL TESTS PASSED  (checks %0d)", checks);
        else          $display("TEST FAILED  (%0d/%0d failed)", fails, checks);
        $finish;
    end
endmodule