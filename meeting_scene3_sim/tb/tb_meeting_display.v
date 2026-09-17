`timescale 1ns/1ps
// Renderer driven by stable state snapshots, independently from accelerated timer.
module tb_meeting_display;
reg clk=0;always #5 clk=~clk;
reg rst=1,en=1,alarm=0,hs_i=0,vs_i=0,de_i=0;
reg [23:0] data_i=24'h345678;reg [11:0] px_x=0,px_y=0;
reg [2:0] state=0;reg [3:0] current=0;reg [15:0] remaining=300,overtime=38;
reg [31:0] uptime=1234;reg alarm_paused=0;
reg start=0,valid=0,last=0;reg [7:0] data=0;
wire ready,error;wire [4:0] total;wire [15:0] duration,next_duration;
wire [319:0] title,next_title,meeting_name,organizer,venue,notice,overview_title;
wire [159:0] speaker,next_speaker;wire [1:0] notice_sel;wire [3:0] overview_index;
meeting_config cfg(clk,rst,start,valid,last,data,ready,error,total,current,duration,next_duration,
 title,next_title,meeting_name,organizer,venue,notice,speaker,next_speaker,notice_sel,overview_index,overview_title);
wire hs_o,vs_o,de_o;wire [23:0] data_o;wire [11:0] px_x_o,px_y_o;
meeting_osd dut(clk,rst,en,alarm,hs_i,vs_i,de_i,data_i,px_x,px_y,state,current,total,
 remaining,overtime,duration,next_duration,uptime,alarm_paused,title,next_title,meeting_name,
 organizer,venue,notice,overview_title,speaker,next_speaker,
 hs_o,vs_o,de_o,data_o,px_x_o,px_y_o,notice_sel,overview_index);
reg [7:0] image[0:1023];reg [2047:0] run_dir;
integer errors=0,checks=0,i,x,y,f,handle,green,yellow,red,ink,saved_ink,saved_phase;
task cycles;input integer n;begin repeat(n) @(negedge clk);end endtask
task check;input c;input [639:0] m;begin checks=checks+1;
 if(c!==1'b1) begin errors=errors+1;$display("FAIL %0s",m);end else $display("PASS %0s",m);end endtask
task tick_frame;begin vs_i=1;cycles(1);vs_i=0;cycles(1);end endtask
task render;input [255:0] name;begin
 handle=$fopen({run_dir,"/",name},"wb");$fwrite(handle,"P6\n640 480\n255\n");green=0;yellow=0;red=0;ink=0;
 tick_frame;
 for(y=0;y<480;y=y+1) for(x=0;x<640;x=x+1) begin
 px_x=x;px_y=y;de_i=1;@(posedge clk);#1;
 $fwrite(handle,"%c%c%c",data_o[23:16],data_o[15:8],data_o[7:0]);
 if(y>=228 && y<292 && x<350) begin
 if(data_o==24'h26c281) green=green+1;
 if(data_o==24'hffd24a) yellow=yellow+1;
 if(data_o==24'hff2a2a) red=red+1;
 if(data_o!=24'h0a2647) ink=ink+1;
 end
 @(negedge clk);
 end de_i=0;$fclose(handle);
 check(px_x_o==639 && px_y_o==479 && de_o,"RGB/sync/coordinates align in full frame");
end endtask
initial begin
 if(!$value$plusargs("RUN_DIR=%s",run_dir)) run_dir="runs/manual_display";
 $readmemh("assets/meeting.hex",image);cycles(3);rst=0;start=1;cycles(1);start=0;
 for(i=0;i<1024;i=i+1) begin valid=1;data=image[i];last=i==1023;cycles(1);end valid=0;last=0;cycles(2);
 check(ready && !error,"display receives parsed TF metadata");
 render("01_idle.ppm");
 state=1;current=2;remaining=276;render("02_running.ppm");check(green>1000 && yellow==0 && red==0,"normal countdown green real glyph ink");
 state=2;render("03_paused.ppm");
 state=3;remaining=60;render("04_warning.ppm");check(yellow>1000 && green==0 && red==0,"warning countdown yellow");
 state=4;remaining=0;overtime=38;
 while(!dut.frames[4]) tick_frame;
 render("05_timeout.ppm");check(red>1000 && green==0 && yellow==0,"overtime red real glyph ink");saved_ink=red;
 while(dut.frames[4]) tick_frame;
 render("06_timeout_blink_off.ppm");check(red==0 && saved_ink>0,"timeout digits blink");
 state=5;remaining=180;render("07_switch.ppm");
 state=6;current=5;render("08_finished.ppm");
 state=2;alarm_paused=1;alarm=1;saved_phase=dut.phase;render("09_alarm.ppm");
 check(dut.phase==saved_phase,"alarm freezes meeting notices");
 alarm=0;render("10_alarm_cleared.ppm");
 saved_phase=dut.phase;tick_frame;check(dut.phase==saved_phase+1,"notice scroll advances once per frame");
 for(f=0;f<2600;f=f+1) tick_frame;
 check(notice_sel==0,"all four meeting notices loop");
 $display("RESULT checks=%0d errors=%0d",checks,errors);
 if(errors==0) $display("ALL TESTS PASSED");$stop;
end
initial begin #100000000;$display("FAIL watchdog");errors=errors+1;$stop;end
endmodule
