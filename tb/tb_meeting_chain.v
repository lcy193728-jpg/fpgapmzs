`timescale 1ns/1ps
//====================================================================
// TB : tb_meeting_chain.v -- integration self-check for the meeting scene
//
// Coverage (same instantiation style as top.v):
//   A) meeting_cfg  : sd-domain MTG1 byte writes -> video-domain snapshots
//   B) meeting_ctrl : meeting timer FSM (start/pause/resume/next/prev/
//                     restart/warning/timeout/finished/home/alarm/uptime)
//   C) meeting_fmt  : serial BCD (divide-by-60 first) and progress divide
//   D) meeting_osd  : panel background, separators, ink, alarm layer,
//                     notice page cycling, overview line index
//
// Notes:
//   * meeting_osd.v `includes meeting_fmt.v / meeting_glyph_rom.v internally
//     (exactly like top.v), so this TB only instantiates
//     meeting_cfg / meeting_ctrl / meeting_osd.
//   * meeting_ctrl is instantiated with SEC_CYCLES=4 so "1 second = 4 clk",
//     otherwise the sim could never reach timeout/finished. On board it is
//     25_000_000 (1 s at 25 MHz video clock); the logic is identical.
//   * video domain 25 MHz (40 ns), SD domain 100 MHz (10 ns).
//   * Messages are intentionally ASCII so transcripts stay readable.
//====================================================================
module tb_meeting_chain;

//--------------------------------------------------------------------
// clocks / reset
//--------------------------------------------------------------------
reg clk    = 1'b0;      // video 25 MHz
reg wr_clk = 1'b0;      // SD   100 MHz
always #20 clk    = ~clk;
always #5  wr_clk = ~wr_clk;

integer checks = 0;
integer errors = 0;

task chk;
    input               cond;
    input [8*96-1:0]    msg;
    begin
        checks = checks + 1;
        if (!cond) begin
            errors = errors + 1;
            $display("  [FAIL] %0s   (t=%0t)", msg, $time);
        end else begin
            $display("  [PASS] %0s", msg);
        end
    end
endtask

//====================================================================
// A) meeting_cfg
//====================================================================
reg         cfg_rst      = 1'b1;
reg         wr_en        = 1'b0;
reg  [10:0] wr_addr      = 11'd0;
reg  [7:0]  wr_data      = 8'h00;
reg         cfg_ready    = 1'b0;
reg         cfg_error    = 1'b0;
reg  [4:0]  cfg_total    = 5'd0;
reg  [3:0]  cfg_current  = 4'd0;
reg  [1:0]  cfg_notice   = 2'd0;
reg  [3:0]  cfg_ovidx    = 4'd0;

wire        c_ready, c_error;
wire [4:0]  c_total;
wire [3:0]  c_current;
wire [15:0] c_duration, c_nextdur;
wire [319:0] c_title, c_nexttitle, c_name, c_org, c_venue, c_notice, c_ovtitle;
wire [159:0] c_speaker, c_nextspeaker;

meeting_cfg u_cfg (
    .wr_clk        (wr_clk       ),
    .wr_en         (wr_en        ),
    .wr_addr       (wr_addr      ),
    .wr_data       (wr_data      ),
    .cfg_ready     (cfg_ready    ),
    .cfg_error     (cfg_error    ),
    .cfg_total     (cfg_total    ),
    .cfg_current   (cfg_current  ),
    .clk           (clk          ),
    .rst           (cfg_rst      ),
    .notice_sel    (cfg_notice   ),
    .overview_index(cfg_ovidx    ),
    .ready         (c_ready      ),
    .error         (c_error      ),
    .total         (c_total      ),
    .current       (c_current    ),
    .duration      (c_duration   ),
    .next_duration (c_nextdur    ),
    .title         (c_title      ),
    .meeting_name  (c_name       ),
    .organizer     (c_org        ),
    .venue         (c_venue      ),
    .notice        (c_notice     ),
    .overview_title(c_ovtitle    ),
    .speaker       (c_speaker    ),
    .next_title    (c_nexttitle  ),
    .next_speaker  (c_nextspeaker)
);

