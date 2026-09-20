`timescale 1ns/1ps
module tb_emergency_alarm_ctrl;
  reg clk=0,rst=1,alarm_en=0,key4_raw=1; wire [1:0] alarm_type;
  wire [3:0] mt,mo,st,so; always #5 clk=~clk;
  emergency_alarm_ctrl #(.CLK_HZ(10),.DEBOUNCE_CYCLES(2)) dut(
    .clk(clk),.rst(rst),.alarm_en(alarm_en),.key4_raw(key4_raw),.alarm_type(alarm_type),
    .elapsed_m_tens(mt),.elapsed_m_ones(mo),.elapsed_s_tens(st),.elapsed_s_ones(so));
  task press; begin key4_raw=0;repeat(5)@(posedge clk);key4_raw=1;repeat(5)@(posedge clk);end endtask
  initial begin
    repeat(3)@(posedge clk);rst=0;alarm_en=1;repeat(3)@(posedge clk);
    if(alarm_type!==0)$fatal(1,"entry must select fire");
    press;if(alarm_type!==1)$fatal(1,"KEY4 must select earthquake");
    press;if(alarm_type!==2)$fatal(1,"KEY4 must select weather");
    press;if(alarm_type!==3)$fatal(1,"KEY4 must select evacuation");
    press;if(alarm_type!==0)$fatal(1,"selection must wrap");
    repeat(12)@(posedge clk);if(st==0&&so==0)$fatal(1,"elapsed timer did not advance");
    alarm_en=0;repeat(3)@(posedge clk);alarm_en=1;repeat(3)@(posedge clk);
    if(alarm_type!==0)$fatal(1,"new alarm must return to fire");
    $display("PASS: KEY4 cycles all four alarm types and timer advances");$finish;
  end
endmodule
