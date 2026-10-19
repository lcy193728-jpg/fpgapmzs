`timescale 1ns/1ps
module tb_display_resinfo_persistent;
  reg clk=0,rst=1,res_always=0; always #5 clk=~clk;
  reg [11:0] x=12'd564,y=12'd6;
  wire [23:0] out; wire ho,vo,de;
  display_adjust #(.BAR_HOLD_FRAMES(0),.RES_HOLD_FRAMES(0),.MAN_HOLD_FRAMES(0),
    .VOL_HOLD_FRAMES(0),.RESW_HOLD_FRAMES(0),.SCB_HOLD_FRAMES(0)) dut(
    .video_clk(clk),.rst(rst),.hs_i(0),.vs_i(0),.de_i(1),.data_i(24'h123456),.px_x(x),.px_y(y),
    .menu_active(0),.emerg(0),.bmp_busy(0),.iris_trig(0),.wipe_trig(0),
    .bri_level(4'd8),.vol_level(4'd8),.res_level(4'd4),.con_level(4'd8),.img_res(2'd1),
    .pic_manual(0),.res_info_always(res_always),.ui_mode(3'd6),.quiz_on(0),.meeting_on(0),
    .q_state(0),.q_end(0),.q_end_ready(0),.sc0(0),.sc1(0),.sc2(0),.sc3(0),
    .sc_evt(0),.sc_team(0),.hs_o(ho),.vs_o(vo),.de_o(de),.data_o(out));
  initial begin
    repeat(4)@(posedge clk); rst=0; repeat(8)@(posedge clk);
    if(dut.resw_show!==0)begin $display("[FAIL] default must remain transient/off");$finish;end
    res_always=1;repeat(5)@(posedge clk);
    if(dut.resw_show!==1)begin $display("[FAIL] persistent resolution mode did not latch");$finish;end
    repeat(3)@(posedge clk);
    if(!dut.resw_region || !dut.resw_border)begin $display("[FAIL] persistent resolution border geometry missing");$finish;end
    res_always=0;repeat(5)@(posedge clk);
    if(dut.resw_show!==0)begin $display("[FAIL] persistent resolution mode did not turn off");$finish;end
    $display("[PASS] resolution label supports persistent on/off without changing default");$finish;
  end
endmodule