task cfg_put;
    input [10:0] a;
    input [7:0]  d;
    begin
        wr_addr = a; wr_data = d; wr_en = 1'b1;
        @(posedge wr_clk); #1;
        wr_en = 1'b0;
        @(posedge wr_clk); #1;
    end
endtask

integer i;
reg [7:0] bpat;
initial begin
    //--------------------------------------------------------------
    // load all 1272 bytes (default 0x11, then mark key bytes)
    //   [0..39] name  [40..79] organizer  [80..119] venue
    //   [120..279] notice page 0..3 (40B each)
    //   [280+i*62 ..] item i: +0/+1 duration (big endian)
    //                         +2..41 title  +42..61 speaker
    //--------------------------------------------------------------
    @(negedge clk);
    for (i = 0; i < 1272; i = i + 1) begin
        bpat = 8'h11;
        case (i)
        0:   bpat = 8'h41;      39:  bpat = 8'h5A;   // name first/last
        40:  bpat = 8'h43;      79:  bpat = 8'h44;   // organizer
        80:  bpat = 8'h45;      119: bpat = 8'h46;   // venue
        120: bpat = 8'h47;      159: bpat = 8'h48;   // notice page 0
        280: bpat = 8'h00;      281: bpat = 8'h7D;   // item0 duration = 125
        282: bpat = 8'h4B;      321: bpat = 8'h4C;   // item0 title
        322: bpat = 8'h4D;      341: bpat = 8'h4E;   // item0 speaker
        342: bpat = 8'h00;      343: bpat = 8'h3C;   // item1 duration = 60
        344: bpat = 8'h4F;      383: bpat = 8'h50;   // item1 title
        384: bpat = 8'h51;      403: bpat = 8'h52;   // item1 speaker
        default: bpat = 8'h11;
        endcase
        cfg_put(i[10:0], bpat);
    end

    cfg_total   = 5'd2;
    cfg_current = 4'd0;
    cfg_error   = 1'b0;
    cfg_ready   = 1'b1;

    repeat (4) @(posedge clk);
    cfg_rst = 1'b0;
    repeat (1500) @(posedge clk);
    #1;

    $display("");
    $display("======== A) meeting_cfg snapshots ========");
    chk(c_ready   == 1'b1,    "cfg: ready asserted");
    chk(c_error   == 1'b0,    "cfg: error stays 0");
    chk(c_total   == 5'd2,    "cfg: total = 2");
    chk(c_current == 4'd0,    "cfg: current = 0");
    chk(c_duration== 16'd125, "cfg: item0 duration = 125");
    chk(c_nextdur == 16'd60,  "cfg: item1 duration = 60");
    // snapshot shifts left: first byte read lands in [319:312]
    chk(c_name [319:312] == 8'h41, "cfg: name first byte");
    chk(c_name [  7:  0] == 8'h5A, "cfg: name last byte");
    chk(c_org  [319:312] == 8'h43, "cfg: organizer first byte");
    chk(c_org  [  7:  0] == 8'h44, "cfg: organizer last byte");
    chk(c_venue[319:312] == 8'h45, "cfg: venue first byte");
    chk(c_venue[  7:  0] == 8'h46, "cfg: venue last byte");
    chk(c_title[319:312] == 8'h4B, "cfg: item0 title first byte");
    chk(c_title[  7:  0] == 8'h4C, "cfg: item0 title last byte");
    // speaker is 20 bytes = 160 bit, so the first byte read lands in [159:152]
    chk(c_speaker[159:152] == 8'h4D, "cfg: item0 speaker first byte");
    chk(c_speaker[  7:  0] == 8'h4E, "cfg: item0 speaker last byte");
    chk(c_nexttitle[319:312] == 8'h4F, "cfg: item1 title first byte");
    chk(c_nextspeaker[159:152] == 8'h51, "cfg: item1 speaker first byte");
    chk(c_notice[319:312] == 8'h47, "cfg: notice page0 first byte");
    chk(c_notice[  7:  0] == 8'h48, "cfg: notice page0 last byte");

    // switch current item -> snapshot must rescan
    cfg_current = 4'd1;
    repeat (400) @(posedge clk);
    #1;
    chk(c_current  == 4'd1,     "cfg: current follows to 1");
    chk(c_duration == 16'd60,   "cfg: item1 duration = 60");
    chk(c_title[319:312] == 8'h4F, "cfg: title refreshed after switch");

    $display("  [INFO] dump name  hi=%02h lo=%02h", c_name[319:312],  c_name[7:0]);
    $display("  [INFO] dump org   hi=%02h lo=%02h", c_org [319:312],  c_org [7:0]);
    $display("  [INFO] dump venue hi=%02h lo=%02h", c_venue[319:312], c_venue[7:0]);
    $display("  [INFO] dump title hi=%02h lo=%02h", c_title[319:312], c_title[7:0]);
    $display("  [INFO] dump spk   hi=%02h lo=%02h", c_speaker[159:152], c_speaker[7:0]);
    $display("  [INFO] dump notic hi=%02h lo=%02h", c_notice[319:312], c_notice[7:0]);
    $display("  [INFO] dump nttl  hi=%02h lo=%02h", c_nexttitle[319:312], c_nexttitle[7:0]);

//====================================================================
// B) meeting_ctrl  (SEC_CYCLES=4)
//====================================================================
    $display("");
    $display("======== B) meeting_ctrl timer FSM ========");
    run_ctrl;

//====================================================================
// C) meeting_fmt
//====================================================================
    $display("");
    $display("======== C) meeting_fmt formatting ========");
    run_fmt;

//====================================================================
// D) meeting_osd
//====================================================================
    $display("");
    $display("======== D) meeting_osd overlay ========");
    run_osd;

    //--------------------------------------------------------------
    $display("");
    $display("================================================");
    $display("checks %0d, failed %0d", checks, errors);
    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("TEST FAILED");
    $display("================================================");
    $finish;
end

//====================================================================
// B) meeting_ctrl
//====================================================================
reg         k_rst     = 1'b1;
reg         k_en      = 1'b0;
reg         k_cfgok   = 1'b0;
reg         k_alarm   = 1'b0;
reg  [3:0]  k_press   = 4'b0000;
reg         k_end     = 1'b0;
reg         k_home    = 1'b0;
reg  [4:0]  k_total   = 5'd2;
reg  [15:0] k_dur     = 16'd61;

wire [2:0]  k_state;
wire [3:0]  k_cur;
wire [15:0] k_rem, k_ot;
wire        k_ap, k_we, k_te;
wire [31:0] k_up;

meeting_ctrl #(.SEC_CYCLES(4)) u_ctrl (
    .clk          (clk      ),
    .rst          (k_rst    ),
    .en           (k_en     ),
    .config_ready (k_cfgok  ),
    .alarm        (k_alarm  ),
    .press        (k_press  ),
    .end_long     (k_end    ),
    .home_long    (k_home   ),
    .total        (k_total  ),
    .duration     (k_dur    ),
    .state        (k_state  ),
    .current      (k_cur    ),
    .remaining    (k_rem    ),
    .overtime     (k_ot     ),
    .alarm_paused (k_ap     ),
    .warn_event   (k_we     ),
    .timeout_event(k_te     ),
    .uptime       (k_up     )
);

// sticky event capture: the pulse is exactly one clk wide, and this monitor
// samples the pre-edge value, so it needs one extra edge to latch it.
reg warn_seen = 1'b0;
reg to_seen   = 1'b0;
always @(posedge clk) begin
    if (k_we) warn_seen <= 1'b1;
    if (k_te) to_seen   <= 1'b1;
end

task key;
    input [3:0] b;
    begin
        k_press = b;
        @(posedge clk); #1;
        k_press = 4'b0000;
        @(posedge clk); #1;
    end
endtask

task wait_st;
    input  [2:0]  s;
    input integer maxc;
    output        ok;
    integer n;
    begin
        ok = 1'b0;
        for (n = 0; n < maxc; n = n + 1) begin
            @(posedge clk); #1;
            if (k_state === s) begin ok = 1'b1; n = maxc; end
        end
    end
endtask

task wait_active;      // RUNNING(1) or WARNING(3) or TIMEOUT(4)
    input integer maxc;
    output        ok;
    integer n;
    begin
        ok = 1'b0;
        for (n = 0; n < maxc; n = n + 1) begin
            @(posedge clk); #1;
            if (k_state === 3'd1 || k_state === 3'd3 || k_state === 3'd4) begin
                ok = 1'b1; n = maxc;
            end
        end
    end
endtask

reg okv;
task run_ctrl;
    reg [15:0] r0;
    reg [31:0] u0;
    begin
        repeat (4) @(posedge clk);
        k_rst = 1'b0;
        repeat (4) @(posedge clk); #1;
        chk(k_state == 3'd0, "ctrl: IDLE after reset");
        chk(k_cur   == 4'd0, "ctrl: current=0 after reset");

        // ---- start ----
        k_en = 1'b1; k_cfgok = 1'b1;
        key(4'b0001);
        wait_st(3'd1, 20, okv);
        chk(okv == 1'b1,            "ctrl: start -> RUNNING");
        chk(k_rem >= k_dur - 16'd2, "ctrl: start loads item duration");
        chk(k_cur == 4'd0,          "ctrl: start keeps item 0");

        // ---- warning ----
        wait_st(3'd3, 40, okv);
        chk(okv == 1'b1,        "ctrl: remaining <=60 -> WARNING");
        repeat (4) @(posedge clk);
        chk(warn_seen == 1'b1,  "ctrl: warn_event pulsed");
        chk(k_rem <= 16'd60,    "ctrl: WARNING with remaining <=60");

        // ---- pause / resume ----
        key(4'b0001);
        wait_st(3'd2, 20, okv);
        chk(okv == 1'b1, "ctrl: second press -> PAUSED");
        r0 = k_rem;
        repeat (40) @(posedge clk); #1;
        chk(k_rem == r0,  "ctrl: countdown frozen while PAUSED");
        chk(k_ot  == 16'd0, "ctrl: overtime 0 while PAUSED");
        key(4'b0001);
        wait_active(20, okv);
        chk(okv == 1'b1, "ctrl: resume -> counting again");

        // ---- timeout ----
        wait_st(3'd4, 4000, okv);
        chk(okv == 1'b1, "ctrl: countdown to 0 -> TIMEOUT");
        repeat (4) @(posedge clk);
        chk(to_seen == 1'b1, "ctrl: timeout_event pulsed");
        repeat (40) @(posedge clk); #1;
        chk(k_ot != 16'd0, "ctrl: overtime counts up in TIMEOUT");

        // ---- next item ----
        key(4'b0010);
        wait_st(3'd1, 30, okv);
        chk(okv == 1'b1,            "ctrl: next -> RUNNING");
        chk(k_cur == 4'd1,          "ctrl: next -> current = 1");
        chk(k_rem >= k_dur - 16'd2, "ctrl: next reloads duration");
        chk(k_ot  == 16'd0,         "ctrl: next clears overtime");

        // ---- previous item ----
        repeat (20) @(posedge clk);
        key(4'b0100);
        wait_st(3'd1, 30, okv);
        chk(okv == 1'b1,   "ctrl: prev -> RUNNING");
        chk(k_cur == 4'd0, "ctrl: prev -> current = 0");

        // ---- restart current item ----
        repeat (20) @(posedge clk); #1;
        r0 = k_rem;
        key(4'b1000);
        wait_st(3'd1, 30, okv);
        chk(okv == 1'b1,                    "ctrl: restart -> RUNNING");
        chk(k_rem > r0 || k_rem >= k_dur - 16'd2,
                                            "ctrl: restart reloads full duration");

        // ---- uptime free running ----
        u0 = k_up;
        repeat (100) @(posedge clk); #1;
        chk(k_up > u0, "ctrl: uptime keeps counting");

        // ---- finished / home ----
        k_end = 1'b1; @(posedge clk); #1; k_end = 1'b0;
        wait_st(3'd6, 20, okv);
        chk(okv == 1'b1, "ctrl: end_long -> FINISHED");
        k_alarm = 1'b1; repeat (4) @(posedge clk); #1;
        chk(k_state == 3'd6, "ctrl: alarm ignored while FINISHED");
        k_alarm = 1'b0;
        k_home = 1'b1; @(posedge clk); #1; k_home = 1'b0;
        wait_st(3'd0, 20, okv);
        chk(okv == 1'b1, "ctrl: home_long -> IDLE");
        chk(k_ap == 1'b0, "ctrl: alarm_paused cleared in IDLE");

        // ---- emergency alarm ----
        key(4'b0001);
        wait_st(3'd1, 20, okv);
        chk(okv == 1'b1, "ctrl: restart counting for alarm test");
        k_alarm = 1'b1; repeat (4) @(posedge clk); #1;
        chk(k_state == 3'd2, "ctrl: alarm -> PAUSED immediately");
        chk(k_ap    == 1'b1, "ctrl: alarm_paused = 1 during alarm");
        k_alarm = 1'b0;
        key(4'b0001);
        wait_active(30, okv);
        chk(okv == 1'b1, "ctrl: resume after alarm clears");
        chk(k_rem >= k_dur - 16'd2, "ctrl: alarm resume reloads duration");

        // ---- last item + next -> FINISHED ----
        key(4'b0010);
        wait_st(3'd1, 30, okv);
        key(4'b0010);
        wait_st(3'd6, 30, okv);
        chk(okv == 1'b1, "ctrl: next on last item -> FINISHED");

        // ---- leave meeting mode ----
        k_home = 1'b1; @(posedge clk); #1; k_home = 1'b0;
        repeat (10) @(posedge clk); #1;
        k_en = 1'b0;
        repeat (10) @(posedge clk); #1;
        chk(k_state == 3'd0, "ctrl: stays IDLE after leaving meeting mode");
    end
endtask

//====================================================================
// C) meeting_fmt
//====================================================================
reg         f_rst  = 1'b1;
reg  [15:0] f_rem  = 16'd0;
reg  [15:0] f_ot   = 16'd0;
reg  [15:0] f_nd   = 16'd0;
reg  [31:0] f_up   = 32'd0;
reg  [3:0]  f_cur  = 4'd0;
reg  [4:0]  f_tot  = 5'd0;

wire [19:0] f_rembcd, f_otbcd, f_ndbcd;
wire [39:0] f_upbcd;
wire [13:0] f_prog;

meeting_fmt u_fmt (
    .clk          (clk      ),
    .rst          (f_rst    ),
    .remaining    (f_rem    ),
    .overtime     (f_ot     ),
    .next_duration(f_nd     ),
    .uptime       (f_up     ),
    .current      (f_cur    ),
    .total        (f_tot    ),
    .rem_bcd      (f_rembcd ),
    .ot_bcd       (f_otbcd  ),
    .nd_bcd       (f_ndbcd  ),
    .up_bcd       (f_upbcd  ),
    .progress     (f_prog   )
);

task run_fmt;
    begin
        // 125 s -> 02:05 ; 5999 s -> 99:59 ; 60 s -> 01:00
        // 3725 s = 1h02m05s ; 592*1/2 = 296
        f_rem = 16'd125; f_ot = 16'd5999; f_nd = 16'd60;
        f_up  = 32'd3725; f_cur = 4'd1;  f_tot = 5'd2;
        repeat (4) @(posedge clk);
        f_rst = 1'b0;
        // 15 jobs x 34 clk = 510 clk, 3x margin
        repeat (1600) @(posedge clk);
        #1;

        $display("  [INFO] fmt dump rem=%05h ot=%05h nd=%05h up=%06h prog=%0d",
                 f_rembcd, f_otbcd, f_ndbcd, f_upbcd[23:0], f_prog);

        chk(f_rembcd[15:8] == 8'h02 && f_rembcd[7:0] == 8'h05,
            "fmt: 125 s -> 02:05");
        chk(f_otbcd [15:8] == 8'h99 && f_otbcd [7:0] == 8'h59,
            "fmt: 5999 s -> 99:59");
        chk(f_ndbcd [15:8] == 8'h01 && f_ndbcd [7:0] == 8'h00,
            "fmt: 60 s -> 01:00");
        chk(f_upbcd [23:16] == 8'h01 && f_upbcd [15:8] == 8'h02
         && f_upbcd [ 7: 0] == 8'h05,
            "fmt: 3725 s -> 01:02:05");
        chk(f_prog == 14'd296, "fmt: progress = 592*1/2 = 296");

        // boundaries
        f_rem = 16'd0; f_ot = 16'd0; f_cur = 4'd0; f_tot = 5'd0;
        repeat (1600) @(posedge clk);
        #1;
        chk(f_rembcd == 20'h00000, "fmt: 0 s -> 00:00");
        chk(f_otbcd  == 20'h00000, "fmt: 0 s overtime -> 00:00");
        chk(f_prog   == 14'd0,     "fmt: total=0 -> progress 0 (no div by 0)");
    end
endtask

//====================================================================
// D) meeting_osd
//====================================================================
reg         o_rst   = 1'b1;
reg         o_en    = 1'b0;
reg         o_alarm = 1'b0;
reg         o_hs    = 1'b1;
reg         o_vs    = 1'b0;
reg         o_de    = 1'b0;
reg  [23:0] o_data  = 24'hFFFFFF;
reg  [11:0] o_x     = 12'd0;
reg  [11:0] o_y     = 12'd0;
reg  [2:0]  o_state = 3'd0;
reg  [3:0]  o_cur   = 4'd0;
reg  [4:0]  o_tot   = 5'd2;
reg  [15:0] o_rem   = 16'd0;
reg  [15:0] o_ot    = 16'd0;
reg  [15:0] o_dur   = 16'd0;
reg  [15:0] o_nd    = 16'd0;
reg  [31:0] o_up    = 32'd0;
reg         o_ap    = 1'b0;
reg  [319:0] o_title = 320'd0, o_ntitle = 320'd0, o_name = 320'd0;
reg  [319:0] o_org   = 320'd0, o_venue  = 320'd0, o_notice = 320'd0;
reg  [319:0] o_ovt   = 320'd0;
reg  [159:0] o_spk   = 160'd0, o_nspk = 160'd0;

wire        o_hso, o_vso, o_deo;
wire [23:0] o_datao;
wire [11:0] o_xo, o_yo;
wire [1:0]  o_nsel;
wire [3:0]  o_ovidx;

meeting_osd u_osd (
    .clk (clk), .rst (o_rst), .en (o_en), .alarm (o_alarm),
    .hs_i(o_hs), .vs_i(o_vs), .de_i(o_de), .data_i(o_data),
    .px_x(o_x), .px_y(o_y),
    .state(o_state), .current(o_cur), .total(o_tot),
    .remaining(o_rem), .overtime(o_ot), .duration(o_dur),
    .next_duration(o_nd), .uptime(o_up), .alarm_paused(o_ap),
    .title(o_title), .next_title(o_ntitle), .meeting_name(o_name),
    .organizer(o_org), .venue(o_venue), .notice(o_notice),
    .overview_title(o_ovt), .speaker(o_spk), .next_speaker(o_nspk),
    .hs_o(o_hso), .vs_o(o_vso), .de_o(o_deo), .data_o(o_datao),
    .px_x_o(o_xo), .px_y_o(o_yo),
    .notice_sel(o_nsel), .overview_index(o_ovidx)
);

reg [23:0] pix;
task get_pix;
    input [11:0] xx;
    input [11:0] yy;
    begin
        o_x = xx; o_y = yy;
        @(posedge clk); #1;
        pix = o_datao;
    end
endtask

integer cnt_ink, cnt_green, cnt_bg, px, py;
task run_osd;
    begin
        repeat (4) @(posedge clk);
        o_rst = 1'b0;
        repeat (10) @(posedge clk); #1;

        // ---- en=0: pure bypass, 1 clk delay ----
        o_en = 1'b0; o_de = 1'b1; o_hs = 1'b1; o_vs = 1'b0;
        o_data = 24'hF0F0F0;
        get_pix(12'd100, 12'd100);
        chk(o_datao == 24'hF0F0F0, "osd: en=0 bypasses pixel");
        chk(o_deo   == 1'b1,       "osd: en=0 bypasses de");
        chk(o_hso   == 1'b1,       "osd: en=0 bypasses hs");
        chk(o_vso   == 1'b0,       "osd: en=0 bypasses vs");
        chk(o_xo    == 12'd100 && o_yo == 12'd100,
                                   "osd: en=0 bypasses pixel coords");

        // ---- panel background / separators ----
        o_en = 1'b1; o_de = 1'b1; o_data = 24'hFFFFFF;
        o_state = 3'd0; o_tot = 5'd2;
        get_pix(12'd0, 12'd200);
        chk(o_datao == 24'h0a2647, "osd: panel background 0a2647");
        get_pix(12'd0, 12'd108);
        chk(o_datao == 24'hffd24a, "osd: top separator ffd24a");
        get_pix(12'd0, 12'd432);
        chk(o_datao == 24'hffd24a, "osd: bottom separator ffd24a");
        get_pix(12'd0, 12'd500);
        chk(o_datao == 24'h0a2647, "osd: caption band background 0a2647");

        // ---- full frame ink scan (proves text/timer really drawn) ----
        o_state = 3'd1;
        o_rem   = 16'd125;
        o_dur   = 16'd125;
        o_cur   = 4'd0;
        o_tot   = 5'd2;
        repeat (1600) @(posedge clk);
        cnt_ink = 0; cnt_green = 0; cnt_bg = 0;
        for (py = 0; py < 512; py = py + 8) begin
            for (px = 0; px < 640; px = px + 1) begin
                get_pix(px[11:0], py[11:0]);
                if (pix == 24'hf5fdff) cnt_ink   = cnt_ink   + 1;
                if (pix == 24'h26c281) cnt_green = cnt_green + 1;
                if (pix == 24'h0a2647) cnt_bg    = cnt_bg    + 1;
            end
        end
        $display("  [INFO] ink scan: white=%0d green=%0d bg=%0d",
                 cnt_ink, cnt_green, cnt_bg);
        chk(cnt_ink   > 200,  "osd: white text ink > 200 px");
        chk(cnt_green > 20,   "osd: green timer ink > 20 px");
        chk(cnt_bg    > 2000, "osd: panel background coverage");

        // ---- alarm layer ----
        o_alarm = 1'b1;
        get_pix(12'd10, 12'd40);
        chk(o_datao == 24'hffffff || o_datao == 24'h8a0000,
            "osd: alarm banner active on top band");
        o_alarm = 1'b0;

        // ---- notice page cycling: 640 frame starts -> notice_sel + 1 ----
        o_state = 3'd0; o_de = 1'b0; o_hs = 1'b0; o_vs = 1'b0;
        for (i = 0; i < 640; i = i + 1) begin
            o_vs = 1'b1; @(posedge clk); #1;
            o_vs = 1'b0; @(posedge clk); #1;
        end
        chk(o_nsel == 2'd1, "osd: notice_sel advanced after 640 frames");

        // ---- overview line index ----
        o_tot = 5'd10;
        o_x = 12'd0; o_y = 12'd164;
        @(posedge clk); #1;
        $display("  [INFO] ovidx=%0d nsel=%0d", o_ovidx, o_nsel);
        chk(o_ovidx == 4'd9, "osd: overview index = ov_k + 8 (frames[7]=1)");
        o_y = 12'd100;
        @(posedge clk); #1;
        chk(o_ovidx == 4'd0, "osd: overview index 0 outside band");
    end
endtask

endmodule
