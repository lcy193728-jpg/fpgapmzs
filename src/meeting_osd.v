`timescale 1ns/1ps
//====================================================================
// 模块名 : meeting_osd.v —— 会议场景三 OSD(议程/计时/进度/公告)
// 来源   : dev_sim(meeting_scene3_sim)的 rtl/meeting_osd.v
//
// 上板改动(2026-09-19, 只在"算法实现"层面, 画面与状态语义完全不变):
//   原版把 `t/60`、`uptime_view/3600`、`next_duration%60`、`current*592/total`、
//   `(px_y-140)/24`、`(px_x-origin)/scale` 直接写在 always @* 里 —— 纯仿真写法。
//   上板若照抄: 除以变量 → 除法器; 除以常数 → 综合器走"乘倒数" → 乘法器;
//   本板 DSP 29/29 已满, 会直接爆资源。故:
//     · 所有"秒→时:分:秒/十进制位"与"进度条宽度"改由 meeting_fmt.v 串行算好
//       (双 dabble + 移位减法), 本模块只取寄存器;
//     · `(px_y-140)/24` 改为比较链(值域 0..191 → 0..7);
//     · 字号缩放 `(…)/scale` 改为右移(scale 只取 1/2/4);
//     · 滚动字幕取模 640 改为"减一次 640"(px_x+phase ≤ 1278);
//     · `local_x/16`、`local_x%16`、`char_index*8` 改为位选/移位
//       (原用 integer 变量做 /16、%16, 综合器可能不认"恒非负"而生成除法网络);
//     · `line_y+16*scale` 改为 `line_y+band_h`(12bit 线网, 避免变量乘法与 32bit 加法)。
//   像素通路里现在没有任何 * 与 / , 只剩位选与移位。
//
// ★2026-09-19 第二轮(LUT 收敛用, 画面/状态语义完全不变):
//   首版照抄 dev_sim 的写法后 syn 报 #lut 84.9%, 布线(phy_1)报
//   RUN-8102 "Incremental route failed" 无法收敛; 面积报告定位到
//   meeting_osd 一个模块就占 6938 LUT。两处真凶:
//     1) meeting_text.vh 的 `digit_id(input integer n)` —— 20 处调用, 每处都被
//        综合成 10 个 32bit 有符号相等比较器; 已改为 `input [3:0] n`;
//     2) 本文件用 `integer row,col,scale,origin,line_y` —— origin/line_y 参与
//        `px_x>=origin`、`px_y>=line_y`、`line_y+(16<<sh)` 等运算, 生成 32bit
//        有符号比较/加法。已改为 `reg [11:0]` + 独立 `line_vld` 有效位
//        (原版用 line_y=-100 当"未命中"哨兵, 语义等价);
//        只被赋值、从不读取的 row/col/scale 已删除。
//   另外 `(ov_idx+1)/10`、`%10` 等改为 dec_t/dec_o(比较+定宽加法) ——
//   顺带修掉 `ov_idx+1` 在 4bit 下的溢出(第 16 项议程序号原本显示成 00)。

// 画面功能(与 dev_sim 一致):
//   固定深蓝底 + 金线(108/432 行) + 会议名(32px) + 主办/地点/已运行时钟
//   + 初始议程总览(>8 项分两页) + 当前项 32px 大字倒计时(>60s 绿 / ≤60s 黄 /
//     归零红闪烁) + 状态行 + 当前项序号 + 下一项名称/发言人/计划时间
//     + 整体进度条 + 底部循环滚动通知 + 告警顶部覆盖。
//
// 时钟域 : video_clk(25MHz), 同步输出整体寄存 1 拍。
// 语言: 纯 Verilog-2001。
//====================================================================
`include "meeting_fmt.v"
`include "meeting_glyph_rom.v"

module meeting_osd(input clk,rst,en,alarm,input hs_i,vs_i,de_i,
 input [23:0] data_i,input [11:0] px_x,px_y,
 input [2:0] state,input [3:0] current,input [4:0] total,
 input [15:0] remaining,overtime,duration,next_duration,input [31:0] uptime,
 input alarm_paused,
 input [319:0] title,next_title,meeting_name,organizer,venue,notice,overview_title,
 input [159:0] speaker,next_speaker,
 output reg hs_o,vs_o,de_o,output reg [23:0] data_o,
 output reg [11:0] px_x_o,px_y_o,
 output reg [1:0] notice_sel,output wire [3:0] overview_index);
`include "meeting_text.vh"

