`timescale 1ns/1ps
module tb_meeting_scene3;
reg clk=0;always #5 clk=~clk;
reg rst=1,en=1;reg [3:0] key_raw=15;
reg emergency_raw=0,alarm_clear=0,cfg_start=0,cfg_valid=0,cfg_last=0;
reg [7:0] cfg_data=0;reg hs_i=0,vs_i=0,de_i=0;
reg [23:0] data_i=24'h345678;reg [11:0] px_x=0,px_y=0;
wire hs_o,vs_o,de_o;wire [23:0] data_o;wire [11:0] px_x_o,px_y_o;
wire [2:0] state;wire [3:0] current;wire [15:0] remaining,overtime;
wire alarm,alarm_paused,config_ready,config_error;wire [4:0] total;
wire buzzer,sample_valid;wire signed [15:0] pcm_l,pcm_r;
wire [7:0] seg_sel,seg_data;wire [15:0] timer_bcd;wire warn_event,timeout_event;
meeting_scene3 #(.SEC_CYCLES(200),.DEB_MAX(3),.LONG_CYCLES(100),
 .CLK_HZ(100000000),.BEEP_CYCLES(30),.GAP_CYCLES(20)) dut(
 clk,rst,en,key_raw,emergency_raw,alarm_clear,cfg_start,cfg_valid,cfg_last,cfg_data,
 hs_i,vs_i,de_i,data_i,px_x,px_y,hs_o,vs_o,de_o,data_o,px_x_o,px_y_o,
 state,current,remaining,overtime,alarm,alarm_paused,config_ready,config_error,total,
 buzzer,sample_valid,pcm_l,pcm_r,seg_sel,seg_data,timer_bcd,warn_event,timeout_event);
reg [7:0] image[0:1023];
integer errors=0,checks=0,warnings=0,timeouts=0,steps,i,f,x,y,handle;
integer saved,old_warn,old_time;reg [2:0] expected_state;
reg [2047:0] run_dir;
always @(posedge clk) if(!rst) begin
 if(warn_event) warnings=warnings+1;
 if(timeout_event) timeouts=timeouts+1;
 if(sample_valid && pcm_l!==pcm_r) begin $display("FAIL stereo mismatch");errors=errors+1;end
end
task check;input condition;input [639:0] msg;begin
 checks=checks+1;if(condition!==1'b1) begin errors=errors+1;$display("FAIL %0s state=%d rem=%d",msg,state,remaining);end
 else $display("PASS %0s",msg);end endtask
task cycles;input integer n;begin repeat(n) @(negedge clk);end endtask
task key;input integer n;begin key_raw[n]=0;cycles(15);key_raw[n]=1;cycles(15);end endtask
task held_key;input integer n;begin key_raw[n]=0;cycles(130);key_raw[n]=1;cycles(15);end endtask
task load_cfg;input integer mode;begin
 cfg_start=1;cycles(1);cfg_start=0;
 for(i=0;i<(mode==2?20:1024);i=i+1) begin
 cfg_valid=1;cfg_data=image[i];
 if(mode==1 && i==0) cfg_data=0;
 if(mode==3 && i==4) cfg_data=0;
 if(mode==4 && (i==285 || i==286)) cfg_data=0;
 if(mode==5 && i==4) cfg_data=17;
 cfg_last=i==(mode==2?19:1023);cycles(1);
 // Byte gaps model a noncontinuous sector stream.
 if(i%13==0) begin cfg_valid=0;cfg_last=0;cycles(2);end
 end cfg_valid=0;cfg_last=0;cycles(3);
end endtask
task wait_rem;input integer target;begin
 steps=0;while(remaining!=target && steps<200000) begin cycles(1);steps=steps+1;end
 check(remaining==target,"countdown reached target");end endtask
task frame;input [255:0] name;begin
 // Temporarily disable timing while obtaining a complete coherent software frame.
 en=0;cycles(2);en=1;
 handle=$fopen({run_dir,"/",name},"w");$fwrite(handle,"P3\n640 480\n255\n");
 vs_i=1;cycles(1);vs_i=0;
 for(y=0;y<480;y=y+1) for(x=0;x<640;x=x+1) begin
 @(negedge clk);px_x=x;px_y=y;de_i=1;
 @(posedge clk);#1;$fwrite(handle,"%0d %0d %0d\n",data_o[23:16],data_o[15:8],data_o[7:0]);
 end
 @(negedge clk);de_i=0;$fclose(handle);
end endtask
initial begin
 if(!$value$plusargs("RUN_DIR=%s",run_dir)) run_dir="runs/manual";
 $dumpfile({run_dir,"/meeting.vcd"});
 $dumpvars(0,clk,rst,key_raw,state,current,remaining,overtime,alarm,alarm_paused,config_ready,warn_event,timeout_event,buzzer,pcm_l);
 $readmemh("assets/meeting.hex",image);cycles(4);rst=0;cycles(3);
 load_cfg(1);check(config_error && !config_ready,"bad magic rejected");key(0);check(state==0,"START blocked without config");
 load_cfg(2);check(config_error,"truncated config rejected");
 load_cfg(3);check(config_error,"zero agenda count rejected");
 load_cfg(4);check(config_error,"zero duration rejected");
 load_cfg(5);check(config_error,"excess agenda count rejected");
 load_cfg(0);check(config_ready && total==6 && !config_error,"TF byte stream parsed with gaps");
 check(dut.duration==120 && dut.next_duration==180,"current and next planned duration");
 check(dut.title[319-:8]==image[287] && dut.speaker[159-:8]==image[327],"title/speaker loaded from TF payload");
 // Full image capture while IDLE; countdown is inactive.
 frame("idle.ppm");check(state==0,"idle overview remains idle");
 key_raw[0]=0;cycles(1);key_raw[0]=1;cycles(10);check(state==0,"key bounce filtered");
 key(0);check(state==1 && current==0 && remaining==120,"KEY1 start first agenda");
 check(timer_bcd==16'h0200,"seven segment MM:SS BCD");
 key(0);check(state==2,"KEY1 pause");saved=remaining;cycles(600);check(remaining==saved,"paused countdown frozen");
 frame("paused.ppm");check(remaining==saved,"pause retained during frame rendering");
 key(0);check(state==1,"KEY1 resume");
 old_warn=warnings;wait_rem(60);cycles(5);check(state==3 && warnings==old_warn+1,"one minute warning exactly once");
 key(0);saved=remaining;cycles(500);check(state==2 && remaining==saved,"warning pause freezes");
 frame("warning_paused.ppm");
 key(0);check(state==3,"resume warning phase");
 old_time=timeouts;wait_rem(0);cycles(5);check(state==4 && timeouts==old_time+1,"timeout event exactly once");
 cycles(600);check(overtime>=3 && timer_bcd[7:0]>=8'h03,"positive overtime and BCD");
 key(0);saved=overtime;cycles(500);check(overtime==saved,"pause overtime freezes");
 frame("timeout_paused.ppm");key(0);check(state==4,"resume overtime");
 key(3);check(state==1 && remaining==120 && overtime==0,"KEY4 resets current agenda timer");
 key(1);check(current==1 && remaining==180 && state==1,"KEY2 next agenda and duration");
 key(2);check(current==0 && remaining==120,"KEY3 previous agenda");
 key(2);check(current==0,"previous at first agenda bounded");
 // Alarm synchronized and latched; held alarm cannot be cleared.
 emergency_raw=1;cycles(8);check(alarm && state==2 && alarm_paused,"alarm latch forces pause");
 saved=remaining;key(1);key(3);cycles(500);check(current==0 && remaining==saved,"alarm blocks keys and time");
 alarm_clear=1;cycles(3);alarm_clear=0;check(alarm,"alarm input wins clear");
 frame("alarm.ppm");emergency_raw=0;cycles(8);check(alarm,"alarm stays latched after input release");
 alarm_clear=1;cycles(2);alarm_clear=0;cycles(300);
 check(!alarm && state==2 && remaining==saved && alarm_paused,"clear leaves meeting paused");
 frame("alarm_cleared.ppm");key(0);check(state==1 && !alarm_paused,"host KEY1 required to resume");
 en=0;saved=remaining;cycles(500);check(remaining==saved,"scene disable freezes meeting");en=1;
 held_key(1);check(state==6 && current==0,"long KEY2 finishes without short next action");
 saved=remaining;cycles(500);check(remaining==saved,"finished timer frozen");frame("finished.ppm");
 held_key(3);check(state==0 && current==0,"long KEY4 returns initial state");
 key(0);for(f=0;f<5;f=f+1) key(1);check(current==5,"last agenda reachable");
 key(1);check(state==6 && current==5,"next after final agenda finishes bounded");
 held_key(3);emergency_raw=1;cycles(10);emergency_raw=0;cycles(5);alarm_clear=1;cycles(2);alarm_clear=0;
 key(0);check(state==1 && remaining==120,"alarm before START resumes by loading first agenda");
 // Output pipeline alignment and pass-through away from panel.
 en=0;de_i=1;hs_i=1;px_x=17;px_y=99;cycles(2);
 check(data_o==data_i && hs_o && de_o && px_x_o==17 && px_y_o==99,"disabled RGB and sync pipeline passthrough");
 de_i=0;en=1;cycles(2);check(data_o==data_i && !de_o,"blanking preserves input RGB");
 $display("RESULT checks=%0d errors=%0d",checks,errors);
 if(errors==0) $display("ALL TESTS PASSED");
 $stop;
end
initial begin #200000000; $display("FAIL watchdog");$stop;end
endmodule
