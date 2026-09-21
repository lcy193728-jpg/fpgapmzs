`timescale 1ns/1ps
// Compact actual-final-PCM waveform and peak meter. Hidden in menu/meeting.
//--------------------------------------------------------------------
// 面积优化(2026-09-21), 行为逐位不变:
//  [A1] 波形高亮线原来用 13 位有符号比较 (y_d >= wy-1 && y_d <= wy+1),
//       现改为 9 位无符号"回绕距离", 去掉两个 13 位加减法 + 两个 13 位
//       有符号比较(≈20 级进位链)。等价性推导:
//         wave_q 为 signed[7:0] → off = wave_q>>>3 ∈ [-16,15];
//         wy = 418-off ∈ [403,434]; 使用处被 y_d∈[400,437] 门控。
//         令 d = y_d - wy, 则 d ∈ [400-434, 437-403] = [-34,34], |d| < 512,
//         故 9 位模 512 运算不产生二次回绕:
//           dy9 = (y_d - wy) mod 512 = d      (d>=0, 0..34)
//                                    = d+512  (d<0, 478..511)
//         于是 dy9<=1 ⇔ d∈{0,1}, dy9==511 ⇔ d=-1, 合并即 |d|<=1 ⇔ d∈{-1,0,1},
//         与原 (y_d>=wy-1 && y_d<=wy+1) 完全等价(13 位有符号域内 wy±1 亦无溢出)。
//  [A2] 窗口比较把 x_d 收窄到 10 位、y_d 收窄到 9 位: 本模块所有坐标比较都在
//       de_d=1 门控内, 而整链(osd_engine→…→emergency_multi_overlay→本模块)
//       de=1 时 x∈[0,639]、y∈[0,479], 故 x_d[11:10]=0、y_d[11:9]=0 恒成立 →
//       窄位比较逐位等价, 且高位比较器被综合常量化剪掉。
//       ★BRAM 读地址侧(px_x[8:0] 截断/ridx 计算)与 x_d<320 门控属既有设计,
//         本次未改动。
//--------------------------------------------------------------------
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
 // ---- [A1] 9 位回绕距离(替代 13 位有符号 wy±1 比较) ----
 wire signed [8:0] off9=$signed(wave_q)>>>3;   // -16..15
 wire [8:0] wy9=9'd418-off9[8:0];              // 403..434, 即原 wy (mod 512 无歧义)
 wire [8:0] dy9=y_d[8:0]-wy9;                  // (y_d-wy) mod 512
 wire wht=(dy9<=9'd1)||(dy9==9'd511);          // ⇔ |y_d-wy|<=1
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
   if(de_d&&show&&y_d[8:0]>=9'd400&&y_d[8:0]<9'd438)begin
    data_o<=24'h101820;
    if(x_d[9:0]<10'd320&&wht)data_o<=accent;
    if(x_d[9:0]>=10'd340&&x_d[9:0]<10'd620&&y_d[8:0]>=9'd426&&y_d[8:0]<9'd434)begin
      if(x_d[9:0]-10'd340<barw)data_o<=accent;else data_o<=24'h303840;
    end
    if(y_d[8:0]==9'd400||y_d[8:0]==9'd437)data_o<=accent;
   end
  end
 end
endmodule