//--------------------------------------------------------------------
// 寄存器/线网声明(先声明后用, 保持 Verilog-2001 严格顺序)
//--------------------------------------------------------------------
reg vs_prev;
reg [15:0] phase;
reg [7:0]  frames;
reg [31:0] uptime_view;
reg [319:0] line;
reg [7:0]  glyph;
reg [23:0] color,pixel;
reg        ink_allowed;
reg [3:0]  bit_column;
reg [1:0]  sh;                             // 字号缩放对应的右移量(scale 1/2/4 → 0/1/2)
reg [11:0] local_x, local_y;               // 像素在"字带内"的局部坐标(恒非负 → 无符号)
reg [7:0]  char_index;                     // 字单元列号(local_x/16 → 直接位选 [11:4])
// 字带位置/有效期: 原版用 `integer`(32bit 有符号)存 origin/line_y, 并用
//   line_y=-100 当"本条带未命中"的哨兵 —— 综合时会产生 32bit 有符号比较器
//   与 32bit 减法。改为 12bit 无符号 + 独立有效位, 语义完全等价(见下方注释)。
reg [11:0] origin, line_y;
reg        line_vld;                       // 1=本像素落在某条字带内
// 字带编号 0..14(本轮新增): 见下方"条带编号 + case"重构说明
reg [3:0]  band;
wire [15:0] bits;
wire [23:0] composed=(ink_allowed && bits[bit_column])?color:pixel;
wire [11:0] addr={glyph,local_y[3:0]};
meeting_glyph_rom font(addr,bits);

//--------------------------------------------------------------------
// 十进制格式化(串行引擎): 时:分:秒 各位 + 进度条宽度
//   ※ uptime 用"帧起点锁存值"uptime_view, 与原版显示节拍一致
//--------------------------------------------------------------------
wire [19:0] rem_bcd, ot_bcd, nd_bcd;
wire [39:0] up_bcd;
wire [13:0] prog_q;

meeting_fmt u_fmt(
 .clk           (clk          ),
 .rst           (rst          ),
 .remaining     (remaining    ),
 .overtime      (overtime     ),
 .next_duration (next_duration),
 .uptime        (uptime_view  ),
 .current       (current      ),
 .total         (total        ),
 .rem_bcd       (rem_bcd      ),
 .ot_bcd        (ot_bcd       ),
 .nd_bcd        (nd_bcd       ),
 .up_bcd        (up_bcd       ),
 .progress      (prog_q       )
);

// 倒计时显示值: 剩余归零且已开始 → 改显超时正计时(与原版 `t` 等价)
wire [15:0] t_bcd = (remaining==0 && state!=0) ? ot_bcd[15:0] : rem_bcd[15:0];
wire [3:0]  ss_o = t_bcd[3:0],  ss_t = t_bcd[7:4];
wire [3:0]  mm_o = t_bcd[11:8], mm_t = t_bcd[15:12];

// 已运行时间(时:分:秒; "时取 %100" 已由 up_bcd 的十进制位天然给出)
wire [3:0]  up_ss_o = up_bcd[3:0],   up_ss_t = up_bcd[7:4];
wire [3:0]  up_mm_o = up_bcd[11:8],  up_mm_t = up_bcd[15:12];
wire [3:0]  up_hh_o = up_bcd[19:16], up_hh_t = up_bcd[23:20];

// 下一项计划时长(分:秒)
wire [3:0]  nd_ss_o = nd_bcd[3:0],   nd_ss_t = nd_bcd[7:4];
wire [3:0]  nd_mm_o = nd_bcd[11:8],  nd_mm_t = nd_bcd[15:12];

