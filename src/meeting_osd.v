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
//     · `local_x/16`、`local_x%16`、`char_index*8` 改为位选/移位;
//     · `line_y+16*scale` 改为 `line_y+band_h`(12bit 线网, 避免变量乘法)。
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
//
// ★2026-09-21 第三轮(取字通路重构, 为把整机 mslice 压到器件上限 4900 以内):
//   前两版把 9 个 320bit/160bit 文本字段当端口从 meeting_cfg 的**快照寄存器**
//   搬进来(那 2673 个触发器是全设计最大单项), 再在像素通路上做 320bit 的
//   15 路 case mux。现在改为: 像素组合逻辑只算出"字段基址 + 字单元列号",
//   直接向 meeting_cfg 的配置 BRAM 发 11bit 读地址, 下一拍拿回该字节当字模 ID。
//     · meeting_cfg 不再需要任何文本快照 → 2673 触发器 → 约 60;
//     · 本模块不再有 320bit 宽 mux, 只剩窄地址运算 + 一个 8bit 选择;
//     · 画面逐像素完全等价(字段基址表见下)。
//   因为 BRAM 读是同步的(晚地址一拍), 像素通路由 1 级寄存改为 2 级流水:
//     第 1 级(组合): 算条带几何 / 背景 / 取字地址, 并寄存几何与背景;
//     第 2 级(组合): 查字模行 → 落墨, 连同延迟 2 拍的 hs/vs/de/px 打拍输出。
//   下游(应急叠层/音频示波/显示调节)看到的 (de, px_x, px_y, data) 相对关系
//   与改造前完全一致, 只是整条链整体晚 1 拍。
//
// 字段基址表(与 meeting_cfg 的 mem 布局一一对应; 全用移位加减, 无乘法器):
//   会议名称     0                     主办单位     40
//   报到地点     80                    注意事项     120 + notice_sel*40
//   总览项名称   282 + ov_idx*62       当前项名称   282 + current*62
//   当前项发言人 322 + current*62      下一项名称   344 + current*62
//   下一项发言人 384 + current*62
//   当前项/下一项时长(各 16bit)由 meeting_cfg 单独解出, 不经此处。
//   每字段可用字数: 名称/主办/地点/下一项名称 40, 发言人 20(超出部分补空白,
//   与旧快照寄存器的零填充位宽完全对齐)。
//
// 画面功能(与 dev_sim 一致):
//   固定深蓝底 + 金线(108/432 行) + 会议名(32px) + 主办/地点/已运行时钟
//   + 初始议程总览(>8 项分两页) + 当前项 32px 大字倒计时(>60s 绿 / ≤60s 黄 /
//     归零红闪烁) + 状态行 + 当前项序号 + 下一项名称/发言人/计划时间
//     + 整体进度条 + 底部循环滚动通知 + 告警顶部覆盖。
//
// 时钟域 : video_clk(25MHz), 同步输出整体寄存 2 拍。
// 语言: 纯 Verilog-2001。
//====================================================================
`include "meeting_fmt.v"
`include "meeting_glyph_rom.v"

module meeting_osd(input clk,rst,en,alarm,input hs_i,vs_i,de_i,
 input [23:0] data_i,input [11:0] px_x,px_y,
 input [2:0] state,input [3:0] current,input [4:0] total,
 input [15:0] remaining,overtime,next_duration,input [31:0] uptime,
 input alarm_paused,
 output [10:0] cfg_addr,input [7:0] cfg_byte,
 output [15:0] time_bcd_o,
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

// ---- 第 1 级(组合): 条带几何 + 背景 + 取字地址 ----
reg [4:0]  s_sel;                          // 内容选择码: 0=用BRAM字段 1..19=TEXT_n 20..24=运行期数字
reg [7:0]  s_gb;                           // 由 s_sel/s_ci 选出的字形字节
reg [7:0]  s_ci;                           // 字单元列号(0..39)
reg [7:0]  s_lim;                          // 本条带可取字数(40 / 20)
reg [11:0] s_lx, s_ly;                     // 字带内局部坐标(恒非负 → 无符号)
reg [11:0] s_origin, s_line_y;
reg [1:0]  sh;                             // 字号缩放右移量(scale 1/2/4 → 0/1/2)
reg        line_vld;                       // 1=本像素落在某条字带内
reg [3:0]  band;                           // 字带编号 0..14
reg        lcfg;                           // 1=字形取自配置 BRAM
reg [10:0] lbase;                          // lcfg=1 时的字段基址
reg [3:0]  bit_column;                     // 格内列(15..0)
reg        ink_allowed;                    // 1=允许落墨
reg [23:0] color, pixel;                   // 墨色 / 未落墨时的像素

// ---- 第 2 级(寄存) ----
reg [7:0]  p_gb;
reg [3:0]  p_row, p_col;
reg        p_ink, p_lcfg;
reg [23:0] p_color, p_bg;
reg        hs_1, vs_1, de_1;
reg [11:0] px_x_1, px_y_1;

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
 .ot_bcd        (ot_bcd      ),
 .nd_bcd        (nd_bcd      ),
 .up_bcd        (up_bcd      ),
 .progress      (prog_q       )
);

