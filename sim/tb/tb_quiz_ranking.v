`timescale 1ns/1ps
module tb_quiz_ranking;
  reg clk=0,rst=1,vs=0,qend=0,qready=0; always #5 clk=~clk;
  reg [11:0] x=12'd393,y=12'd430; reg signed [7:0] s0=2,s1=9,s2=-1,s3=5;
  wire [23:0] out; wire ho,vo,de;
  display_adjust #(.BAR_HOLD_FRAMES(0),.RES_HOLD_FRAMES(0),.MAN_HOLD_FRAMES(0),
    .VOL_HOLD_FRAMES(0),.RESW_HOLD_FRAMES(0),.SCB_HOLD_FRAMES(0),.IRIS_FRAMES(0)) dut(
    .video_clk(clk),.rst(rst),.hs_i(0),.vs_i(vs),.de_i(1),.data_i(24'h123456),.px_x(x),.px_y(y),
    .menu_active(0),.emerg(0),.bmp_busy(0),.iris_trig(0),.wipe_trig(0),.bri_level(8),.vol_level(8),
    .res_level(4),.con_level(8),.img_res(1),.pic_manual(0),.res_info_always(0),.ui_mode(0),
    .quiz_on(1),.meeting_on(0),.q_state(0),.q_end(qend),.q_end_ready(qready),
    .sc0(s0),.sc1(s1),.sc2(s2),.sc3(s3),.sc_evt(0),.sc_team(0),
    .hs_o(ho),.vs_o(vo),.de_o(de),.data_o(out));
  task frame;begin @(negedge clk);vs=1;@(negedge clk);vs=0;repeat(3)@(posedge clk);end endtask
  initial begin
    repeat(4)@(posedge clk);rst=0;repeat(6)@(posedge clk);
    qend=1;repeat(4)@(posedge clk);
    if(dut.end_osd!==0)begin $display("[FAIL] end OSD visible before frame boundary");$finish;end
    frame;
    if({dut.rk_t0,dut.rk_t1,dut.rk_t2,dut.rk_t3}!==8'b01_11_00_10)begin
      $display("[FAIL] rank order %0d %0d %0d %0d",dut.rk_t0,dut.rk_t1,dut.rk_t2,dut.rk_t3);$finish;end
    begin
      @(negedge clk);x=12'd73;y=12'd107;repeat(3)@(posedge clk);
      if(!dut.rank_panel || dut.rank_color!==24'h2EC4FF)begin
        $display("[FAIL] first row is not ranked T2/cyan: %h",dut.rank_color);$finish;end
    end
    if(!dut.end_osd)begin $display("[FAIL] full-screen end OSD not active");$finish;end
    @(negedge clk);x=12'd190;y=12'd34;repeat(3)@(posedge clk);
    if(!dut.title_pix)begin $display("[FAIL] optimized GAME OVER glyph decode");$finish;end
    s0=5;s1=5;s2=5;s3=5;repeat(5)@(posedge clk);
    if({dut.rk_t0,dut.rk_t1,dut.rk_t2,dut.rk_t3}!==8'b00_01_10_11)begin
      $display("[FAIL] tie order %0d %0d %0d %0d",dut.rk_t0,dut.rk_t1,dut.rk_t2,dut.rk_t3);$finish;end
    $display("[PASS] full-screen quiz OSD is frame-gated, score-sorted and team-colored");$finish;
  end
endmodule
