`timescale 1ns/1ps
// Time-series ENVELOPE BAR field ("音量柱"), 2026-09-22 替换原"波形线+水平音量条".
// 隐藏条件不变: menu/meeting 场景不显示。
//--------------------------------------------------------------------
// [B1] 写侧: 每 16 个 48 kHz 样本取一次 |pcm| 的分组最大值(即包络), 写入
//      256×8 环形 BRAM。原实现写的是单点抽样的 pcm[15:8](有符号), 柱体
//      会随过零点上下乱跳, 不像"音量柱"; 取分组最大值后柱子只随音量起伏。
// [B2] 读侧: 列号 col = px_x[10:2] ∈ [0,159]; 读址 = (wp+col) 取低 8 位。
//      环形深度取 256 后"模 256"就是一次位截断, 不需要比较器+减法器
//      (上一版用 320 深 + 9 位比较减法, 本版更省)。
//      col=159 对应最新写入(wp-1) → 内容随时间向左滚动, 与"历史柱阵"一致。
// [B3] 画法: 柱底固定在 y=436, 柱高 hgt = 包络 * 3/16 (见下), 满足
//      (436 - y) <= hgt 的像素填 accent 色; 每 4 个像素中前 3 个是柱体、
//      第 4 个是间隙, 所以画面是 160 根独立柱子。hgt 上限 47 > 条带内高
//      36, 大音量时柱顶自然顶到条带上沿, 无需额外限幅比较器。
//      柱高映射 3/16 是配合本工程实际幅度选的(见 scene_audio_final):
//        旋律 raw≈5668 → hgt≈8~10, 提示音 raw≈11336 → hgt≈16,
//        空袭警报 raw≈19841 → hgt≈29, 静音 → 0(只剩 y=436 一条基线)。
//      不取 3/16 更大的系数(如 /4)是因为那样警报段会长期顶满、看不出起伏。
// [B4] 面积: 删掉原"右半水平音量条"(10 位比较 + 10 位减法 + 9 位比较)和
//      波形高亮线的 9 位回绕距离比较, 换成 1 个 9 位减法 + 1 个 9 位比较
//      (像素域)与 1 个 8 位比较器(48 kHz 域), 总体面积持平略降。
// [B5] 坐标收窄沿用上一版结论: 本模块所有坐标比较都在 de_d=1 门控内, 而整
//      链(osd_engine→…→emergency_multi_overlay→本模块)de=1 时
//      x∈[0,639]、y∈[0,479], 故 x_d[11:10]=0、y_d[11:9]=0 恒成立 →
//      比较只用低位, 高位比较器被综合常量化剪掉。
//   条带几何(与上一版一致, 未动): y ∈ [400, 437], 上下边框 y=400/437 为
//      accent, 内部底色 24'h101820。
//--------------------------------------------------------------------
module audio_viz_overlay(
 input wire clk,rst, input wire hs_i,vs_i,de_i,input wire [23:0] data_i,
 input wire [11:0] px_x,px_y,input wire menu_active,input wire [1:0] scene_id,
 input wire pcm_take,input wire signed [15:0] pcm,
 output reg hs_o,vs_o,de_o,output reg [23:0] data_o,
 output reg [11:0] px_x_o,px_y_o
);
 // 显式逻辑 BRAM 存"每列包络", 不占用 LUT 存储。
 wire [7:0] wave_q;             // 本列(16 样本)的 |pcm| 分组最大值
 reg [7:0] wp;                  // 环形写址; 深度 256 → 8 位自然回绕
 reg [3:0] decim;               // 16 样本一组
 reg [7:0] grp_max;             // 本组已见到的最大包络
 reg menu0,menu1;reg [1:0] sc0,sc1;
 reg hs_d,vs_d,de_d;reg [23:0] data_d;reg [11:0] x_d,y_d;
 wire show=!menu1&&(sc1==0||sc1==2||sc1==3);
 // ---- [B2] 列号与读址(模 256 即 8 位截断) ----
 wire [7:0] col=px_x[10:2];
 wire [7:0] ridx=wp+col;
 // ---- [B3] 柱高与填充判定 ----
 wire [6:0] hgt={1'b0,wave_q[7:3]}+{2'b0,wave_q[7:4]};   // 包络*3/16, 0..47
 wire [8:0] dh=9'd436-y_d[8:0];                          // 当前行距柱底的行数
 wire [14:0] abs_pcm=pcm[15]?(~pcm[14:0]+1'b1):pcm[14:0];
 wire [7:0] mag=abs_pcm[14:7];
 wire [7:0] wval=(mag>grp_max)?mag:grp_max;              // 含当前样本的本组最大
 wire wave_we=pcm_take&&(decim==15);
 wire [23:0] accent=sc1==3?24'hff3030:(sc1==2?24'h30e8ff:24'h44ff88);
 EG_LOGIC_BRAM #(
  .DATA_WIDTH_A(8),.DATA_WIDTH_B(8),.ADDR_WIDTH_A(9),.ADDR_WIDTH_B(9),
  .DATA_DEPTH_A(512),.DATA_DEPTH_B(512),.MODE("DP"),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("9K")
 ) u_wave_bram (
  .doa(),.dob(wave_q),.dia(wval),.dib(8'b0),
  .cea(1'b1),.ocea(1'b1),.clka(clk),.wea(wave_we),.rsta(1'b0),.bea(1'b0),
  .ceb(1'b1),.oceb(1'b1),.clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),
  .addra({1'b0,wp}),.addrb({1'b0,ridx})
 );
 always @(posedge clk) begin
  if(rst)begin wp<=0;decim<=0;grp_max<=0;menu0<=1;menu1<=1;sc0<=0;sc1<=0;
   hs_d<=0;vs_d<=0;de_d<=0;data_d<=0;x_d<=0;y_d<=0;
   hs_o<=0;vs_o<=0;de_o<=0;data_o<=0;px_x_o<=0;px_y_o<=0;end
  else begin
   menu0<=menu_active;menu1<=menu0;sc0<=scene_id;sc1<=sc0;
   if(pcm_take)begin
    if(decim==15)begin decim<=0;wp<=wp+1'b1;end else decim<=decim+1'b1;
    grp_max<=wave_we?8'd0:wval;   // 写完一组即清零, 下一组重新取最大
   end
   // 同步读使 BRAM 推断成立(读址打拍), 整条视频流同步延迟 2 拍: 本拍把
   // data_i→data_d, 下一拍 dob(wave_q)/x_d 才与 data_d 对齐。
   hs_d<=hs_i;vs_d<=vs_i;de_d<=de_i;data_d<=data_i;x_d<=px_x;y_d<=px_y;
   hs_o<=hs_d;vs_o<=vs_d;de_o<=de_d;px_x_o<=x_d;px_y_o<=y_d;data_o<=data_d;
   if(de_d&&show&&y_d[8:0]>=9'd400&&y_d[8:0]<9'd438)begin
    data_o<=24'h101820;
    // 3 px 柱体 + 1 px 间隙; dh<=hgt ⇔ 该行在柱高之内(条带内 dh 最大 36,
    //   故 hgt>36 时整条内高全填, 不需要限幅)。
    if(x_d[1:0]!=2'b11&&dh<={2'b0,hgt})data_o<=accent;
    if(y_d[8:0]==9'd400||y_d[8:0]==9'd437)data_o<=accent;
   end
  end
 end
endmodule