// 倒计时显示值: 剩余归零且已开始 → 改显超时正计时(与原版 `t` 等价)
wire [15:0] t_bcd = (remaining==0 && state!=0) ? ot_bcd[15:0] : rem_bcd[15:0];
assign time_bcd_o = t_bcd;
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
// 常量串取字节: 从 320bit 常量串里按"字单元列号"取 8bit 字形 ID
//   ※ 调用点传入的 s 是编译期常量, 综合器把整个 case 塌缩成"8bit × 40:1
//     常量 mux"(约 12 LUT/调用点)。
//     旧写法先把 320bit 的 `line` 整个分支搭出来(320bit × 15 路 case mux,
//     实测约 1300 LUT), 再变址取其中 1 字节 —— 那步正是本模块最大 LUT 沉没点。
//--------------------------------------------------------------------
function [7:0] tsel;
    input [319:0] s;
    input [7:0]   i;
    begin
        case (i)
        8'd0 : tsel = s[319:312];  8'd1 : tsel = s[311:304];
        8'd2 : tsel = s[303:296];  8'd3 : tsel = s[295:288];
        8'd4 : tsel = s[287:280];  8'd5 : tsel = s[279:272];
        8'd6 : tsel = s[271:264];  8'd7 : tsel = s[263:256];
        8'd8 : tsel = s[255:248];  8'd9 : tsel = s[247:240];
        8'd10: tsel = s[239:232];  8'd11: tsel = s[231:224];
        8'd12: tsel = s[223:216];  8'd13: tsel = s[215:208];
        8'd14: tsel = s[207:200];  8'd15: tsel = s[199:192];
        8'd16: tsel = s[191:184];  8'd17: tsel = s[183:176];
        8'd18: tsel = s[175:168];  8'd19: tsel = s[167:160];
        8'd20: tsel = s[159:152];  8'd21: tsel = s[151:144];
        8'd22: tsel = s[143:136];  8'd23: tsel = s[135:128];
        8'd24: tsel = s[127:120];  8'd25: tsel = s[119:112];
        8'd26: tsel = s[111:104];  8'd27: tsel = s[103:96];
        8'd28: tsel = s[95:88];    8'd29: tsel = s[87:80];
        8'd30: tsel = s[79:72];    8'd31: tsel = s[71:64];
        8'd32: tsel = s[63:56];    8'd33: tsel = s[55:48];
        8'd34: tsel = s[47:40];    8'd35: tsel = s[39:32];
        8'd36: tsel = s[31:24];    8'd37: tsel = s[23:16];
        8'd38: tsel = s[15:8];     8'd39: tsel = s[7:0];
        default: tsel = 8'd0;
        endcase
    end
endfunction

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

//------------------------------------------------------------
// 字段基址(移位加减, 无乘法器; 各字段宽度见文件头"字段基址表")
//------------------------------------------------------------
wire [10:0] cu62 = ({7'd0, current}  << 6) - ({7'd0, current}  << 1); // current*62
wire [10:0] ov62 = ({7'd0, ov_idx}   << 6) - ({7'd0, ov_idx}   << 1); // ov_idx*62
wire [10:0] ns40 = ({9'd0, notice_sel} << 5) + ({9'd0, notice_sel} << 3); // 页*40

// 底部滚动字幕的横向取址(px_x+phase ≤ 639+639=1278 → 减一次 640 即可, 不用取模)
wire [11:0] scr_x = px_x + phase[11:0];

// 本条带高度(16 / 32 / 64); 单独算成 12bit 线网, 避免 32bit 加法器/比较器
wire [11:0] band_h = 12'd16 << sh;