// 进度条已填充像素宽度(等价于原版 592*current/total; 结束时满格)
wire [13:0] progress = (total==5'd0) ? 14'd0 : ((state==6) ? 14'd592 : prog_q);

//--------------------------------------------------------------------
// 议程总览行号 = (px_y-140)/24 (0..7): 用比较链代替除法
//--------------------------------------------------------------------
function [2:0] div24_8;                    // 输入 0..191 → 0..7
    input [7:0] d;
    begin
        if      (d < 8'd24)  div24_8 = 3'd0;
        else if (d < 8'd48)  div24_8 = 3'd1;
        else if (d < 8'd72)  div24_8 = 3'd2;
        else if (d < 8'd96)  div24_8 = 3'd3;
        else if (d < 8'd120) div24_8 = 3'd4;
        else if (d < 8'd144) div24_8 = 3'd5;
        else if (d < 8'd168) div24_8 = 3'd6;
        else                 div24_8 = 3'd7;
    end
endfunction

//--------------------------------------------------------------------
// 十进制 十位/个位(值域 0..19; 本模块最大 16: 议程序号/总项数)
//   原版写 `(ov_idx+1)/10`、`(ov_idx+1)%10` 等 —— 常数除法虽小, 但本板 DSP
//   已满, 且 `ov_idx+1` 在 4bit 下会于 ov_idx=15 时溢出(第 16 项显示成 00)。
//   这里改成定宽加法 + 比较, 既避免除法也修掉溢出。
//--------------------------------------------------------------------
function [3:0] dec_t;                      // 十位
    input [4:0] v;
    begin dec_t = (v > 5'd9) ? 4'd1 : 4'd0; end
endfunction
function [3:0] dec_o;                      // 个位
    input [4:0] v;
    begin dec_o = (v > 5'd9) ? (v - 5'd10) : v[3:0]; end
endfunction

wire [7:0]  ov_d   = px_y[7:0] - 8'd140;                        // (px_y-140), 仅在区间内有效
wire [2:0]  ov_k   = div24_8(ov_d);                             // 行号 0..7
wire [7:0]  ov_k24 = ({5'd0, ov_k} << 4) + ({5'd0, ov_k} << 3); // k*24(移位加)
wire [7:0]  ov_rem = ov_d - ov_k24;                             // (px_y-140)%24
wire [3:0]  ov_idx = {1'b0, ov_k} + ((total>8 && frames[7]) ? 4'd8 : 4'd0);

assign overview_index = (px_y>=140 && px_y<332) ? ov_idx : 4'd0;

// 底部滚动字幕的横向取址(px_x+phase ≤ 639+639=1278 → 减一次 640 即可, 不用取模)
wire [11:0] scr_x = px_x + phase[11:0];

//--------------------------------------------------------------------
// 帧计数/滚动相位(帧起点更新)
//--------------------------------------------------------------------
always @(posedge clk) begin
 if(rst) begin vs_prev<=0;phase<=0;frames<=0;notice_sel<=0;uptime_view<=0; end
 else begin vs_prev<=vs_i;
 if(vs_i && !vs_prev && en) begin
 uptime_view<=uptime;
 frames<=frames+1;
 if(!alarm) begin
 if(phase==639) begin phase<=0;notice_sel<=notice_sel+1;end else phase<=phase+1;
 end end end
end

//--------------------------------------------------------------------
// 逐像素合成
//   ※ 字带高度 16<<sh 单独算成 12bit 线网: 若直接写 `line_y+(16<<sh)`,
//     `16` 是无尺寸字面量(32bit) → 会生成 32bit 加法器/比较器。
//--------------------------------------------------------------------
wire [11:0] band_h = 12'd16 << sh;         // 本条带高度(16 / 32 / 64)
always @* begin
 pixel=data_i;color=24'hf5fdff;line=0;sh=0;origin=12'd24;line_y=12'd0;line_vld=1'b0;
 band=4'd0;char_index=0;local_x=0;local_y=0;glyph=0;
 ink_allowed=0;bit_column=0;
 if(de_i && en) begin
 // Fixed background supplied by existing framebuffer; only panel areas overlaid.
 if(px_y<110 || (px_y>=116 && px_y<428) || px_y>=438) pixel=24'h0a2647;
 if(px_y==108 || px_y==432) pixel=24'hffd24a;
 //----------------------------------------------------------------
 // ★条带编号 + case(2026-09-19 第二轮重构, 画面完全不变)
 //   原写法是一条 15 级 `if/else if` 优先链, 每一级都要对 320bit 的 `line`
 //   做一次 mux —— 综合器无法认定这些 px_y 区间互斥, 于是一级一级串下去,
 //   实测仅这一条链就烧掉约 4800 LUT(meeting_osd 总共 7403 LUT,
 //   全设计 #lut 88.05%, 布线 RUN-8102 无法收敛)。
 //   现在拆成两步:
 //     1) 先用**只含窄数据**的比较链算出 band 编号(15 个 1bit 的判据);
 //     2) 再用 `case(band)` 选内容 —— case 各级天然互斥, 综合器可用浅的
 //        mux 树/one-hot 选择, 宽数据的 mux 深度从 15 降到 log2(15)≈4。
 //----------------------------------------------------------------
 if(px_y>=12 && px_y<44)                       band=4'd1;
 else if(px_y>=52 && px_y<68)                  band=4'd2;
 else if(px_y>=76 && px_y<92)                  band=4'd3;
 else if(state==0 && px_y>=116 && px_y<132)    band=4'd4;
 else if(state==0 && px_y>=140 && px_y<332)    band=4'd5;
 else if(state!=0 && px_y>=124 && px_y<156)    band=4'd6;
 else if(state!=0 && px_y>=168 && px_y<184)    band=4'd7;
 else if(state!=0 && px_y>=202 && px_y<218)    band=4'd8;
 else if(state!=0 && px_y>=228 && px_y<292)    band=4'd9;
 else if(px_y>=306 && px_y<322)                band=4'd10;
 else if(px_y>=334 && px_y<350)                band=4'd11;
 else if(px_y>=360 && px_y<376)                band=4'd12;
 else if(px_y>=384 && px_y<400)                band=4'd13;
 else if(px_y>=450 && px_y<466)                band=4'd14;
 case(band)
 4'd1 : begin line=meeting_name;sh=1;line_y=12'd12;line_vld=1'b1;end
 4'd2 : begin line=organizer;line_y=12'd52;line_vld=1'b1;end
 4'd3 : begin
 line=venue;line_y=12'd76;line_vld=1'b1;
 if(px_x>=360) begin origin=12'd360;line=TEXT_17;
 if(px_x>=488) begin origin=12'd488;line=0;
 line[319-:8]=digit_id(up_hh_t);line[311-:8]=digit_id(up_hh_o);
 line[303-:8]=COLON_ID;line[295-:8]=digit_id(up_mm_t);line[287-:8]=digit_id(up_mm_o);
 line[279-:8]=COLON_ID;line[271-:8]=digit_id(up_ss_t);line[263-:8]=digit_id(up_ss_o);end end
 end
 4'd4 : begin line=TEXT_18;line_y=12'd116;line_vld=1'b1;
 if(px_x>=400) begin origin=12'd400;line=TEXT_8;end end
 4'd5 : begin
 if(ov_idx<total && ov_rem<8'd16) begin
 line=overview_title;line_y=12'd140+{4'd0,ov_k24};origin=12'd72;line_vld=1'b1;
 if(px_x<64) begin origin=12'd24;line=0;
 line[319-:8]=digit_id(dec_t({1'b0,ov_idx}+5'd1));
 line[311-:8]=digit_id(dec_o({1'b0,ov_idx}+5'd1));end
 end
 end
 4'd6 : begin line=title;line_y=12'd124;sh=1;line_vld=1'b1;end
 4'd7 : begin line=TEXT_1;line_y=12'd168;line_vld=1'b1;
 if(px_x>=152) begin origin=12'd152;line={speaker,160'd0};end end
 4'd8 : begin line=(state==4 || (remaining==0 && overtime!=0))?TEXT_3:TEXT_2;line_y=12'd202;line_vld=1'b1;end
 4'd9 : begin
 line_y=12'd228;sh=2;line=0;line_vld=1'b1;
 line[319-:8]=digit_id(mm_t);line[311-:8]=digit_id(mm_o);
 line[303-:8]=COLON_ID;line[295-:8]=digit_id(ss_t);line[287-:8]=digit_id(ss_o);
 color=remaining>60?24'h26c281:(remaining>0?24'hffd24a:24'hff2a2a);
 if(remaining==0 && !frames[4]) color=24'h0a2647;
 end
 4'd10: begin
 line_y=12'd306;line_vld=1'b1;case(state)
 0:line=TEXT_8;1:line=TEXT_9;2:line=alarm_paused?TEXT_15:TEXT_10;
 3:line=TEXT_11;4:line=TEXT_12;5:line=TEXT_13;6:line=TEXT_14;default:line=0;endcase
 end
 4'd11: begin line=TEXT_4;line_y=12'd334;line_vld=1'b1;
 if(px_x>=104) begin origin=12'd104;line=0;
 line[319-:8]=digit_id(dec_t({1'b0,current}+5'd1));
 line[311-:8]=digit_id(dec_o({1'b0,current}+5'd1));
 line[303-:8]=SLASH_ID;line[295-:8]=digit_id(dec_t(total));
 line[287-:8]=digit_id(dec_o(total));end
 end
 4'd12: begin line=TEXT_5;line_y=12'd360;line_vld=1'b1;
 if(px_x>=152) begin origin=12'd152;line=current+1<total?next_title:TEXT_19;end end
 4'd13: begin line=TEXT_6;line_y=12'd384;line_vld=1'b1;
 if(px_x>=152) begin origin=12'd152;line={next_speaker,160'd0};end
 if(px_x>=376) begin origin=12'd376;line=TEXT_7;end
 if(px_x>=520) begin origin=12'd520;line=0;line[319-:8]=digit_id(nd_mm_t);line[311-:8]=digit_id(nd_mm_o);
 line[303-:8]=COLON_ID;line[295-:8]=digit_id(nd_ss_t);line[287-:8]=digit_id(nd_ss_o);end
 end
 4'd14: begin line=notice;line_y=12'd450;origin=12'd0;line_vld=1'b1;end
 default: ;
 endcase
 if(px_y>=410 && px_y<422 && px_x>=24 && px_x<616) pixel=px_x-24<progress?24'h26c281:24'h28425d;
 if(line_vld && px_y>=line_y && px_y<line_y+band_h && px_x>=origin) begin
 local_x=(px_x-origin)>>sh;
 if(line_y==12'd450) local_x=(scr_x>=12'd640)?(scr_x-12'd640):scr_x;
 char_index=local_x[11:4];local_y=(px_y-line_y)>>sh;
 if(char_index<40) begin glyph=line[319-char_index*8-:8];
 ink_allowed=1;bit_column=4'd15-local_x[3:0];end
 end
 // Minimal highest-layer emergency integration preview; full alarm scene is unchanged.
 if(alarm && px_y<64) begin pixel=frames[4]?24'hff2a2a:24'h8a0000;
 line=TEXT_16;local_x=px_x>>1;local_y=(px_y-16)>>1;char_index=local_x[11:4];
 glyph=char_index<40?line[319-char_index*8-:8]:0;
 ink_allowed=px_y>=16 && px_y<48;bit_column=4'd15-local_x[3:0];color=24'hffffff;
 end
 end
end

always @(posedge clk) begin
 if(rst) begin hs_o<=0;vs_o<=0;de_o<=0;data_o<=0;px_x_o<=0;px_y_o<=0;end
 else begin hs_o<=hs_i;vs_o<=vs_i;de_o<=de_i;data_o<=composed;px_x_o<=px_x;px_y_o<=px_y;end
end
endmodule
