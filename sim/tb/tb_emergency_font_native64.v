`timescale 1ns/1ps
module tb_emergency_font_native64;
  reg clk=0,en=0; reg [16:0] addr=0; wire [1:0] q;
  integer gid,pix,core_count,edge_count,fail=0;
  emergency_big_font_rom dut(.clk(clk),.en(en),.addr(addr),.q(q));
  always #5 clk=~clk;
  initial begin
    en=1;
    for(gid=0;gid<19;gid=gid+1) begin
      core_count=0;edge_count=0;
      for(pix=0;pix<4096;pix=pix+1) begin
        addr=gid*4096+pix;
        @(posedge clk); #1;
        if(q==2'd3) core_count=core_count+1;
        else if(q==2'd1||q==2'd2) edge_count=edge_count+1;
      end
      if(core_count<100||edge_count<20) begin
        $display("[FAIL] glyph %0d core=%0d edge=%0d",gid,core_count,edge_count);
        fail=fail+1;
      end
    end
    if(fail==0) $display("[PASS] 19 native-64 glyphs contain core and AA edge coverage");
    else $display("[FAIL] native-64 font failures=%0d",fail);
    $finish;
  end
endmodule