// 取字地址: 只在"落在字带内 且 取自配置 且 列号在字段长度内"时发有效地址。
//   否则发 0(0 号字节是会议名称首字节, 一般是空白, 不会误落墨);
//   同时也保证不会读越 mem[0:1271]。
wire        fetch_ok = line_vld && lcfg && (s_ci < s_lim);
wire [10:0] cfg_rd   = fetch_ok ? (lbase + {3'd0, s_ci}) : 11'd0;
assign cfg_addr = cfg_rd;

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
// 第 1 级: 逐像素组合 —— 条带编号 + 内容来源 + 背景/墨色 + 取字地址
//   ※ 字带高度 16<<sh 单独算成 12bit 线网: 若直接写 `line_y+(16<<sh)`,
//     `16` 是无尺寸字面量(32bit) → 会生成 32bit 加法器/比较器。
//   ★条带编号 + case(2026-09-19 第二轮重构, 画面完全不变):
//     拆成两步 —— 1) 先用**只含窄数据**的比较链算出 band 编号(15 个 1bit 判据);
//                 2) 再用 `case(band)` 选内容(case 各级天然互斥, 综合器可用
//                    浅 mux 树/one-hot 选择, 宽数据 mux 深度从 15 降到 ~4)。
//   ★2026-09-21 第三轮: case 各级不再搬 320bit 文本寄存器, 改为只给
//     "字段基址 lcfg/lbase"(取字时经 BRAM 取字节)。
//   ★2026-09-21 第四轮(LUT 收敛): 常量串旧写法是先把整条 320bit 的 `line`
//     按 15 路 case 搭出来、再变址取其中 1 字节 —— 那一步实测约 1300 LUT,
//     是本模块最大单项。现改为: case 各级只登记一个 5bit 内容码 `s_sel`,
//     最后由 `case(s_sel)` + tsel() 直接算出"被选中的那一个字节"。
//--------------------------------------------------------------------
always @* begin
 pixel=data_i;color=24'hf5fdff;s_sel=5'd0;sh=0;s_origin=12'd24;s_line_y=12'd0;line_vld=1'b0;
 band=4'd0;s_ci=0;s_lim=8'd40;s_lx=0;s_ly=0;s_gb=0;
 lcfg=1'b0;lbase=11'd0;ink_allowed=0;bit_column=0;
 if(de_i && en) begin
 // Fixed background supplied by existing framebuffer; only panel areas overlaid.
 if(px_y<110 || (px_y>=116 && px_y<428) || px_y>=438) pixel=24'h0a2647;
 if(px_y==108 || px_y==432) pixel=24'hffd24a;
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
 4'd1 : begin lcfg=1'b1;lbase=11'd0;s_line_y=12'd12;sh=1;line_vld=1'b1;end
 4'd2 : begin lcfg=1'b1;lbase=11'd40;s_line_y=12'd52;line_vld=1'b1;end
 4'd3 : begin
 lcfg=1'b1;lbase=11'd80;s_line_y=12'd76;line_vld=1'b1;
 if(px_x>=360) begin s_origin=12'd360;lcfg=1'b0;s_sel=5'd17;
 if(px_x>=488) begin s_origin=12'd488;s_sel=5'd20;end end
 end
 4'd4 : begin s_sel=5'd18;s_line_y=12'd116;line_vld=1'b1;
 if(px_x>=400) begin s_origin=12'd400;s_sel=5'd8;end end
 4'd5 : begin
 if(ov_idx<total && ov_rem<8'd16) begin
 lcfg=1'b1;lbase=11'd282+ov62;s_line_y=12'd140+{4'd0,ov_k24};
 s_origin=12'd72;line_vld=1'b1;
 if(px_x<64) begin s_origin=12'd24;lcfg=1'b0;s_sel=5'd21;end
 end
 end
 4'd6 : begin lcfg=1'b1;lbase=11'd282+cu62;s_line_y=12'd124;sh=1;line_vld=1'b1;end
 4'd7 : begin s_sel=5'd1;s_line_y=12'd168;line_vld=1'b1;
 if(px_x>=152) begin s_origin=12'd152;lcfg=1'b1;lbase=11'd322+cu62;s_lim=8'd20;end end
 4'd8 : begin s_sel=(state==4 || (remaining==0 && overtime!=0))?5'd3:5'd2;
 s_line_y=12'd202;line_vld=1'b1;end
 4'd9 : begin
 s_line_y=12'd228;sh=2;s_sel=5'd23;line_vld=1'b1;
 color=remaining>60?24'h26c281:(remaining>0?24'hffd24a:24'hff2a2a);
 if(remaining==0 && !frames[4]) color=24'h0a2647;
 end
 4'd10: begin
 s_line_y=12'd306;line_vld=1'b1;case(state)
 0:s_sel=5'd8;1:s_sel=5'd9;2:s_sel=alarm_paused?5'd15:5'd10;
 3:s_sel=5'd11;4:s_sel=5'd12;5:s_sel=5'd13;6:s_sel=5'd14;default:s_sel=5'd0;endcase
 end
 4'd11: begin s_sel=5'd4;s_line_y=12'd334;line_vld=1'b1;
 if(px_x>=104) begin s_origin=12'd104;s_sel=5'd22;end
 end
 4'd12: begin s_sel=5'd5;s_line_y=12'd360;line_vld=1'b1;
 if(px_x>=152) begin s_origin=12'd152;
 if(current+1<total) begin lcfg=1'b1;lbase=11'd344+cu62;end
 else                                s_sel=5'd19;
 end
 end
 4'd13: begin s_sel=5'd6;s_line_y=12'd384;line_vld=1'b1;
 if(px_x>=152) begin s_origin=12'd152;
 if(current+1<total) begin lcfg=1'b1;lbase=11'd384+cu62;s_lim=8'd20;end
 else                     s_sel=5'd0;
 end
 if(px_x>=376) begin s_origin=12'd376;lcfg=1'b0;s_sel=5'd7;end
 if(px_x>=520) begin s_origin=12'd520;lcfg=1'b0;s_sel=5'd24;end
 end
 4'd14: begin lcfg=1'b1;lbase=11'd120+ns40;s_line_y=12'd450;
 s_origin=12'd0;line_vld=1'b1;end
 default: ;
 endcase
 if(px_y>=410 && px_y<422 && px_x>=24 && px_x<616) pixel=px_x-24<progress?24'h26c281:24'h28425d;
 if(line_vld && px_y>=s_line_y && px_y<s_line_y+band_h && px_x>=s_origin) begin
 s_lx=(px_x-s_origin)>>sh;
 if(s_line_y==12'd450) s_lx=(scr_x>=12'd640)?(scr_x-12'd640):scr_x;
 s_ci=s_lx[11:4];s_ly=(px_y-s_line_y)>>sh;
 if(s_ci<s_lim) begin
 ink_allowed=1;bit_column=4'd15-s_lx[3:0];end
 end
 // Minimal highest-layer emergency integration preview; full alarm scene is unchanged.
 if(alarm && px_y<64) begin pixel=frames[4]?24'hff2a2a:24'h8a0000;
 s_sel=5'd16;lcfg=1'b0;s_lx=px_x>>1;s_ly=(px_y-16)>>1;s_ci=s_lx[11:4];
 ink_allowed=px_y>=16 && px_y<48;bit_column=4'd15-s_lx[3:0];color=24'hffffff;
 end
 end
 // ---- 取字: 由 s_sel 决定取自哪条常量串/哪种运行期数字, 只搭"被选中的那一字节"
 //      (见 tsel 说明; 旧写法整体搭 320bit `line` 再变址取 1 字节, 是本模块最大 LUT 沉没点)
 case(s_sel)
 5'd1 : s_gb = tsel(TEXT_1 , s_ci);
 5'd2 : s_gb = tsel(TEXT_2 , s_ci);
 5'd3 : s_gb = tsel(TEXT_3 , s_ci);
 5'd4 : s_gb = tsel(TEXT_4 , s_ci);
 5'd5 : s_gb = tsel(TEXT_5 , s_ci);
 5'd6 : s_gb = tsel(TEXT_6 , s_ci);
 5'd7 : s_gb = tsel(TEXT_7 , s_ci);
 5'd8 : s_gb = tsel(TEXT_8 , s_ci);
 5'd9 : s_gb = tsel(TEXT_9 , s_ci);
 5'd10: s_gb = tsel(TEXT_10, s_ci);
 5'd11: s_gb = tsel(TEXT_11, s_ci);
 5'd12: s_gb = tsel(TEXT_12, s_ci);
 5'd13: s_gb = tsel(TEXT_13, s_ci);
 5'd14: s_gb = tsel(TEXT_14, s_ci);
 5'd15: s_gb = tsel(TEXT_15, s_ci);
 5'd16: s_gb = tsel(TEXT_16, s_ci);
 5'd17: s_gb = tsel(TEXT_17, s_ci);
 5'd18: s_gb = tsel(TEXT_18, s_ci);
 5'd19: s_gb = tsel(TEXT_19, s_ci);
 5'd20: case(s_ci)                                  // 已运行 时:分:秒
        8'd0:s_gb=digit_id(up_hh_t); 8'd1:s_gb=digit_id(up_hh_o);
        8'd2:s_gb=COLON_ID;          8'd3:s_gb=digit_id(up_mm_t);
        8'd4:s_gb=digit_id(up_mm_o); 8'd5:s_gb=COLON_ID;
        8'd6:s_gb=digit_id(up_ss_t); 8'd7:s_gb=digit_id(up_ss_o);
        default:s_gb=8'd0; endcase
 5'd21: case(s_ci)                                  // 总览行序号
        8'd0:s_gb=digit_id(dec_t({1'b0,ov_idx}+5'd1));
        8'd1:s_gb=digit_id(dec_o({1'b0,ov_idx}+5'd1));
        default:s_gb=8'd0; endcase
 5'd22: case(s_ci)                                  // 当前项/总项数
        8'd0:s_gb=digit_id(dec_t({1'b0,current}+5'd1));
        8'd1:s_gb=digit_id(dec_o({1'b0,current}+5'd1));
        8'd2:s_gb=SLASH_ID;
        8'd3:s_gb=digit_id(dec_t(total));
        8'd4:s_gb=digit_id(dec_o(total));
        default:s_gb=8'd0; endcase
 5'd23: case(s_ci)                                  // 倒计时 分:秒
        8'd0:s_gb=digit_id(mm_t); 8'd1:s_gb=digit_id(mm_o);
        8'd2:s_gb=COLON_ID;
        8'd3:s_gb=digit_id(ss_t); 8'd4:s_gb=digit_id(ss_o);
        default:s_gb=8'd0; endcase
 5'd24: case(s_ci)                                  // 下一项时长 分:秒
        8'd0:s_gb=digit_id(nd_mm_t); 8'd1:s_gb=digit_id(nd_mm_o);
        8'd2:s_gb=COLON_ID;
        8'd3:s_gb=digit_id(nd_ss_t); 8'd4:s_gb=digit_id(nd_ss_o);
        default:s_gb=8'd0; endcase
 default: s_gb = 8'd0;
 endcase
