`timescale 1ns/1ps
// Compact actual-final-PCM waveform and peak meter. Hidden in menu/meeting.
module audio_viz_overlay(
 input wire clk,rst, input wire hs_i,vs_i,de_i,input wire [23:0] data_i,
 input wire [11:0] px_x,px_y,input wire menu_active,input wire [1:0] scene_id,
 input wire pcm_take,input wire signed [15:0] pcm,
 output reg hs_o,vs_o,de_o,output reg [23:0] data_o,
 output reg [11:0] px_x_o,px_y_o
);
 // Explicit logical BRAM keeps the waveform history out of LUT storage.
 wire signed [7:0] wave_q;reg [8:0] wp;reg [3:0] decim;
 reg [14:0] peak;reg menu0,menu1;reg [1:0] sc0,sc1;
 reg hs_d,vs_d,de_d;reg [23:0] data_d;reg [11:0] x_d,y_d;
 wire show=!menu1&&(sc1==0||sc1==2||sc1==3);
 wire [8:0] sum=wp+px_x[8:0];wire [8:0] ridx=sum>=320?sum-320:sum;
 wire signed [12:0] wy=13'sd418-($signed(wave_q)>>>3);
 wire [14:0] abs_pcm=pcm[15]?(~pcm[14:0]+1'b1):pcm[14:0];
 wire [8:0] barw={peak[14:7],1'b0};
 wire [23:0] accent=sc1==3?24'hff3030:(sc1==2?24'h30e8ff:24'h44ff88);
 wire wave_we=pcm_take&&(decim==15);
 EG_LOGIC_BRAM #(
  .DATA_WIDTH_A(8),.DATA_WIDTH_B(8),.ADDR_WIDTH_A(9),.ADDR_WIDTH_B(9),
  .DATA_DEPTH_A(512),.DATA_DEPTH_B(512),.MODE("DP"),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("9K")
 ) u_wave_bram (
  .doa(),.dob(wave_q),.dia(pcm[15:8]),.dib(8'b0),
  .cea(1'b1),.ocea(1'b1),.clka(clk),.wea(wave_we),.rsta(1'b0),.bea(1'b0),
  .ceb(1'b1),.oceb(1'b1),.clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),
  .addra(wp),.addrb(ridx)
 );
 always @(posedge clk) begin
  if(rst)begin wp<=0;decim<=0;peak<=0;menu0<=1;menu1<=1;sc0<=0;sc1<=0;
   hs_d<=0;vs_d<=0;de_d<=0;data_d<=0;x_d<=0;y_d<=0;
   hs_o<=0;vs_o<=0;de_o<=0;data_o<=0;px_x_o<=0;px_y_o<=0;end
  else begin
   menu0<=menu_active;menu1<=menu0;sc0<=scene_id;sc1<=sc0;
   if(pcm_take)begin
    if(decim==15)begin decim<=0;wp<=wp==319?0:wp+1'b1;end else decim<=decim+1'b1;
    if(abs_pcm>peak)peak<=abs_pcm;else if(peak!=0)peak<=peak-1'b1;
   end
   // Synchronous read makes the 320x8 waveform infer block RAM. Delay the
   // complete video stream by the same one pixel clock.
   hs_d<=hs_i;vs_d<=vs_i;de_d<=de_i;data_d<=data_i;x_d<=px_x;y_d<=px_y;
   hs_o<=hs_d;vs_o<=vs_d;de_o<=de_d;px_x_o<=x_d;px_y_o<=y_d;data_o<=data_d;
   if(de_d&&show&&y_d>=400&&y_d<438)begin
    data_o<=24'h101820;
    if(x_d<320&&($signed({1'b0,y_d})>=wy-1)&&($signed({1'b0,y_d})<=wy+1))data_o<=accent;
    if(x_d>=340&&x_d<620&&y_d>=426&&y_d<434)begin
      if(x_d-340<barw)data_o<=accent;else data_o<=24'h303840;
    end
    if(y_d==400||y_d==437)data_o<=accent;
   end
  end
 end
endmodule
