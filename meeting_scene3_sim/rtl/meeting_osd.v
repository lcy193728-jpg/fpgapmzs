`timescale 1ns/1ps
// One clock independent simulation profile, same {hs,vs,de,RGB888,12-bit px}
// interface style as main osd_scene. Output registered 1 cycle, all sync aligned.
// Host integration must cross coherent state/text using snapshot handshake/FIFO.
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
reg vs_prev;
reg [15:0] phase;
reg [7:0] frames;
reg [31:0] uptime_view;
reg [319:0] line;
reg [7:0] glyph;
reg [23:0] color,pixel;
reg ink_allowed;
reg [3:0] bit_column;
integer row,col,scale,origin,line_y,char_index,local_x,local_y,t,mins,secs,progress;
wire [15:0] bits;
wire [23:0] composed=(ink_allowed && bits[bit_column])?color:pixel;
wire [11:0] addr={glyph,local_y[3:0]};
meeting_glyph_rom font(addr,bits);
assign overview_index=(state==0 && px_y>=140 && px_y<332)?
 (((px_y-140)/24)+((total>8 && frames[7])?8:0)):0;
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
always @* begin
 pixel=data_i;color=24'hf5fdff;line=0;scale=1;origin=24;line_y=-100;
 row=0;col=0;char_index=0;local_x=0;local_y=0;glyph=0;
 ink_allowed=0;bit_column=0;
 t=(remaining==0 && state!=0)?overtime:remaining;mins=t/60;secs=t%60;
 progress=total==0?0:(state==6?592:(current*592/total));
 if(de_i && en) begin
 // Fixed background supplied by existing framebuffer; only panel areas overlaid.
 if(px_y<110 || (px_y>=116 && px_y<428) || px_y>=438) pixel=24'h0a2647;
 if(px_y==108 || px_y==432) pixel=24'hffd24a;
 if(px_y>=12 && px_y<44) begin line=meeting_name;scale=2;line_y=12;end
 else if(px_y>=52 && px_y<68) begin line=organizer;line_y=52;end
 else if(px_y>=76 && px_y<92) begin
 line=venue;line_y=76;
 if(px_x>=360) begin origin=360;line=TEXT_17;
 if(px_x>=488) begin origin=488;line=0;
 line[319-:8]=digit_id((uptime_view/3600)%100/10);line[311-:8]=digit_id((uptime_view/3600)%10);
 line[303-:8]=COLON_ID;line[295-:8]=digit_id((uptime_view/60)%60/10);line[287-:8]=digit_id((uptime_view/60)%10);
 line[279-:8]=COLON_ID;line[271-:8]=digit_id((uptime_view%60)/10);line[263-:8]=digit_id(uptime_view%10);end end
 end
 else if(state==0 && px_y>=116 && px_y<132) begin line=TEXT_18;line_y=116;
 if(px_x>=400) begin origin=400;line=TEXT_8;end end
 else if(state==0 && px_y>=140 && px_y<332) begin
 if(overview_index<total && (px_y-140)%24<16) begin
 line=overview_title;line_y=140+((px_y-140)/24)*24;origin=72;
 if(px_x<64) begin origin=24;line=0;line[319-:8]=digit_id((overview_index+1)/10);line[311-:8]=digit_id((overview_index+1)%10);end
 end
 end
 else if(state!=0 && px_y>=124 && px_y<156) begin line=title;line_y=124;scale=2;end
 else if(state!=0 && px_y>=168 && px_y<184) begin line=TEXT_1;line_y=168;
 if(px_x>=152) begin origin=152;line={speaker,160'd0};end end
 else if(state!=0 && px_y>=202 && px_y<218) begin line=(state==4 || (remaining==0 && overtime!=0))?TEXT_3:TEXT_2;line_y=202;end
 else if(state!=0 && px_y>=228 && px_y<292) begin
 line_y=228;scale=4;line=0;line[319-:8]=digit_id(mins/10);line[311-:8]=digit_id(mins%10);
 line[303-:8]=COLON_ID;line[295-:8]=digit_id(secs/10);line[287-:8]=digit_id(secs%10);
 color=remaining>60?24'h26c281:(remaining>0?24'hffd24a:24'hff2a2a);
 if(remaining==0 && !frames[4]) color=24'h0a2647;
 end
 else if(px_y>=306 && px_y<322) begin
 line_y=306;case(state)
 0:line=TEXT_8;1:line=TEXT_9;2:line=alarm_paused?TEXT_15:TEXT_10;
 3:line=TEXT_11;4:line=TEXT_12;5:line=TEXT_13;6:line=TEXT_14;default:line=0;endcase
 end
 else if(px_y>=334 && px_y<350) begin line=TEXT_4;line_y=334;
 if(px_x>=104) begin origin=104;line=0;line[319-:8]=digit_id((current+1)/10);line[311-:8]=digit_id((current+1)%10);
 line[303-:8]=SLASH_ID;line[295-:8]=digit_id(total/10);line[287-:8]=digit_id(total%10);end
 end
 else if(px_y>=360 && px_y<376) begin line=TEXT_5;line_y=360;
 if(px_x>=152) begin origin=152;line=current+1<total?next_title:TEXT_19;end end
 else if(px_y>=384 && px_y<400) begin line=TEXT_6;line_y=384;
 if(px_x>=152) begin origin=152;line={next_speaker,160'd0};end
 if(px_x>=376) begin origin=376;line=TEXT_7;end
 if(px_x>=520) begin origin=520;line=0;line[319-:8]=digit_id(next_duration/600);line[311-:8]=digit_id((next_duration/60)%10);
 line[303-:8]=COLON_ID;line[295-:8]=digit_id((next_duration%60)/10);line[287-:8]=digit_id(next_duration%10);end
 end
 else if(px_y>=450 && px_y<466) begin line=notice;line_y=450;origin=0;end
 if(px_y>=410 && px_y<422 && px_x>=24 && px_x<616) pixel=px_x-24<progress?24'h26c281:24'h28425d;
 if(px_y>=line_y && px_y<line_y+16*scale && px_x>=origin) begin
 local_x=(px_x-origin)/scale;
 if(line_y==450) local_x=(px_x+phase)%640;
 char_index=local_x/16;local_y=(px_y-line_y)/scale;
 if(char_index<40) begin glyph=line[319-char_index*8-:8];
 ink_allowed=1;bit_column=15-(local_x%16);end
 end
 // Minimal highest-layer emergency integration preview; full alarm scene is unchanged.
 if(alarm && px_y<64) begin pixel=frames[4]?24'hff2a2a:24'h8a0000;
 line=TEXT_16;local_x=px_x/2;local_y=(px_y-16)/2;char_index=local_x/16;
 glyph=char_index<40?line[319-char_index*8-:8]:0;
 ink_allowed=px_y>=16 && px_y<48;bit_column=15-(local_x%16);color=24'hffffff;
 end
 end
end
always @(posedge clk) begin
 if(rst) begin hs_o<=0;vs_o<=0;de_o<=0;data_o<=0;px_x_o<=0;px_y_o<=0;end
 else begin hs_o<=hs_i;vs_o<=vs_i;de_o<=de_i;data_o<=composed;px_x_o<=px_x;px_y_o<=px_y;end
end
endmodule
