`timescale 1ns/1ps

// 低功耗等价门控专项：可视化窗口外 BRAM 读口关闭、地址与坐标运算冻结；
// 窗口内仍按原 50 列映射连续读地址。只检查门控边界，不改变柱高/显示测试。
module EG_LOGIC_BRAM #(
    parameter DATA_WIDTH_A=8,DATA_WIDTH_B=8,ADDR_WIDTH_A=9,ADDR_WIDTH_B=9,
    parameter DATA_DEPTH_A=512,DATA_DEPTH_B=512,MODE="DP",REGMODE_A="NOREG",
    parameter REGMODE_B="NOREG",IMPLEMENT="9K"
)(output [7:0] doa,output [7:0] dob,input [7:0] dia,dib,input cea,ocea,clka,wea,rsta,bea,
  input ceb,oceb,clkb,web,rstb,beb,input [8:0] addra,addrb);
    assign doa=8'd0; assign dob=8'd0;
endmodule

module tb_audio_viz_window_gate;
    reg clk=0,rst=1,de_i=0;
    reg [11:0] x=0,y=0;
    wire hs_o,vs_o,de_o; wire [23:0] data_o; wire [11:0] xo,yo;
    always #5 clk=~clk;

    audio_viz_overlay dut(
      .clk(clk),.rst(rst),.hs_i(1'b0),.vs_i(1'b0),.de_i(de_i),.data_i(24'h123456),
      .px_x(x),.px_y(y),.menu_active(1'b0),.scene_id(2'd0),.meet_warn_lv(1'b0),
      .pcm_take(1'b0),.pcm(16'sd0),.hs_o(hs_o),.vs_o(vs_o),.de_o(de_o),
      .data_o(data_o),.px_x_o(xo),.px_y_o(yo));

    integer checks=0,fails=0;
    task expect_gate;
      input exp_en; input [11:0] exp_vx; input [255:0] msg;
      begin
        #1; checks=checks+1;
        if((dut.viz_rd_en===exp_en)&&(dut.viz_x===exp_vx))
          $display("[PASS] %0s",msg);
        else begin
          fails=fails+1;
          $display("[FAIL] %0s en=%b/%b vx=%0d/%0d",msg,
                   dut.viz_rd_en,exp_en,dut.viz_x,exp_vx);
        end
      end
    endtask

    initial begin
      repeat(3) @(posedge clk); rst=0;
      de_i=1; x=12'd639; y=12'd361; expect_gate(0,12'd0,"上边界前冻结");
      y=12'd362; expect_gate(1,12'd639,"首行放行");
      y=12'd437; x=12'd321; expect_gate(1,12'd321,"末行放行");
      y=12'd438; expect_gate(0,12'd0,"下边界后冻结");
      de_i=0; y=12'd400; x=12'd500; expect_gate(0,12'd0,"消隐期冻结");

      de_i=1; y=12'd400; x=12'd0; #1;
      checks=checks+1;
      if(dut.col==6'd0 && dut.sub==6'd0) $display("[PASS] 窗口内首列映射不变");
      else begin fails=fails+1; $display("[FAIL] 窗口内首列映射"); end
      x=12'd628; #1;
      checks=checks+1;
      if(dut.col==6'd49 && dut.sub==6'd4) $display("[PASS] 窗口内末列映射不变");
      else begin fails=fails+1; $display("[FAIL] 窗口内末列 col=%0d sub=%0d",dut.col,dut.sub); end

      $display("==== tb_audio_viz_window_gate checks=%0d fails=%0d ====",checks,fails);
      if(fails==0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
      $finish;
    end
endmodule
