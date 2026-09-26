`timescale 1ns/1ps
module tb_meeting_control_audio;
reg clk=0,rst=1,en=1,config_ready=1,alarm=0;
reg [3:0] press=0; reg [4:0] total=3; reg [15:0] duration=62;
wire [2:0] state; wire [3:0] current; wire [15:0] remaining,overtime;
wire alarm_paused,warn_event,timeout_event; wire [31:0] uptime;
reg menu_active=0,emergency=0; reg [1:0] scene_id=1,q_state=0;
reg [3:0] q_t_tens=0,q_t_ones=0;
wire audio_event; wire [1:0] event_kind,event_media;
integer errors=0,audio_count=0,warn_count=0,timeout_count=0;

always #5 clk=~clk;

meeting_ctrl #(.SEC_CYCLES(4)) dut(
 .clk(clk),.rst(rst),.en(en),.config_ready(config_ready),.alarm(alarm),.press(press),
 .end_long(1'b0),.home_long(1'b0),.total(total),.duration(duration),.state(state),
 .current(current),.remaining(remaining),.overtime(overtime),.alarm_paused(alarm_paused),
 .warn_event(warn_event),.timeout_event(timeout_event),.uptime(uptime));

audio_feature_events #(.CLOCK_HZ(10)) aud(
 .clk(clk),.rst_n(~rst),.menu_active(menu_active),.emergency(emergency),
 .scene_id(scene_id),.q_state(q_state),.q_t_tens(q_t_tens),.q_t_ones(q_t_ones),
 .meeting_warn_event(warn_event),.meeting_timeout_event(timeout_event),
 .event_valid(audio_event),.event_kind(event_kind),.event_media(event_media));

always @(posedge clk) begin
 if(audio_event) audio_count=audio_count+1;
 if(warn_event) warn_count=warn_count+1;
 if(timeout_event) timeout_count=timeout_count+1;
end

task tap; input integer n; begin
 @(negedge clk); press=1<<n; @(negedge clk); press=0;
end endtask
task check; input cond; input [255:0] msg; begin
 if(!cond) begin $display("FAIL %s",msg); errors=errors+1; end
 else $display("PASS %s",msg);
end endtask

initial begin
 repeat(3) @(negedge clk); rst=0; repeat(5) @(negedge clk);
 tap(0); repeat(13) @(negedge clk); check(state==1 && remaining==62,"KEY1 starts agenda");
 repeat(9) @(negedge clk); check(state==3 && remaining<=60,"60-second warning state");
 repeat(4) @(negedge clk); check(warn_count==1 && audio_count>=1,"warning drives HDMI event once");

 tap(0); repeat(2) @(negedge clk); check(state==2,"KEY1 pauses");
 tap(0); repeat(2) @(negedge clk); check(state==3,"KEY1 resumes warning state");

 tap(1); repeat(4) @(negedge clk); duration=125; repeat(10) @(negedge clk);
 check(current==1 && remaining==125,"KEY2 loads next agenda duration after BRAM latency");
 tap(2); repeat(4) @(negedge clk); duration=62; repeat(10) @(negedge clk);
 check(current==0 && remaining==62,"KEY3 loads previous agenda");
 duration=70; tap(3); repeat(13) @(negedge clk);
 check(current==0 && remaining==70,"KEY4 re-times current agenda");

 // Force a short agenda to verify one timeout event and the delayed second HDMI tone.
 duration=2; tap(3); repeat(13) @(negedge clk); repeat(12) @(negedge clk);
 check(state==4 && timeout_count==1,"agenda reaches timeout once");
 repeat(8) @(negedge clk); check(audio_count>=3,"timeout produces two HDMI tone events");
 $display("RESULT errors=%0d audio=%0d warn=%0d timeout=%0d",errors,audio_count,warn_count,timeout_count);
 $finish;
end
endmodule
