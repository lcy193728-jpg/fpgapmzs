`timescale 1ns/1ps
//====================================================================
// TB : tb_meeting_sd_rd.v -- MTG1 config parser self-check (real card image)
//
// Why this TB exists (added 2026-09-19, after an on-board failure):
//   The board showed NO meeting overlay because meeting_sd_rd rejected the
//   real meeting.bin. Root cause: the item phase counter `dmod` wraps every
//   62 bytes starting from pos=0 (it is only force-cleared at pos==285), so
//   the "duration must be 1..5999" check also fired at pos=62/124/186/248 --
//   inside the zero-padded metadata block -- where the byte pairs are
//   0x0000/0x0000/0x0000/0x3C3D. That set bad=1 -> error=1, ready=0, so
//   meeting_osd.en stayed 0 and the display fell back to the old
//   osd_scene "meeting notice" picture (i.e. "nothing changed").
//   tb_meeting_chain.v only drove meeting_cfg's write port, so this module
//   was never simulated -- that is how the bug escaped the regression.
//
// This TB feeds the byte stream of the REAL assets/meeting.bin
// (tb/meeting_bin.hex, 1024 B = 2 sectors) through an emulated SD
// sector-read handshake that mirrors sd_card_sec_read_write.v:
//   S_WAIT_READ_WRITE --(sd_sec_read=1)--> latch sd_sec_read_addr
//   --> 512 x (sd_sec_read_data + data_valid=1) --> sd_sec_read_end (1 cyc)
//   --> back to S_WAIT_READ_WRITE
//
// Phases:
//   A) clean image      -> ready=1, error=0, total=6,
//                          RAM == card[5..656] byte-exact,
//                          item i duration lands at RAM 280+i*62
//   B) duration = 0     -> error=1, ready=0  (the check must still work)
//   C) magic corrupted  -> error=1, ready=0
//
// Notes:
//   * $readmemh path is relative to the run dir used by run_regress.ps1
//     (sim/_regress/tb_meeting_sd_rd) -> ../../../tb/meeting_bin.hex
//   * Messages are ASCII and avoid the uppercase token ERROR so that the
//     regression scanner does not count them as tool errors.
//====================================================================
module tb_meeting_sd_rd;

localparam [31:0] START = 32'd200000;   // must match top.v mtg_start_sector

reg clk = 1'b0;
always #5 clk = ~clk;                   // 100 MHz (sd_card_clk)

reg rst          = 1'b1;
reg sd_init_done = 1'b0;

integer checks = 0;
integer errors = 0;

//--------------------------------------------------------------------
// card image: 1024 bytes (2 sectors) read from the real asset
//--------------------------------------------------------------------
reg [7:0] card [0:1023];
integer   k;

//--------------------------------------------------------------------
// DUT
//--------------------------------------------------------------------
wire        sd_sec_read;
wire [31:0] sd_sec_read_addr;
reg  [7:0]  sd_sec_read_data;
reg         sd_sec_read_data_valid;
reg         sd_sec_read_end;
wire        ram_we;
wire [10:0] ram_addr;
wire [7:0]  ram_data;
wire        ready, error, done;
wire [4:0]  total;

meeting_sd_rd #(
    .MAX_SECTORS (32'd3              ),
    .CLK_FREQ_HZ (32'd100_000_000    ),
    .TIMEOUT_MS  (32'd100            )
) dut (
    .clk                     (clk                    ),
    .rst                     (rst                    ),
    .start_sector            (START                  ),
    .sd_init_done            (sd_init_done           ),
    .sd_sec_read             (sd_sec_read            ),
    .sd_sec_read_addr        (sd_sec_read_addr       ),
    .sd_sec_read_data        (sd_sec_read_data       ),
    .sd_sec_read_data_valid  (sd_sec_read_data_valid ),
    .sd_sec_read_end         (sd_sec_read_end        ),
    .ram_we                  (ram_we                 ),
    .ram_addr                (ram_addr               ),
    .ram_data                (ram_data               ),
    .ready                   (ready                  ),
    .error                   (error                  ),
    .total                   (total                  ),
    .done                    (done                   )
);

//--------------------------------------------------------------------
// config RAM shadow (captures the DUT write port)
//--------------------------------------------------------------------
reg [7:0] rmem [0:1271];
always @(posedge clk) if (ram_we) rmem[ram_addr] <= ram_data;

//--------------------------------------------------------------------
// emulated SD card controller (sector read handshake)
//   Mirrors sd_card_sec_read_write.v timing EXACTLY, including the
//   one-cycle gap that matters:
//     S_READ -> S_READ_END(sd_sec_read_end) -> S_WAIT_READ_WRITE(latch addr)
//   The DUT advances sd_sec_read_addr on the cycle where it samples
//   sd_sec_read_end, so the new address only becomes visible on the NEXT
//   cycle -- i.e. during S_WAIT_READ_WRITE. Latching one cycle earlier
//   re-reads the same sector (this is what the CWAIT dead cycle models).
//--------------------------------------------------------------------
localparam [2:0] CGAP  = 3'd0,   // waiting for sd_sec_read
                 CCMD  = 3'd1,   // command phase (1 cycle)
                 CDATA = 3'd2,   // 512 data bytes, 1 per cycle
                 CEND  = 3'd3,   // sd_sec_read_end, 1 cycle
                 CWAIT = 3'd4;   // dead cycle = S_WAIT_READ_WRITE

reg [2:0]  cst   = CGAP;
reg [31:0] caddr = 32'd0;
reg [9:0]  cidx  = 10'd0;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        cst                     <= CGAP;
        caddr                   <= 32'd0;
        cidx                    <= 10'd0;
        sd_sec_read_data        <= 8'd0;
        sd_sec_read_data_valid  <= 1'b0;
        sd_sec_read_end         <= 1'b0;
    end
    else begin
        sd_sec_read_data_valid <= 1'b0;   // default: single-cycle pulse
        sd_sec_read_end        <= 1'b0;
        case (cst)
        CGAP: begin
            if (sd_sec_read) begin
                caddr <= sd_sec_read_addr;   // latch address
                cidx  <= 10'd0;
                cst   <= CCMD;
            end
        end
        CCMD: cst <= CDATA;
        CDATA: begin
            sd_sec_read_data       <= card[(caddr - START) * 512 + cidx];
            sd_sec_read_data_valid <= 1'b1;
            if (cidx == 10'd511) cst <= CEND;
            else                 cidx <= cidx + 10'd1;
        end
        CEND: begin
            sd_sec_read_end <= 1'b1;
            cst <= CWAIT;
        end
        CWAIT: cst <= CGAP;
        endcase
    end
end

//--------------------------------------------------------------------
// helpers
//--------------------------------------------------------------------
task chk;
    input             cond;
    input [8*80-1:0]  msg;
    begin
        checks = checks + 1;
        if (!cond) begin
            errors = errors + 1;
            $display("  [FAIL] %0s", msg);
        end
        else $display("  [PASS] %0s", msg);
    end
endtask

task do_reset;
    begin
        rst = 1'b1;
        repeat (6) @(posedge clk);
        rst = 1'b0;
        repeat (6) @(posedge clk);
    end
endtask

// wait for done with a watchdog (returns 0 on timeout)
task wait_done;
    output ok;
    integer n;
    begin
        ok = 1'b0;
        for (n = 0; n < 30000; n = n + 1) begin
            @(posedge clk);
            if (done) begin ok = 1'b1; n = 30000; end
        end
    end
endtask

//--------------------------------------------------------------------
// main
//--------------------------------------------------------------------
reg        wok;
integer    mism;
reg [15:0] dur;
integer    idx;
integer    cyc;

initial begin
    $readmemh("../../../tb/meeting_bin.hex", card);
    $display("");
    $display("======== A) clean image (real meeting.bin) ========");
    $display("  [INFO] card[0..7] = %02h %02h %02h %02h %02h %02h %02h %02h",
             card[0],card[1],card[2],card[3],card[4],card[5],card[6],card[7]);

    do_reset;
    sd_init_done = 1'b1;

    wait_done(wok);
    chk(wok, "A: read finished (done=1)");
    repeat (4) @(posedge clk);

    chk(ready == 1'b1, "A: ready = 1");
    chk(error == 1'b0, "A: error stays 0");
    chk(total == 5'd6, "A: total = 6");

    // metadata region must survive the duration check untouched
    // (pos 62/124/186/248 pairs are 0000/0000/0000/3C3D -> would trip it)
    chk(rmem[0]  == card[5],  "A: RAM[0]   = card[5]  (meeting name head)");
    chk(rmem[39] == card[44], "A: RAM[39]  = card[44] (meeting name tail)");
    chk(rmem[40] == card[45], "A: RAM[40]  = card[45] (organizer head)");
    chk(rmem[80] == card[85], "A: RAM[80]  = card[85] (venue head)");
    chk(rmem[120] == card[125],"A: RAM[120] = card[125](notice page0 head)");

    // whole payload byte-exact
    mism = 0;
    for (k = 0; k < 652; k = k + 1)
        if (rmem[k] !== card[5+k]) mism = mism + 1;
    $display("  [INFO] payload mismatch count = %0d (expect 0)", mism);
    chk(mism == 0, "A: RAM[0..651] == card[5..656] byte-exact");

    // debug: locate the divergence (prints nothing when the payload is clean)
    idx = 0;
    for (k = 0; k < 652; k = k + 1)
        if (rmem[k] !== card[5+k] && idx < 8) begin
            $display("  [INFO] mism @RAM %0d (pos %0d): rmem=%02h card=%02h",
                     k, k+5, rmem[k], card[5+k]);
            idx = idx + 1;
        end

    // item durations land at RAM 280 + i*62 (big endian)
    for (idx = 0; idx < 6; idx = idx + 1) begin
        dur = {rmem[280+idx*62], rmem[281+idx*62]};
        $display("  [INFO] item%0d duration @RAM %0d = %0d", idx, 280+idx*62, dur);
    end
    dur = {rmem[280], rmem[281]};
    chk(dur == 16'd120, "A: item0 duration = 120 s");
    dur = {rmem[342], rmem[343]};
    chk(dur == 16'd180, "A: item1 duration = 180 s");
    dur = {rmem[590], rmem[591]};
    chk(dur == 16'd120, "A: item5 duration = 120 s");

    //--------------------------------------------------------------
    // B) duration = 0 -> must be rejected (the check still works)
    //    NOTE: corrupt the image BEFORE do_reset -- sd_init_done stays 1
    //    across phases, so the DUT starts reading the moment rst drops.
    //--------------------------------------------------------------
    $display("");
    $display("======== B) item0 duration forced to 0 ========");
    card[285] = 8'h00;
    card[286] = 8'h00;
    do_reset;
    sd_init_done = 1'b1;
    wait_done(wok);
    repeat (4) @(posedge clk);
    chk(wok,                     "B: read finished (done=1)");
    chk(error == 1'b1,           "B: error = 1 (zero duration rejected)");
    chk(ready == 1'b0,           "B: ready stays 0");
    card[286] = 8'h78;

    //--------------------------------------------------------------
    // C) magic corrupted -> must be rejected
    //--------------------------------------------------------------
    $display("");
    $display("======== C) magic byte0 corrupted ========");
    card[0] = 8'h00;
    do_reset;
    sd_init_done = 1'b1;
    wait_done(wok);
    repeat (4) @(posedge clk);
    chk(wok,           "C: read finished (done=1)");
    chk(error == 1'b1, "C: error = 1 (bad magic rejected)");
    chk(ready == 1'b0, "C: ready stays 0");
    card[0] = 8'h4D;

    $display("");
    if (errors == 0) $display("ALL TESTS PASSED  (checks %0d)", checks);
    else             $display("TEST FAILED       (checks %0d, failed %0d)", checks, errors);
    $finish;
end

// global watchdog
initial begin
    for (cyc = 0; cyc < 400000; cyc = cyc + 1) @(posedge clk);
    $display("  [FAIL] global watchdog expired");
    $display("TEST FAILED       (checks %0d, failed %0d)", checks, errors + 1);
    $finish;
end

endmodule
