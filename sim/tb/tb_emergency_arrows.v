`timescale 1ns/1ps
module tb_emergency_arrows;
  reg clk=0,rst=1,en=0; always #5 clk=~clk;
  reg [11:0] x=0,y=0; reg [1:0] alarm_type=0; wire [23:0] out; wire ho,vo,de; wire[11:0]xo,yo;
  emergency_multi_overlay #(.BLINK_DIV(1000)) dut(.clk(clk),.rst(rst),.hs_i(0),.vs_i(0),.de_i(1),
    .data_i(24'h123456),.px_x(x),.px_y(y),.alarm_en(en),.alarm_type(alarm_type),
    .ticker_ids(224'd0),.ticker_length(6'd0),.ticker_speed(6'd1),
    .ticker_pause(1'b0),.ticker_override(1'b0),
    .min_tens(0),.min_ones(0),.sec_tens(0),.sec_ones(0),.hs_o(ho),.vs_o(vo),.de_o(de),
    .data_o(out),.px_x_o(xo),.px_y_o(yo));
  task sample;input[11:0]sx,sy;begin @(negedge clk);x=sx;y=sy;repeat(4)@(posedge clk);end endtask
  initial begin
    repeat(4)@(posedge clk);rst=0;en=1;repeat(5)@(posedge clk);
    sample(12'd100,12'd230);if(out!==24'hFF3B30)begin $display("[FAIL] type0 left arrow %h",out);$finish;end
    sample(12'd500,12'd230);if(out===24'hFF3B30)begin $display("[FAIL] type0 leaked right arrow");$finish;end
    alarm_type=1;repeat(4)@(posedge clk);
    sample(12'd100,12'd230);if(out===24'hFF3B30)begin $display("[FAIL] type1 leaked left arrow");$finish;end
    sample(12'd500,12'd230);if(out!==24'hFF9F0A)begin $display("[FAIL] type1 right arrow %h",out);$finish;end
    sample(12'd20,12'd230);if(out===24'hFF3B30)begin $display("[FAIL] arrow leaked outside geometry");$finish;end
    $display("[PASS] each emergency type displays exactly one shelter direction");$finish;
  end
endmodule
