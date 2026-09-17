`timescale 1ns/1ps
module tb_meeting_edges;
reg clk=0;always #5 clk=~clk;
reg rst=1,en=1,ready=1,alarm=0;reg [3:0] press=0;
reg end_long=0,home_long=0;reg [4:0] total=3;
wire [2:0] state;wire [3:0] current;wire [15:0] remaining,overtime;
wire [15:0] duration=current==0?16'd61:(current==1?16'd20:16'd1);
wire alarm_paused,warn_event,timeout_event;wire [31:0] uptime;
meeting_ctrl #(.SEC_CYCLES(8)) dut(clk,rst,en,ready,alarm,press,end_long,home_long,total,duration,
 state,current,remaining,overtime,alarm_paused,warn_event,timeout_event,uptime);
integer errors=0,checks=0,warnings=0,timeouts=0,i;
always @(posedge clk) begin if(warn_event) warnings=warnings+1;if(timeout_event) timeouts=timeouts+1;end
task cycles;input integer n;begin repeat(n) @(negedge clk);end endtask
task check;input c;input [639:0] m;begin checks=checks+1;
 if(c!==1'b1) begin errors=errors+1;$display("FAIL %0s",m);end else $display("PASS %0s",m);end endtask
task key;input [3:0] k;begin press=k;cycles(1);press=0;cycles(2);end endtask
initial begin
 cycles(3);rst=0;cycles(1);key(1);check(state==1 && remaining==61,"61s starts normal");
 cycles(8);check(state==3 && remaining==60 && warnings==1,"exact 61-to-60 warning");
 key(1);cycles(16);check(state==2 && remaining==60,"warning pause");
 key(1);cycles(5);check(warnings==1,"resume never repeats warning");
 // Pause immediately before a tick and resume the fractional second.
 while(dut.subsecond!=7) cycles(1);
 press=1;cycles(1);press=0;cycles(1);i=remaining;cycles(20);
 check(remaining==i && dut.subsecond==7,"pause wins coincident second tick");
 key(1);check(remaining==i-1,"fractional second retained on resume");
 // Emergency exactly at topic switch: old topic duration must not leak.
 press=2;cycles(1);press=0;alarm=1;cycles(1);
 check(state==2 && current==1,"alarm at MEET_SWITCH preserves new index");
 alarm=0;cycles(10);check(state==2,"alarm clear never auto resumes");
 key(1);check(remaining==20 && state==3,"resume loads interrupted switch duration");
 check(warnings==2,"short topic reminder once at start");
 key(2);check(current==2 && remaining==1,"one second topic");
 cycles(8);check(state==4 && remaining==0 && timeouts==1,"one second topic times out once");
 cycles(16);check(overtime>=2,"overtime increments");
 alarm=1;cycles(2);i=overtime;cycles(20);check(overtime==i && state==2,"emergency freezes overtime");
 alarm=0;cycles(10);key(1);check(state==4,"post alarm resume restores timeout");
 // Exhaustive state disable behavior.
 en=0;i=overtime;cycles(20);check(overtime==i,"disabled overtime freezes");en=1;
 end_long=1;cycles(1);end_long=0;cycles(16);check(state==6,"finished remains finished");
 alarm=1;cycles(3);alarm=0;cycles(3);check(state==6,"alarm does not restart finished meeting");
 home_long=1;cycles(1);home_long=0;cycles(2);check(state==0 && current==0,"home clears state");
 // Conflicting key priority is deterministic, NEXT precedes PREVIOUS.
 key(6);check(current==1,"simultaneous NEXT/PREVIOUS priority");
 $display("RESULT checks=%0d errors=%0d",checks,errors);
 if(errors==0) $display("ALL TESTS PASSED");$stop;
end
initial begin #1000000;$display("FAIL watchdog");errors=errors+1;$stop;end
endmodule
