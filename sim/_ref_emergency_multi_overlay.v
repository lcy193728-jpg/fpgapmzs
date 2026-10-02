// 临时等价性参考件: 改前 emergency_multi_overlay.v 的逐字副本(仅改模块名)。
// 仅供 sim/_tb_em_equiv.v 做 A/B 逐像素对照, 不参与综合工程(pic_sdram_audio_final.al)。
`timescale 1ns/1ps

module emergency_multi_overlay_ref #(
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
        if(vs_rise) scroll_phase<=scroll_phase+1'b1;
      end
    end

    reg hs1,vs1,de1,hs2,vs2,de2; reg [23:0] d1,d2;
    reg [11:0] x1,y1,x2,y2;
    always @(posedge clk) begin
      if(rst) begin hs1<=0;vs1<=0;de1<=0;hs2<=0;vs2<=0;de2<=0;d1<=0;d2<=0;x1<=0;y1<=0;x2<=0;y2<=0; end
      else begin hs1<=hs_i;vs1<=vs_i;de1<=de_i;d1<=data_i;x1<=px_x;y1<=px_y;
        hs2<=hs1;vs2<=vs1;de2<=de1;d2<=d1;x2<=x1;y2<=y1; end
    end

    reg [4:0] text_id; reg [4:0] char_pos; reg [3:0] glyph_row; reg [3:0] glyph_col;
    reg text_hit; reg [11:0] text_x0; reg large_text,type_large,scroll_text;
    reg [6:0] gid; reg font_en; reg [10:0] font_addr; wire [15:0] font_q;
    reg text_hit_q; reg [3:0] glyph_col_q; reg large_q;
    integer len;
    always @(*) begin
      text_id=0;char_pos=0;glyph_row=0;glyph_col=0;text_hit=0;text_x0=0;large_text=0;type_large=0;scroll_text=0;len=0;
      if(alarm_s && de1) begin
        if(y1>=12'd16 && y1<12'd48) begin text_id=0;text_x0=256;large_text=1; end
        else if(y1>=12'd58 && y1<12'd122) begin text_id={3'd0,type_s}+1'b1;text_x0=192;type_large=1; end
        else if(y1>=12'd142 && y1<12'd158) begin text_id=(type_s<2)?5:((type_s==2)?6:7);text_x0=200; end
        else if(y1>=12'd174 && y1<12'd190) begin text_id=(type_s<2)?8:((type_s==2)?9:10);text_x0=200; end
        else if(y1>=12'd222 && y1<12'd238) begin text_id=11+({3'd0,type_s}<<1);text_x0=200; end
        else if(y1>=12'd254 && y1<12'd270) begin text_id=12+({3'd0,type_s}<<1);text_x0=200; end
        else if(y1>=12'd310 && y1<12'd326) begin text_id=19;text_x0=240; end
        else if(y1>=12'd350 && y1<12'd366) begin text_id=20;text_x0=272; end
        else if(y1>=12'd390 && y1<12'd406) begin text_id=21;text_x0=248; end
        else if(y1>=12'd448 && y1<12'd464) begin text_id=22+{3'd0,type_s};scroll_text=1; end
        len=emergency_text_len(text_id);
        if(type_large) begin
          if(x1>=12'd192 && x1<12'd448) begin
            text_hit=1;char_pos=(x1-12'd192)>>6;glyph_col=((x1-12'd192)&63)>>2;
            glyph_row=(y1-12'd58)>>2;
          end
        end else if(large_text) begin
          if(x1>=text_x0 && x1<text_x0+len*32) begin
            text_hit=1;char_pos=(x1-text_x0)>>5;glyph_col=((x1-text_x0)&31)>>1;
            glyph_row=((y1-(text_id==0?16:68))&31)>>1;
          end
        end else if(scroll_text) begin
          text_hit=1;char_pos=(x1+scroll_phase)>>4;glyph_col=(x1+scroll_phase)&15;
          glyph_row=y1-448;
        end else if(len!=0 && x1>=text_x0 && x1<text_x0+len*16) begin
          text_hit=1;char_pos=(x1-text_x0)>>4;glyph_col=(x1-text_x0)&15;
          case(text_id) 5,6,7:glyph_row=y1-142;8,9,10:glyph_row=y1-174;
            11,13,15,17:glyph_row=y1-222;12,14,16,18:glyph_row=y1-254;
            19:glyph_row=y1-310;20:glyph_row=y1-350;21:glyph_row=y1-390;
            default:glyph_row=y1-448;endcase
        end
      end
      gid=emergency_glyph_id(text_id,char_pos);
      font_en=text_hit&&(gid!=7'h7f);font_addr={gid,glyph_row};
    end
    emergency_font_rom u_em_font(.clk(clk),.en(font_en),.addr(font_addr),.q(font_q));
    always @(posedge clk) begin text_hit_q<=text_hit;glyph_col_q<=glyph_col;large_q<=large_text; end
    wire text_ink=text_hit_q && font_q[15-glyph_col_q];

    function seg_on; input [3:0] d;input [2:0] s;begin case(d)
      0:seg_on=(s!=6);1:seg_on=(s==1||s==2);2:seg_on=(s==0||s==1||s==6||s==4||s==3);
      3:seg_on=(s==0||s==1||s==2||s==3||s==6);4:seg_on=(s==5||s==6||s==1||s==2);
      5:seg_on=(s==0||s==5||s==6||s==2||s==3);6:seg_on=(s!=1);7:seg_on=(s==0||s==1||s==2);
      8:seg_on=1;default:seg_on=(s!=4);endcase end endfunction
    reg digit_hit; reg [3:0] digit_val; reg [5:0] dx,dy; reg digit_ink;
    integer di;
    always @(*) begin
      digit_hit=0;digit_val=0;dx=0;dy=0;digit_ink=0;di=7;
      if(alarm_s&&y2>=300&&y2<334&&x2>=336&&x2<456) begin
        if(x2<360)begin di=0;digit_val=mt_s;dx=x2-336;end
        else if(x2<384)begin di=1;digit_val=mo_s;dx=x2-360;end
        else if(x2>=400&&x2<424)begin di=2;digit_val=st_s;dx=x2-400;end
        else if(x2>=424&&x2<448)begin di=3;digit_val=so_s;dx=x2-424;end
        dy=y2-300;digit_hit=(di<4);
        digit_ink=(seg_on(digit_val,0)&&dy<4&&dx>=4&&dx<20)||
          (seg_on(digit_val,3)&&dy>=28&&dy<32&&dx>=4&&dx<20)||
          (seg_on(digit_val,6)&&dy>=14&&dy<18&&dx>=4&&dx<20)||
          (seg_on(digit_val,5)&&dx<4&&dy>=4&&dy<15)||
          (seg_on(digit_val,4)&&dx<4&&dy>=17&&dy<28)||
          (seg_on(digit_val,1)&&dx>=20&&dy>=4&&dy<15)||
          (seg_on(digit_val,2)&&dx>=20&&dy>=17&&dy<28);
      end
      if(alarm_s&&x2>=390&&x2<394&&((y2>=309&&y2<313)||(y2>=321&&y2<325))) digit_ink=1;
    end

    wire icon_box=(x2>=50&&x2<174&&y2>=132&&y2<286);
    wire [11:0] fdx=(x2>112)?x2-112:112-x2;
    wire [11:0] fdy=(y2>230)?y2-230:230-y2;
    wire fire_outer=((y2>=176&&y2<278)&&(fdx+(fdy>>1)<52))||
      ((y2>=140&&y2<226)&&fdx<((y2-140)>>1))||
      ((y2>=180&&y2<250)&&(x2>=72&&x2<112)&&((112-x2)<((y2-180)>>1)));
    wire fire_notch=(y2>=170&&y2<228&&x2>=112&&x2<154&&
      (x2-112)>((y2-170)>>1));
    wire fire_inner=(type_s==0)&&(y2>=214&&y2<274)&&fdx<((y2-202)>>2);
    wire fire_icon=(type_s==0)&&fire_outer&&!fire_notch;
    wire quake_icon=(type_s==1)&&(((x2>=76&&x2<148)&&(y2>=180&&y2<252)&&((x2[3:0]<3)||(y2[3:0]<3)))||
      ((y2>=150&&y2<160)&&(x2>=58&&x2<166))||((y2>=270&&y2<278)&&(x2>=58&&x2<166)));
    wire [11:0] c1dx=(x2>90)?x2-90:90-x2, c1dy=(y2>194)?y2-194:194-y2;
    wire [11:0] c2dx=(x2>126)?x2-126:126-x2, c2dy=(y2>190)?y2-190:190-y2;
    wire cloud=(type_s==2)&&(((c1dx+c1dy)<42)||((c2dx+c2dy)<46)||
      (x2>=70&&x2<150&&y2>=194&&y2<220));
    wire lightning=(type_s==2)&&(x2>=98&&x2<132&&y2>=218&&y2<274)&&
      ((x2<116&&y2<246)||(x2>=110&&y2>=240));
    wire [11:0] hdx=(x2>132)?x2-132:132-x2, hdy=(y2>170)?y2-170:170-y2;
    wire exit_door=((x2>=58&&x2<68)||(x2>=106&&x2<116)||(y2>=144&&y2<154))&&
      (x2>=58&&x2<116&&y2>=144&&y2<278);
    wire [11:0] arrow_dy=(y2>223)?y2-223:223-y2;
    wire exit_arrow=(x2>=116&&x2<170&&y2>=218&&y2<228)||
      (x2>=154&&x2<175&&arrow_dy<=((174-x2)>>1));
    wire runner=((hdx+hdy)<15)||(x2>=126&&x2<138&&y2>=184&&y2<226)||
      (x2>=112&&x2<152&&y2>=196&&y2<204)||
      (x2>=104&&x2<116&&y2>=220&&y2<258)||
      (x2>=142&&x2<154&&y2>=220&&y2<258);
    wire evac_icon=(type_s==3)&&(exit_door||exit_arrow||runner);
    wire icon_ink=icon_box&&(fire_icon||quake_icon||cloud||lightning||evac_icon);

    wire top_bar=(y2<56); wire type_band=(y2>=62&&y2<108);
    wire info_panel=(x2>=184&&x2<600&&y2>=126&&y2<286);
    wire timer_panel=(x2>=224&&x2<472&&y2>=294&&y2<338);
    wire status_band=(x2>=208&&x2<432&&y2>=342&&y2<374);
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
        else if(type_band||info_panel||timer_panel||status_band) outpix=panel;
        else if(footer) outpix=24'h101010;
        if(icon_box) outpix=24'h161616;
        if(icon_ink) outpix=(type_s==0)?24'hff7a00:24'hffd60a;
        if(fire_inner) outpix=24'hffd60a;
        if(digit_ink) outpix=24'hffd60a;
        if(text_ink) begin
          if(y2>=58&&y2<122) outpix=24'hff3b30;
          else if(y2>=350&&y2<366) outpix=24'hffd60a;
          else outpix=24'hffffff;
        end
      end
    end
    assign hs_o=hs2;assign vs_o=vs2;assign de_o=de2;assign data_o=outpix;assign px_x_o=x2;assign px_y_o=y2;
endmodule
