`timescale 1ns/1ps
module meeting_ctrl #(parameter SEC_CYCLES=100000000)(
 input clk,rst,en,config_ready,alarm, input [3:0] press,
 input end_long,home_long, input [4:0] total,input [15:0] duration,
 output reg [2:0] state, output reg [3:0] current,
 output reg [15:0] remaining,overtime, output reg alarm_paused,
 output reg warn_event,timeout_event, output reg [31:0] uptime);
localparam MEET_IDLE=0, MEET_RUNNING=1, MEET_PAUSED=2, MEET_WARNING=3,
 MEET_TIMEOUT=4, MEET_SWITCH=5, MEET_FINISHED=6;
reg [31:0] subsecond,run_div;
reg [3:0] switch_wait;
reg warned,switch_idle,resume_load;
wire active=(state==MEET_RUNNING || state==MEET_WARNING || state==MEET_TIMEOUT);
always @(posedge clk) begin
 if(rst) begin state<=MEET_IDLE;current<=0;remaining<=0;overtime<=0;
 alarm_paused<=0;warn_event<=0;timeout_event<=0;uptime<=0;subsecond<=0;run_div<=0;
 warned<=0;switch_idle<=1;resume_load<=0;switch_wait<=0;end
 else begin
 warn_event<=0;timeout_event<=0;
 if(run_div==SEC_CYCLES-1) begin run_div<=0;uptime<=uptime+1;end else run_div<=run_div+1;
 // Emergency beats every key and a coincident timer tick. Fractional second retained.
 if(alarm) begin
 if(state!=MEET_FINISHED) begin
 if(state==MEET_SWITCH || state==MEET_IDLE) resume_load<=1;
 state<=MEET_PAUSED;alarm_paused<=1;end
 end else if(en && config_ready) begin
 if(home_long) begin current<=0;remaining<=0;overtime<=0;subsecond<=0;
 state<=MEET_IDLE;alarm_paused<=0;warned<=0;resume_load<=0;switch_wait<=0;end
 else if(end_long) begin state<=MEET_FINISHED;subsecond<=0;end
 else if(press[1]) begin
 if(current+1>=total) begin state<=MEET_FINISHED;subsecond<=0;end
 else begin current<=current+1;state<=MEET_SWITCH;switch_idle<=0;switch_wait<=0;end
 end else if(press[2]) begin
 if(current!=0) begin current<=current-1;state<=MEET_SWITCH;switch_idle<=0;switch_wait<=0;end
 end else if(press[3]) begin state<=MEET_SWITCH;switch_idle<=state==MEET_IDLE;switch_wait<=0;end
 else if(state==MEET_SWITCH) begin
 // meeting_cfg uses a synchronous BRAM and needs several video clocks after
 // current changes to publish the new duration. Waiting ten clocks prevents
 // the previous agenda duration from being loaded into the new agenda.
 if(switch_wait<4'd10) switch_wait<=switch_wait+1'b1;
 else begin
 remaining<=duration;overtime<=0;subsecond<=0;warned<=0;alarm_paused<=0;resume_load<=0;
 if(switch_idle) state<=MEET_IDLE;
 else if(duration<=60) begin state<=MEET_WARNING;warned<=1;warn_event<=1;end
 else state<=MEET_RUNNING;
 end
 end else if(press[0]) begin
 if(state==MEET_IDLE) begin state<=MEET_SWITCH;switch_idle<=0;switch_wait<=0;end
 else if(active) state<=MEET_PAUSED;
 else if(state==MEET_PAUSED) begin
 alarm_paused<=0;
 // Alarm before START must load first topic rather than resume a zero timer.
 if(resume_load || (remaining==0 && overtime==0 && !warned)) begin state<=MEET_SWITCH;switch_idle<=0;switch_wait<=0;end
 else if(remaining==0) state<=MEET_TIMEOUT;
 else if(remaining<=60) state<=MEET_WARNING;
 else state<=MEET_RUNNING;
 end
 end else if(active) begin
 if(subsecond==SEC_CYCLES-1) begin subsecond<=0;
 if(remaining>0) begin
 remaining<=remaining-1;
 if(remaining==61 && !warned) begin state<=MEET_WARNING;warned<=1;warn_event<=1;end
 if(remaining==1) begin state<=MEET_TIMEOUT;timeout_event<=1;overtime<=0;end
 end else if(overtime<5999) overtime<=overtime+1;
 end else subsecond<=subsecond+1;
 end
 end
 end
end
endmodule
