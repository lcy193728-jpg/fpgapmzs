`timescale 1ns/1ps

// Four-type emergency information page. The overlay is generated entirely in
// logic/BRAM, so switching is immediate and never waits for a TF-card read.
module emergency_multi_overlay #(
    parameter DATA_W = 24,
    parameter [21:0] BLINK_DIV = 22'd3_146_875
)(
    input wire clk,input wire rst,
    input wire hs_i,input wire vs_i,input wire de_i,input wire [DATA_W-1:0] data_i,
    input wire [11:0] px_x,input wire [11:0] px_y,
    input wire alarm_en,input wire [1:0] alarm_type,
    input wire [3:0] min_tens,min_ones,sec_tens,sec_ones,
    output wire hs_o,output wire vs_o,output wire de_o,output wire [DATA_W-1:0] data_o,
    output wire [11:0] px_x_o,output wire [11:0] px_y_o
);
    // 本文件是被 top_final.v 以 "../../src/emergency_multi_overlay.v" 引入的,
    // TD 会拿那个字面路径当基准做嵌套包含, 这里只能写裸文件名, 否则会拼成
    // <root>/../src/emergency_text_map.vh 而报 HDL-8007。
    `include "emergency_text_map.vh"

    reg alarm_m,alarm_s; reg [1:0] type_m,type_s;
    reg [3:0] mt_m,mo_m,st_m,so_m,mt_s,mo_s,st_s,so_s;
    always @(posedge clk) begin
        if(rst) begin alarm_m<=0;alarm_s<=0;type_m<=0;type_s<=0;
          mt_m<=0;mo_m<=0;st_m<=0;so_m<=0;mt_s<=0;mo_s<=0;st_s<=0;so_s<=0; end
        else begin alarm_m<=alarm_en;alarm_s<=alarm_m;type_m<=alarm_type;type_s<=type_m;
          mt_m<=min_tens;mo_m<=min_ones;st_m<=sec_tens;so_m<=sec_ones;
          mt_s<=mt_m;mo_s<=mo_m;st_s<=st_m;so_s<=so_m; end
    end

    reg [21:0] blink_cnt; reg blink;
    reg vs_d; reg [8:0] scroll_phase;
    wire vs_rise = vs_i & ~vs_d;
    always @(posedge clk) begin
      if(rst||!alarm_s) begin blink_cnt<=0;blink<=0; end
      else if(blink_cnt==BLINK_DIV-1) begin blink_cnt<=0;blink<=~blink; end
      else blink_cnt<=blink_cnt+1'b1;
    end
    always @(posedge clk) begin
      if(rst||!alarm_s) begin vs_d<=0;scroll_phase<=0; end
      else begin
        vs_d<=vs_i;
        if(vs_rise) scroll_phase<=scroll_phase+1'b1; // 512px 周期，每帧左移 1px
      end
    end

    reg hs1,vs1,de1,hs2,vs2,de2; reg [23:0] d1,d2;
    reg [11:0] x1,y1,x2,y2;
    always @(posedge clk) begin
      if(rst) begin hs1<=0;vs1<=0;de1<=0;hs2<=0;vs2<=0;de2<=0;d1<=0;d2<=0;x1<=0;y1<=0;x2<=0;y2<=0; end
      else begin hs1<=hs_i;vs1<=vs_i;de1<=de_i;d1<=data_i;x1<=px_x;y1<=px_y;
        hs2<=hs1;vs2<=vs1;de2<=de1;d2<=d1;x2<=x1;y2<=y1; end
    end

    // Text rows: large heading/type plus seven compact information rows.
    reg [4:0] text_id; reg [4:0] char_pos; reg [3:0] glyph_row; reg [3:0] glyph_col;
    reg text_hit; reg [11:0] text_x0; reg [11:0] text_x1; reg large_text,type_large,scroll_text;
    reg [6:0] gid; reg font_en; reg [10:0] font_addr; wire [15:0] font_q;
    reg text_hit_q; reg [3:0] glyph_col_q; reg large_q;
    // ★2026-09-21 面积优化(逐像素等价, 已由 sim/_tb_em_equiv.v 全栅格 A/B 验证):
    //   原版用 `integer len` + emergency_text_len(text_id) 再算 text_x0+len*16 /
    //   text_x0+len*32 —— integer 是 32bit 有符号, 于是每次窗口判定都生成
    //   "32bit 乘加 + 32bit 比较器"。改为**逐行直接给出窗口右沿常量 text_x1**
    //   (= text_x0 + 该行字数×每字宽度, 逐行静态可得), 判定退化为两个 12bit
    //   比较器, 并整块删掉 emergency_text_len 的多路 case 调用。
    // 2026-10-01 版式重排(用户要求): 删除左侧残留字列与「仅管理员可解除告警」行,
    //   内容整体水平居中 —— 所有信息行左沿 text_x0=216, 面板/底衬统一 x∈[192,448)。
    //   各行 (text_x0, 每字宽度, 字数) → text_x1:
    //     标题 (id0)      256 + 32×4  = 384
    //     应急类型大字     192 → 448(固定 4 字 × 64px)
    //     行 事件地点      216 + 16×(10/9/10)     → type2=360, 其余 376
    //     行 撤离指引1     216 + 16×(12/9/13/12)  → 408 / 360 / 424 / 408
    //     行 撤离指引2     216 + 16×(6/6/9/9)     → 312 / 312 / 360 / 360
    //     行 持续时间：    216 + 16×5  = 296
    //   计时数字行「持续时间：MM:SS」同线整体居中(x 中心 320):
    //     标签 216..296, 16px 间隔, 数字 312..424(d0 312/d1 336/冒号 366/
    //     d2 376/d3 400, 每字 24px)。
    //   ※ **关键修复(2026-10-01)**: 未命中任何行窗时, 旧版残留 text_x0=0/
    //     text_x1=64 这个"意外窗口"; 因 glyph_row=(y1-448) 截断后恒等于 y1 mod 16,
    //     会让「紧急告警」四字在左侧 x∈[0,64) 每 16 行重复一叠(即用户看到的
    //     左侧重叠乱码列)。现改为 text_x0=text_x1=0(空窗), 未命中行一律不落墨。
    always @(*) begin
      text_id=0;char_pos=0;glyph_row=0;glyph_col=0;text_hit=0;text_x0=0;text_x1=0;
      large_text=0;type_large=0;scroll_text=0;
      if(alarm_s && de1) begin
        if(y1>=12'd16 && y1<12'd48) begin text_id=0;text_x0=256;text_x1=384;large_text=1; end
        else if(y1>=12'd58 && y1<12'd122) begin text_id={3'd0,type_s}+1'b1;text_x0=192;text_x1=448;type_large=1; end
        // 2026-09-25: 原 y142..158 的「告警级别：紧急/警告/提示」行已删除。
        //   这里保留一个空窗(常量右沿 0 即永不命中), 目的是不让该行落回
        //   "未命中任何行窗"的默认 text_id=0 + x1∈[0,64) 分支, 否则左上方
        //   会冒出 id0 字形的残余笔画。text_id 取 31 使 gid 直接走 7'h7f。
        else if(y1>=12'd142 && y1<12'd158) begin text_id=5'd31;text_x0=12'd0;text_x1=12'd0; end
        else if(y1>=12'd174 && y1<12'd190) begin text_id=(type_s<2)?8:((type_s==2)?9:10);text_x0=216;
                                              text_x1=(type_s==2)?360:376; end
        else if(y1>=12'd222 && y1<12'd238) begin text_id=11+({3'd0,type_s}<<1);text_x0=216;
                                              text_x1=(type_s==1)?360:((type_s==2)?424:408); end
        else if(y1>=12'd254 && y1<12'd270) begin text_id=12+({3'd0,type_s}<<1);text_x0=216;
                                              text_x1=(type_s<2)?312:360; end
        else if(y1>=12'd310 && y1<12'd326) begin text_id=19;text_x0=216;text_x1=296; end
        // 2026-09-25: 原 y350..366 的「告警尚未解除」行已删除, 同法保留空窗。
        else if(y1>=12'd350 && y1<12'd366) begin text_id=5'd31;text_x0=12'd0;text_x1=12'd0; end
        // 2026-10-01: 原 y390..406 的「仅管理员可解除告警」行按用户要求删除, 同法保留空窗。
        else if(y1>=12'd390 && y1<12'd406) begin text_id=5'd31;text_x0=12'd0;text_x1=12'd0; end
        else if(y1>=12'd448 && y1<12'd464) begin text_id=22+{3'd0,type_s};scroll_text=1; end
        if(type_large) begin
          if(x1>=12'd192 && x1<12'd448) begin
            text_hit=1;char_pos=(x1-12'd192)>>6;glyph_col=((x1-12'd192)&63)>>2;
            glyph_row=(y1-12'd58)>>2;
          end
        end else if(large_text) begin
          if(x1>=text_x0 && x1<text_x1) begin
            text_hit=1;char_pos=(x1-text_x0)>>5;glyph_col=((x1-text_x0)&31)>>1;
            glyph_row=((y1-(text_id==0?16:68))&31)>>1;
          end
        end else if(scroll_text) begin
          text_hit=1;char_pos=(x1+scroll_phase)>>4;glyph_col=(x1+scroll_phase)&15;
          glyph_row=y1-448;
        end else if(x1>=text_x0 && x1<text_x1) begin
          text_hit=1;char_pos=(x1-text_x0)>>4;glyph_col=(x1-text_x0)&15;
          // 5,6,7「告警级别」/ 20「告警尚未解除」/ 21「仅管理员可解除告警」
          //   三行均已删除, 对应分支一并去掉。
          case(text_id) 8,9,10:glyph_row=y1-174;
            11,13,15,17:glyph_row=y1-222;12,14,16,18:glyph_row=y1-254;
            19:glyph_row=y1-310;
            default:glyph_row=y1-448;endcase
        end
      end
      gid=emergency_glyph_id(text_id,char_pos);
      font_en=text_hit&&(gid!=7'h7f);font_addr={gid,glyph_row};
    end
    emergency_font_rom u_em_font(.clk(clk),.en(font_en),.addr(font_addr),.q(font_q));
    always @(posedge clk) begin text_hit_q<=text_hit;glyph_col_q<=glyph_col;large_q<=large_text; end
    wire text_ink=text_hit_q && font_q[15-glyph_col_q];

    // Duration digits are drawn from the same glyph ROM using a second read-free
    // seven-segment renderer, keeping the font ROM single-port.
    function seg_on; input [3:0] d;input [2:0] s;begin case(d)
      0:seg_on=(s!=6);1:seg_on=(s==1||s==2);2:seg_on=(s==0||s==1||s==6||s==4||s==3);
      3:seg_on=(s==0||s==1||s==2||s==3||s==6);4:seg_on=(s==5||s==6||s==1||s==2);
      5:seg_on=(s==0||s==5||s==6||s==2||s==3);6:seg_on=(s!=1);7:seg_on=(s==0||s==1||s==2);
      8:seg_on=1;default:seg_on=(s!=4);endcase end endfunction
    reg digit_hit; reg [3:0] digit_val; reg [5:0] dx,dy; reg digit_ink;
    integer di;
    always @(*) begin
      digit_hit=0;digit_val=0;dx=0;dy=0;digit_ink=0;di=7;
      // 2026-10-01: 数字行随「持续时间：」标签整体居中(x 中心 320),
      //   标签 216..296 → 16px 间隙 → 数字 312..424(d0 312/d1 336/
      //   冒号 366..370 / d2 376 / d3 400, 每字 24px, 段内几何不变)。
      if(alarm_s&&y2>=300&&y2<334&&x2>=312&&x2<424) begin
        if(x2<336)begin di=0;digit_val=mt_s;dx=x2-312;end
        else if(x2<360)begin di=1;digit_val=mo_s;dx=x2-336;end
        else if(x2>=376&&x2<400)begin di=2;digit_val=st_s;dx=x2-376;end
        else if(x2>=400&&x2<424)begin di=3;digit_val=so_s;dx=x2-400;end
        dy=y2-300;digit_hit=(di<4);
        digit_ink=(seg_on(digit_val,0)&&dy<4&&dx>=4&&dx<20)||
          (seg_on(digit_val,3)&&dy>=28&&dy<32&&dx>=4&&dx<20)||
          (seg_on(digit_val,6)&&dy>=14&&dy<18&&dx>=4&&dx<20)||
          (seg_on(digit_val,5)&&dx<4&&dy>=4&&dy<15)||
          (seg_on(digit_val,4)&&dx<4&&dy>=17&&dy<28)||
          (seg_on(digit_val,1)&&dx>=20&&dy>=4&&dy<15)||
          (seg_on(digit_val,2)&&dx>=20&&dy>=17&&dy<28);
      end
      if(alarm_s&&x2>=366&&x2<370&&((y2>=309&&y2<313)||(y2>=321&&y2<325))) digit_ink=1;
    end

    // 2026-09-25: 原信息卡左侧的类型矢量图标(火焰/地震/云+闪电/疏散小人,
    //   窗口 x∈[50,174) y∈[132,286))按用户要求整体删除, 该区域现在只是
    //   页面暗底色, 信息卡文字与底部条带位置均不变。
    wire top_bar=(y2<56); wire type_band=(y2>=62&&y2<108);
    // 2026-10-01: 两块内容面板统一为同宽、水平居中(x∈[192,448), 中心 320),
    //   与左侧图标删除后的信息卡文字块对齐, 页面更规整。
    wire info_panel=(x2>=192&&x2<448&&y2>=126&&y2<286);
    wire timer_panel=(x2>=192&&x2<448&&y2>=294&&y2<338);
    // 2026-09-25: 原 status_band(x∈[208,432) y∈[342,374)) 是「告警尚未解除」
    //   的底衬, 文字删除后该空条一并去掉, 否则会留下一条无内容的色块。
    wire footer=(y2>=438);
    reg [23:0] accent,dark,panel; always @(*) begin
      case(type_s) 0:begin accent=24'hff3b30;dark=24'h3a0909;panel=24'h641515;end
        1:begin accent=24'hff9f0a;dark=24'h352008;panel=24'h5b3c12;end
        2:begin accent=24'h32ade6;dark=24'h082b3a;panel=24'h10465e;end
        default:begin accent=24'hbf5af2;dark=24'h281135;panel=24'h48205e;end endcase
    end
    reg [23:0] outpix; always @(*) begin
      outpix=d2;
      if(de2&&alarm_s) begin
        outpix=dark;
        if(top_bar) outpix=blink?accent:panel;
        else if(type_band||info_panel||timer_panel) outpix=panel;
        else if(footer) outpix=24'h101010;
        if(digit_ink) outpix=24'hffd60a;
        if(text_ink) begin
          if(y2>=58&&y2<122) outpix=24'hff3b30;
          else outpix=24'hffffff;
        end
      end
    end
    assign hs_o=hs2;assign vs_o=vs2;assign de_o=de2;assign data_o=outpix;assign px_x_o=x2;assign px_y_o=y2;
endmodule
