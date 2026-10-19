`timescale 1ns/1ps
module tb_score_popup_equiv;
  reg clk=0,rst=1,evt=0; always #5 clk=~clk;
  reg [11:0] x=0,y=0; wire [23:0] out; wire ho,vo,de;
  display_adjust #(.BAR_HOLD_FRAMES(0),.RES_HOLD_FRAMES(0),.MAN_HOLD_FRAMES(0),
    .VOL_HOLD_FRAMES(0),.RESW_HOLD_FRAMES(0),.SCB_HOLD_FRAMES(10),.IRIS_FRAMES(0)) dut(
    .video_clk(clk),.rst(rst),.hs_i(1'b0),.vs_i(1'b0),.de_i(1'b1),.data_i(24'h123456),
    .px_x(x),.px_y(y),.menu_active(1'b1),.emerg(1'b0),.bmp_busy(1'b0),
    .iris_trig(1'b0),.wipe_trig(1'b0),.bri_level(4'd8),.vol_level(4'd8),
    .res_level(4'd4),.con_level(4'd8),.img_res(2'd1),.pic_manual(1'b0),
    .res_info_always(1'b0),.ui_mode(3'd0),.quiz_on(1'b1),.meeting_on(1'b0),
    .q_state(2'd0),.q_end(1'b0),.q_end_ready(1'b0),
    .sc0(8'sd2),.sc1(8'sd9),.sc2(-8'sd1),.sc3(8'sd5),.sc_evt(evt),.sc_team(2'd0),
    .hs_o(ho),.vs_o(vo),.de_o(de),.data_o(out));
  task sample; input[11:0] sx,sy; begin
    @(negedge clk);x=sx;y=sy;repeat(4)@(posedge clk);
  end endtask
  initial begin
    repeat(4)@(posedge clk);rst=0;repeat(4)@(posedge clk);evt=1;repeat(5)@(posedge clk);
    sample(12'd452,12'd26);
    if(!dut.scb_region || out!==24'hE4F0FF)begin $display("[FAIL] popup border %h",out);$finish;end
    sample(12'd456,12'd30);
    if(!dut.scb_pix || out!==24'hFFD24A)begin $display("[FAIL] popup T glyph %h",out);$finish;end
    sample(12'd631,12'd89);
    if(!dut.scb_region || out!==24'hE4F0FF)begin $display("[FAIL] popup far border %h",out);$finish;end
    $display("[PASS] optimized popup geometry and glyph output match original layout");$finish;
  end
endmodule
