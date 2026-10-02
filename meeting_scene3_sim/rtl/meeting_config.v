`timescale 1ns/1ps
// Streaming MTG1 parser. Reload is only accepted while controller is idle.
// A bad/truncated configuration never enables START; completion is atomic.
module meeting_config(input clk, rst, start, valid, last, input [7:0] data,
 output reg ready, error, output reg [4:0] total,
 input [3:0] current, output [15:0] duration, next_duration,
 output [319:0] title, next_title, meeting_name, organizer, venue, notice,
 output [159:0] speaker, next_speaker, input [1:0] notice_sel,
 input [3:0] overview_index, output [319:0] overview_title);
reg [7:0] text_mem[0:1271]; // 280 metadata bytes + 16 * 62 bytes
reg [31:0] pos;
reg [4:0] pending_total;
reg bad;
integer i;
wire [31:0] expected=285+pending_total*62;
assign duration={text_mem[280+current*62],text_mem[281+current*62]};
assign next_duration=(current+1<total)?{text_mem[342+current*62],text_mem[343+current*62]}:0;
generate genvar g; for(g=0;g<40;g=g+1) begin: texts
 assign meeting_name[319-g*8-:8]=text_mem[g];
 assign organizer[319-g*8-:8]=text_mem[40+g];
 assign venue[319-g*8-:8]=text_mem[80+g];
 assign notice[319-g*8-:8]=text_mem[120+notice_sel*40+g];
 assign title[319-g*8-:8]=text_mem[282+current*62+g];
 assign next_title[319-g*8-:8]=(current+1<total)?text_mem[344+current*62+g]:0;
 assign overview_title[319-g*8-:8]=text_mem[282+overview_index*62+g];
 end
 for(g=0;g<20;g=g+1) begin: speakers
 assign speaker[159-g*8-:8]=text_mem[322+current*62+g];
 assign next_speaker[159-g*8-:8]=(current+1<total)?text_mem[384+current*62+g]:0;
 end endgenerate
always @(posedge clk) begin
 if(rst) begin ready<=0;error<=0;total<=0;pos<=0;pending_total<=0;bad<=0;
 for(i=0;i<1272;i=i+1) text_mem[i]<=0;
 end else if(start) begin ready<=0;error<=0;pos<=0;pending_total<=0;bad<=0; end
 else if(valid && !ready && !error) begin
 pos<=pos+1;
 if(pos<4) begin
 case(pos)
 0: if(data!=8'h4d) bad<=1;
 1: if(data!=8'h54) bad<=1;
 2: if(data!=8'h47) bad<=1;
 3: if(data!=8'h31) bad<=1;
 endcase end
 else if(pos==4) begin pending_total<=data[4:0]; if(data==0 || data>16) bad<=1; end
 else if(pos<expected && pos<1277) begin
 text_mem[pos-5]<=data;
 // Validate duration at its low byte (previous high byte already stored).
 if(pos>=286 && (pos-286)%62==0)
 if({text_mem[pos-6],data}==0 || {text_mem[pos-6],data}>5999) bad<=1;
 end
 if(last) begin
 if(bad || pos+1<expected || pending_total==0) error<=1;
 else begin ready<=1;total<=pending_total;end
 end
 end
end
endmodule