end

//--------------------------------------------------------------------
// 第 2 级: 查字模 + 落墨 + 整体打拍输出(2 拍)
//   字形 ID 来源: 取自配置 BRAM 的 cfg_byte(晚本拍一拍, 正好与上面寄存的
//   几何同拍) / 常量串路径的 s_gb。
//--------------------------------------------------------------------
wire [15:0] bits;
wire [7:0]  p_glyph  = p_lcfg ? cfg_byte : p_gb;
wire [11:0] rom_addr = {p_glyph, p_row};
meeting_glyph_rom font(rom_addr, bits);
wire [23:0] composed = (p_ink && bits[p_col]) ? p_color : p_bg;

always @(posedge clk) begin
 if(rst) begin
  p_gb<=0;p_row<=0;p_col<=0;p_ink<=0;p_lcfg<=0;p_color<=0;p_bg<=0;
  hs_1<=0;vs_1<=0;de_1<=0;px_x_1<=0;px_y_1<=0;
  hs_o<=0;vs_o<=0;de_o<=0;data_o<=0;px_x_o<=0;px_y_o<=0;
 end
 else begin
  p_gb<=s_gb;p_row<=s_ly[3:0];p_col<=bit_column;p_ink<=ink_allowed;
  p_lcfg<=lcfg;p_color<=color;p_bg<=pixel;
  hs_1<=hs_i;vs_1<=vs_i;de_1<=de_i;px_x_1<=px_x;px_y_1<=px_y;
  hs_o<=hs_1;vs_o<=vs_1;de_o<=de_1;data_o<=composed;
  px_x_o<=px_x_1;px_y_o<=px_y_1;
 end
end
endmodule
