`timescale 1ns/1ps
// 48kHz sample clock enable and signed stereo PCM for existing HDMI IP audio input.
// 1 warning beep, 2 timeout beeps, repeated alarm. Events canceled on emergency.
module meeting_audio #(parameter CLK_HZ=100000000,SAMPLE_HZ=48000,
 BEEP_CYCLES=10000000,GAP_CYCLES=10000000)(
 input clk,rst,alarm,warn_event,timeout_event,
 output wire buzzer,output reg sample_valid,output wire signed [15:0] pcm_l,pcm_r,
 output wire tone_active);
reg [31:0] elapsed,carrier,sample_acc;
reg [1:0] kind;
reg wave,alarm_prev;
wire [31:0] halfperiod=kind==1?CLK_HZ/2000:CLK_HZ/1200;
wire ordinary=(kind==1 && elapsed<BEEP_CYCLES) ||
 (kind==2 && (elapsed<BEEP_CYCLES || (elapsed>=BEEP_CYCLES+GAP_CYCLES && elapsed<2*BEEP_CYCLES+GAP_CYCLES)));
assign tone_active=alarm?(elapsed%(BEEP_CYCLES+GAP_CYCLES)<BEEP_CYCLES):ordinary;
assign buzzer=tone_active && wave;
assign pcm_l=tone_active?(wave?16'sd6000:-16'sd6000):16'sd0;
assign pcm_r=pcm_l;
always @(posedge clk) begin
 if(rst) begin elapsed<=0;carrier<=0;sample_acc<=0;sample_valid<=0;kind<=0;wave<=0;alarm_prev<=0;end
 else begin
 alarm_prev<=alarm;sample_valid<=0;
 if(sample_acc+SAMPLE_HZ>=CLK_HZ) begin sample_acc<=sample_acc+SAMPLE_HZ-CLK_HZ;sample_valid<=1;end
 else sample_acc<=sample_acc+SAMPLE_HZ;
 if(carrier>=((halfperiod<1)?1:halfperiod)-1) begin carrier<=0;wave<=~wave;end else carrier<=carrier+1;
 if(alarm) begin kind<=0;
 if(!alarm_prev || elapsed>=BEEP_CYCLES+GAP_CYCLES-1) elapsed<=0;else elapsed<=elapsed+1;
 end else if(alarm_prev) begin kind<=0;elapsed<=0;end
 else if(timeout_event) begin kind<=2;elapsed<=0;carrier<=0;wave<=0;end
 else if(warn_event) begin kind<=1;elapsed<=0;carrier<=0;wave<=0;end
 else if(kind!=0) begin
 if(elapsed>=2*BEEP_CYCLES+GAP_CYCLES) begin kind<=0;elapsed<=0;end else elapsed<=elapsed+1;
 end
 end end
endmodule
