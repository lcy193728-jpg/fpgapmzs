`timescale 1ns/1ps
module tb_emergency_uart_ticker;
  reg clk=0,rst=1,vs=0,en=0,pause=0,override_en=1;
  reg [11:0] x=0,y=448; reg [5:0] speed=1,len=2;
  reg [223:0] ids=0; wire [23:0] data_o; wire hs_o,vs_o,de_o; wire[11:0]xo,yo;
  integer errors=0;
  always #5 clk=~clk;
  emergency_multi_overlay #(.BLINK_DIV(1000)) dut(
    .clk(clk),.rst(rst),.hs_i(1'b0),.vs_i(vs),.de_i(1'b1),.data_i(24'h123456),
    .px_x(x),.px_y(y),.alarm_en(en),.alarm_type(2'd0),
    .min_tens(0),.min_ones(0),.sec_tens(0),.sec_ones(0),
    .ticker_ids(ids),.ticker_length(len),.ticker_speed(speed),
    .ticker_pause(pause),.ticker_override(override_en),
    .hs_o(hs_o),.vs_o(vs_o),.de_o(de_o),.data_o(data_o),.px_x_o(xo),.px_y_o(yo));
  task check(input cond,input [255:0] msg);begin
    if(!cond)begin errors=errors+1;$display("[FAIL] %0s",msg);end
    else $display("[PASS] %0s",msg);
  end endtask
  task frame_pulse;begin
    @(negedge clk);vs=1;@(negedge clk);vs=0;repeat(2)@(posedge clk);
  end endtask
  initial begin
    ids[6:0]=7'd42;ids[13:7]=7'd43;
    repeat(4)@(posedge clk);rst=0;en=1;repeat(6)@(posedge clk);
    x=0;repeat(3)@(posedge clk);check(dut.gid==42,"custom ticker glyph 0");
    x=16;repeat(3)@(posedge clk);check(dut.gid==43,"custom ticker glyph 1");
    x=32;repeat(3)@(posedge clk);check(dut.gid==105,"custom ticker blank gap");
    pause=1;frame_pulse();frame_pulse();check(dut.scroll_phase==0,"pause holds ticker phase");
    pause=0;speed=3;frame_pulse();frame_pulse();check(dut.scroll_phase==0,"speed divider waits");
    frame_pulse();check(dut.scroll_phase==1,"speed divider advances");
    override_en=0;x=0;repeat(3)@(posedge clk);
    check(dut.gid==4,"restore uses type-specific default ticker");
    if(errors==0)$display("=== emergency UART ticker PASS ===");
    else $display("=== emergency UART ticker FAIL errors=%0d ===",errors);
    $finish;
  end
endmodule
