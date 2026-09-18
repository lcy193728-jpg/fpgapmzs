`timescale 1ns/1ps
// Related PLL clocks: pixel=25 MHz, serial=125 MHz, both 0 degrees.
// EG_LOGIC_ODDR samples BOTH d0/d1 at rising edge; d0 rises, d1 falls.
// Send TMDS bit0 first. All four lanes use the SAME word-load event.
module audio_eg4_phy(
    input wire pixel_clk,serial_clk,pixel_rst_n,serial_rst_n,
    input wire [9:0] c0,c1,c2,
    output wire clk_p,d0_p,d1_p,d2_p
);
    reg word_toggle;
    always @(posedge pixel_clk or negedge pixel_rst_n)
        if(!pixel_rst_n) word_toggle<=0; else word_toggle<=~word_toggle;
    reg seen;
    reg [9:0] sh0,sh1,sh2,shc;
    // Synchronous transfer between phase-related clocks; DO NOT false-path.
    // At coincident edges we observe the previous toggle; capture at +8 ns,
    // after the 25-MHz symbol register has settled. ODDR emits from next edge.
    always @(posedge serial_clk or negedge serial_rst_n) begin
        if(!serial_rst_n) begin seen<=0;sh0<=0;sh1<=0;sh2<=0;shc<=0;end
        else if(word_toggle!=seen) begin
            seen<=word_toggle;sh0<=c0;sh1<=c1;sh2<=c2;shc<=10'b1111100000;
        end else begin
            sh0<={2'b00,sh0[9:2]};sh1<={2'b00,sh1[9:2]};
            sh2<={2'b00,sh2[9:2]};shc<={2'b00,shc[9:2]};
        end
    end
    wire q0,q1,q2,qc;
    EG_LOGIC_ODDR #(.ASYNCRST("ENABLE")) u_ddr0(.clk(serial_clk),.rst(!serial_rst_n),.d0(sh0[0]),.d1(sh0[1]),.q(q0));
    EG_LOGIC_ODDR #(.ASYNCRST("ENABLE")) u_ddr1(.clk(serial_clk),.rst(!serial_rst_n),.d0(sh1[0]),.d1(sh1[1]),.q(q1));
    EG_LOGIC_ODDR #(.ASYNCRST("ENABLE")) u_ddr2(.clk(serial_clk),.rst(!serial_rst_n),.d0(sh2[0]),.d1(sh2[1]),.q(q2));
    EG_LOGIC_ODDR #(.ASYNCRST("ENABLE")) u_ddrc(.clk(serial_clk),.rst(!serial_rst_n),.d0(shc[0]),.d1(shc[1]),.q(qc));
    // LVDS33 ADC on the P pad causes TD to reserve its differential N mate.
    EG_LOGIC_OBUF u_buf0(.i(q0),.o(d0_p));
    EG_LOGIC_OBUF u_buf1(.i(q1),.o(d1_p));
    EG_LOGIC_OBUF u_buf2(.i(q2),.o(d2_p));
    EG_LOGIC_OBUF u_bufc(.i(qc),.o(clk_p));
endmodule
