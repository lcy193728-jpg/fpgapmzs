`timescale 1ns/1ps
module tb_meeting_io;
reg clk=0;always #5 clk=~clk;
reg rst=1,start=0,init_done=0,data_valid=0,read_end=0;
reg [7:0] data=0;wire read;wire [31:0] addr;
wire cfg_start,cfg_valid,cfg_last,busy,done;wire [7:0] cfg_data;
meeting_sd_reader #(.START_SECTOR(123456),.SECTORS(2)) reader(clk,rst,start,init_done,
 read,addr,data,data_valid,read_end,cfg_start,cfg_valid,cfg_data,cfg_last,busy,done);
reg alarm=0,warn_event=0,timeout_event=0;wire buzzer,sample_valid,tone;
wire signed [15:0] pcm_l,pcm_r;
meeting_audio #(.CLK_HZ(1200000),.BEEP_CYCLES(3000),.GAP_CYCLES(2000)) audio(
 clk,rst,alarm,warn_event,timeout_event,buzzer,sample_valid,pcm_l,pcm_r,tone);
integer checks=0,errors=0,requests=0,bytes_seen=0,lasts=0,sections=0;
integer sample_count=0,pcm_nonzero=0,edges=0,i,s,n;
reg tone_prev=0;
always @(posedge clk) if(!rst) begin
 if(read) requests=requests+1;
 if(cfg_valid) begin bytes_seen=bytes_seen+1;if(cfg_data!==data) errors=errors+1;end
 if(cfg_last) lasts=lasts+1;
 if(sample_valid) begin sample_count=sample_count+1;
 if(pcm_l!==pcm_r) errors=errors+1;
 if(pcm_l!=0) pcm_nonzero=pcm_nonzero+1;end
 if(tone && !tone_prev) sections=sections+1;
 tone_prev=tone;
end
task cycles;input integer n;begin repeat(n) @(negedge clk);end endtask
task check;input c;input [639:0] m;begin checks=checks+1;
 if(c!==1'b1) begin errors=errors+1;$display("FAIL %0s",m);end else $display("PASS %0s",m);end endtask
initial begin
 cycles(3);rst=0;start=1;cycles(1);start=0;cycles(10);
 check(busy && requests==0,"reader waits for SD initialization");init_done=1;cycles(3);
 for(s=0;s<2;s=s+1) begin
 check(addr==123456+s && requests==s+1,"sector request address");
 for(i=0;i<512;i=i+1) begin data=i;data_valid=1;cycles(1);data_valid=0;cycles(1);end
 read_end=1;cycles(1);read_end=0;cycles(3);
 end
 check(!busy && bytes_seen==1024 && lasts==1 && requests==2,"two sectors and one final-byte marker");
 n=sample_count;cycles(2500);check(sample_count-n==100,"48kHz sample enable at exact 25 clocks");
 check(pcm_l==0 && !tone,"audio idle silence");
 sections=0;warn_event=1;cycles(1);warn_event=0;cycles(8500);
 check(sections==1 && !tone && pcm_nonzero>0,"warning one audible PCM beep");
 sections=0;timeout_event=1;cycles(1);timeout_event=0;cycles(8500);
 check(sections==2 && !tone,"timeout exactly two audible beeps");
 sections=0;alarm=1;cycles(16000);check(sections>=3,"alarm repeated beep pattern");
 alarm=0;cycles(10);check(!tone && pcm_l==0,"alarm clear cancels old ordinary sound");
 $display("RESULT checks=%0d errors=%0d",checks,errors);
 if(errors==0) $display("ALL TESTS PASSED");$stop;
end
initial begin #2000000;$display("FAIL watchdog");errors=errors+1;$stop;end
endmodule
