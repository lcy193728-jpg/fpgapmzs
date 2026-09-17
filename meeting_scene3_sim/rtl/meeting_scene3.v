`timescale 1ns/1ps
// Standalone simulation module. Existing top/osd_scene/ui_key_ctrl unchanged.
module meeting_scene3 #(parameter SEC_CYCLES=100000000,DEB_MAX=2000000,
 LONG_CYCLES=100000000,CLK_HZ=100000000,BEEP_CYCLES=10000000,GAP_CYCLES=10000000)(
 input clk,rst,en,input [3:0] key_raw,input emergency_raw,alarm_clear,
 input cfg_start,cfg_valid,cfg_last,input [7:0] cfg_data,
 input hs_i,vs_i,de_i,input [23:0] data_i,input [11:0] px_x,px_y,
 output hs_o,vs_o,de_o,output [23:0] data_o,output [11:0] px_x_o,px_y_o,
 output [2:0] state,output [3:0] current,output [15:0] remaining,overtime,
 output alarm,alarm_paused,config_ready,config_error,output [4:0] total,
 output buzzer,output sample_valid,output signed [15:0] pcm_l,pcm_r,
 output [7:0] seg_sel,seg_data,output [15:0] timer_bcd,
 output warn_event,timeout_event);
reg emergency_meta,emergency_sync,alarm_latch;
always @(posedge clk) begin
 if(rst) begin emergency_meta<=0;emergency_sync<=0;alarm_latch<=0;end
 else begin emergency_meta<=emergency_raw;emergency_sync<=emergency_meta;
 if(emergency_sync) alarm_latch<=1;else if(alarm_clear) alarm_latch<=0;end
end
assign alarm=alarm_latch;
wire [3:0] press;wire end_long,home_long;
meeting_keys #(.DEB_MAX(DEB_MAX),.LONG_CYCLES(LONG_CYCLES)) keys(clk,rst,key_raw,press,end_long,home_long);
wire [15:0] duration,next_duration;
wire [319:0] title,next_title,meeting_name,organizer,venue,notice,overview_title;
wire [159:0] speaker,next_speaker;
wire [1:0] notice_sel;wire [3:0] overview_index;
// Never accept reload while a meeting is active/paused; protects saved agenda state.
meeting_config cfg(clk,rst,cfg_start && state==0 && !alarm,cfg_valid && state==0 && !alarm,cfg_last,cfg_data,
 config_ready,config_error,total,current,duration,next_duration,title,next_title,
 meeting_name,organizer,venue,notice,speaker,next_speaker,notice_sel,overview_index,overview_title);
wire [31:0] uptime;
meeting_ctrl #(.SEC_CYCLES(SEC_CYCLES)) ctrl(clk,rst,en,config_ready,alarm,press,end_long,home_long,
 total,duration,state,current,remaining,overtime,alarm_paused,warn_event,timeout_event,uptime);
meeting_osd osd(clk,rst,en,alarm,hs_i,vs_i,de_i,data_i,px_x,px_y,state,current,total,
 remaining,overtime,duration,next_duration,uptime,alarm_paused,title,next_title,meeting_name,
 organizer,venue,notice,overview_title,speaker,next_speaker,hs_o,vs_o,de_o,data_o,px_x_o,px_y_o,notice_sel,overview_index);
wire tone_active;
meeting_audio #(.CLK_HZ(CLK_HZ),.BEEP_CYCLES(BEEP_CYCLES),.GAP_CYCLES(GAP_CYCLES))
 audio(clk,rst,alarm,warn_event,timeout_event,buzzer,sample_valid,pcm_l,pcm_r,tone_active);
wire [15:0] displayed=(state==4 || (state==2 && remaining==0))?overtime:remaining;
assign timer_bcd[15:12]=(displayed/600)%10;
assign timer_bcd[11:8]=(displayed/60)%10;
assign timer_bcd[7:4]=(displayed%60)/10;
assign timer_bcd[3:0]=displayed%10;
wire [6:0] s0,s1,s2,s3;
seg_decoder d0(timer_bcd[15:12],s0);seg_decoder d1(timer_bcd[11:8],s1);
seg_decoder d2(timer_bcd[7:4],s2);seg_decoder d3(timer_bcd[3:0],s3);
seg_scan #(.CLK_FREQ(CLK_HZ)) scan(clk,!rst,seg_sel,seg_data,
 {1'b1,s0},{1'b0,s1},{1'b1,s2},{1'b1,s3},8'hff,8'hff,8'hff,8'hff);
endmodule
