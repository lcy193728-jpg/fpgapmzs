`timescale 1ns/1ps

module EG_LOGIC_BRAM #(
    parameter DATA_WIDTH_A=8,DATA_WIDTH_B=8,ADDR_WIDTH_A=9,ADDR_WIDTH_B=9,
    parameter DATA_DEPTH_A=512,DATA_DEPTH_B=512,MODE="DP",REGMODE_A="NOREG",
    parameter REGMODE_B="NOREG",IMPLEMENT="9K"
)(output [7:0] doa,output [7:0] dob,input [7:0] dia,dib,input cea,ocea,clka,wea,rsta,bea,
  input ceb,oceb,clkb,web,rstb,beb,input [8:0] addra,addrb);
    assign doa=8'd0; assign dob=8'd0;
endmodule

// 可视化历史不得跨场景继承；新场景只放行本场景重新采集的柱。
module tb_audio_viz_scene_clear;
    reg clk=0,rst=1,menu=0,pcm_take=0; reg [1:0] scene=0;
    reg signed [15:0] pcm=16'sd12000;
    always #5 clk=~clk;
    wire hs_o,vs_o,de_o;wire [23:0] data_o;wire [11:0] xo,yo;
    audio_viz_overlay dut(
      .clk(clk),.rst(rst),.hs_i(0),.vs_i(0),.de_i(1),.data_i(24'h0),
      .px_x(0),.px_y(0),.menu_active(menu),.scene_id(scene),.meet_warn_lv(0),
      .pcm_take(pcm_take),.pcm(pcm),.hs_o(hs_o),.vs_o(vs_o),.de_o(de_o),
      .data_o(data_o),.px_x_o(xo),.px_y_o(yo));
    integer i;
    initial begin
      repeat(4)@(posedge clk);rst=0;pcm_take=1;
      for(i=0;i<1030;i=i+1)@(posedge clk);
      if(dut.live_sr==0 || dut.hist_count==0)begin
        $display("[FAIL] test did not build visualization history");$finish;
      end
      scene=2;
      repeat(8)@(posedge clk);
      if(dut.live_sr!=0 || dut.hist_count!=0)begin
        $display("[FAIL] old visualization survived scene change live=%h count=%0d",
                 dut.live_sr,dut.hist_count);$finish;
      end
      $display("[PASS] visualization history is cleared on scene change");
      $finish;
    end
endmodule
